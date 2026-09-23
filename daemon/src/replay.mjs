// SPDX-License-Identifier: MIT
//
// replay — execute a committed claim against a pinned fork and evaluate its predicate.
//
// Three things in here are load-bearing:
//
// 1. CERTIFY THE ANCHOR, THEN EXECUTE. Never the other way round. If execution precedes the
//    anchor check, a verdict can be produced about code other than the one the claim committed,
//    and nothing downstream can tell.
//
// 2. A REVERT IS AN OBSERVATION, NOT AN ERROR. If a reverting call were treated as a transport
//    failure, every "the check is missing" verdict would invert into "the call failed to run" and
//    the daemon would confidently report the opposite of the truth. Transport failures and
//    execution reverts are distinct types here.
//
// 3. SNAPSHOT, THEN REVERT. Jobs SEND transactions to set up state (a position, a debt), which
//    mutates the fork. Without restoring the snapshot, a second run of the same job would observe
//    different state and produce a different verdict — destroying the idempotence the whole
//    mechanism rests on. Every replay is bracketed by anvil_snapshot / anvil_revert, so the fork
//    is left exactly as pinned and re-runs are byte-identical by construction.

import { keccak256, keccakUtf8, toHex } from "./keccak.mjs";
import {
  decodeSteps,
  decodeWords,
  selectorOf,
  wordToSelector,
  firstWordOf,
  AbiDecodeError,
} from "./abi.mjs";
import { certify, normalizeHash } from "./anchor.mjs";

/** Predicate ids, derived exactly as `Predicates.sol` derives them. */
export const PREDICATE_IDS = {
  INVARIANT_DELTA: toHex(keccakUtf8("remoc.predicate.invariantDelta(uint256)")),
  NO_PRIVILEGED_EFFECT: toHex(keccakUtf8("remoc.predicate.noPrivilegedEffect(address,bytes4)")),
  HEALTH_CHECKED: toHex(keccakUtf8("remoc.predicate.healthChecked(bytes4)")),
};

export class UnknownPredicate extends Error {
  constructor(id) {
    super(`unknown predicateId ${id}`);
    this.name = "UnknownPredicate";
  }
}

/** The job is internally inconsistent (params disagree with the steps). Never guess. */
export class MalformedJob extends Error {
  constructor(msg) {
    super(`malformed job: ${msg}`);
    this.name = "MalformedJob";
  }
}

/** The fork/RPC failed. Distinct from a revert, which is data. */
export class ReplayTransportError extends Error {
  constructor(msg) {
    super(msg);
    this.name = "ReplayTransportError";
  }
}

/** A setup step failed, so the job never reached the code under test. */
export class SetupStepFailed extends Error {
  constructor(index, reason) {
    super(
      `setup step ${index} failed (${reason}), so the claim never reached the code under test. ` +
        `A verdict here would describe a job that did not run.`
    );
    this.name = "SetupStepFailed";
    this.stepIndex = index;
  }
}

const canonical = (v) => {
  if (v === null || typeof v !== "object") return JSON.stringify(v);
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  return `{${Object.keys(v)
    .sort()
    .map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`)
    .join(",")}}`;
};

// ------------------------------------------------------------------ fork rpc

async function forkRpc(forkUrl, method, params) {
  let res;
  try {
    res = await fetch(forkUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
      signal: AbortSignal.timeout(60_000),
    });
  } catch (e) {
    throw new ReplayTransportError(`fork unreachable during ${method}: ${e.message}`);
  }
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    throw new ReplayTransportError(`fork returned non-JSON during ${method}: ${text.slice(0, 120)}`);
  }
  if (json.error) {
    const err = new Error(`${method}: ${String(json.error.message).slice(0, 200)}`);
    err.rpcError = json.error;
    throw err;
  }
  return json.result;
}

export const snapshot = (forkUrl) => forkRpc(forkUrl, "anvil_snapshot", []);
export const revert = (forkUrl, id) => forkRpc(forkUrl, "anvil_revert", [id]);

/**
 * Pin the fork's clock to the PINNED BLOCK's own timestamp.
 *
 * WHY THIS IS REQUIRED FOR DETERMINISM (found empirically): each setup step mines a block, and
 * protocols routinely read `block.timestamp` — Euler accrues interest from it. Without pinning,
 * run 2 of the same job executes at a later wall-clock time than run 1 and computes different
 * internals, so the verdict can agree while the trace (and in the worst case the verdict itself)
 * does not. That is the difference between "reproducible" and "usually reproducible".
 *
 * Pinning to the pinned block's timestamp is also the semantically honest choice: a claim is about
 * state AT block N, so it should be evaluated as of block N, not as of whenever the daemon ran.
 */
export async function pinClock(forkUrl, blockNumber) {
  const blk = await forkRpc(forkUrl, "eth_getBlockByNumber", [
    "0x" + Number(blockNumber).toString(16),
    false,
  ]);
  if (!blk || !blk.timestamp) {
    throw new ReplayTransportError(`could not read block ${blockNumber} to pin the clock`);
  }
  const ts = parseInt(blk.timestamp, 16);

  // interval 0 => subsequent blocks do not advance the timestamp.
  await forkRpc(forkUrl, "anvil_setBlockTimestampInterval", [0]).catch(() => {});
  await forkRpc(forkUrl, "evm_setNextBlockTimestamp", [ts]).catch(() => {});

  // Base fee feeds `block.basefee`, which some contracts branch on. Pin it too.
  if (blk.baseFeePerGas !== undefined) {
    await forkRpc(forkUrl, "anvil_setNextBlockBaseFeePerGas", [blk.baseFeePerGas]).catch(() => {});
  }

  return ts;
}

async function rpcCall(forkUrl, step) {
  const res = await forkRpc(forkUrl, "eth_call", [
    { to: step.target, from: step.sender, value: "0x" + step.value.toString(16), data: step.data },
    "latest",
  ]).catch((e) => {
    if (e.rpcError && (e.rpcError.code === 3 || /revert/i.test(String(e.rpcError.message)))) {
      return { __reverted: true, data: e.rpcError.data ?? "0x" };
    }
    throw e instanceof ReplayTransportError ? e : new ReplayTransportError(e.message);
  });
  if (res && res.__reverted) return { reverted: true, returnData: res.data };
  return { reverted: false, returnData: res };
}

/**
 * Send a state-changing step. Returns whether it reverted.
 * @dev Impersonation is explicit and the sender is funded, because a call from a zero-balance
 *      account fails for its own reasons and would be misread as the claim's observation.
 */
async function sendStep(forkUrl, step, gas = 8_000_000) {
  await forkRpc(forkUrl, "anvil_impersonateAccount", [step.sender]);
  // Fund generously: a step may itself carry value (e.g. wrapping ETH), and a call that fails
  // for lack of gas would be misread as the claim's observation.
  await forkRpc(forkUrl, "anvil_setBalance", [step.sender, "0x" + (10_000n * 10n ** 18n).toString(16)]);

  let txHash;
  try {
    txHash = await forkRpc(forkUrl, "eth_sendTransaction", [
      {
        from: step.sender,
        to: step.target,
        value: "0x" + step.value.toString(16),
        data: step.data,
        gas: "0x" + gas.toString(16),
      },
    ]);
  } catch (e) {
    // A rejected send (revert at estimate time) is a revert observation, not transport failure.
    if (e.rpcError && (e.rpcError.code === 3 || /revert/i.test(String(e.rpcError.message)))) {
      return { reverted: true, returnData: e.rpcError.data ?? "0x" };
    }
    throw new ReplayTransportError(`sendTransaction failed: ${e.message}`);
  }

  for (let i = 0; i < 40; i++) {
    const receipt = await forkRpc(forkUrl, "eth_getTransactionReceipt", [txHash]);
    if (receipt) {
      return {
        reverted: receipt.status !== "0x1",
        returnData: "0x",
        txHash,
        gasUsed: parseInt(receipt.gasUsed, 16),
      };
    }
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new ReplayTransportError(`no receipt for ${txHash} after 2s`);
}

// -------------------------------------------------------------- predicates

/**
 * Evaluate a predicate over the FINAL step's observation.
 * @returns {boolean} assertionHeld — true means the code behaved correctly
 */
export function evaluatePredicate({ predicateId, params, step, observation, log = () => {} }) {
  const id = normalizeHash(predicateId);

  if (id === PREDICATE_IDS.HEALTH_CHECKED) {
    const [selWord] = decodeWords(params, 1);
    const wantSelector = wordToSelector(selWord.toString(16).padStart(64, "0"));
    const gotSelector = selectorOf(step.data);
    if (gotSelector !== wantSelector) {
      throw new MalformedJob(
        `HEALTH_CHECKED wants selector ${wantSelector} but the final step calls ${gotSelector}`
      );
    }
    log(`  HEALTH_CHECKED(${wantSelector}) reverted=${observation.reverted}`);
    return observation.reverted;
  }

  if (id === PREDICATE_IDS.NO_PRIVILEGED_EFFECT) {
    const [callerWord, selWord] = decodeWords(params, 2);
    const wantCaller = "0x" + callerWord.toString(16).padStart(40, "0");
    const wantSelector = wordToSelector(selWord.toString(16).padStart(64, "0"));

    if (step.sender.toLowerCase() !== wantCaller.toLowerCase()) {
      throw new MalformedJob(
        `NO_PRIVILEGED_EFFECT wants caller ${wantCaller} but the final step is sent by ${step.sender}`
      );
    }
    if (selectorOf(step.data) !== wantSelector) {
      throw new MalformedJob(
        `NO_PRIVILEGED_EFFECT wants selector ${wantSelector} but the final step calls ${selectorOf(step.data)}`
      );
    }
    log(`  NO_PRIVILEGED_EFFECT(${wantCaller}, ${wantSelector}) reverted=${observation.reverted}`);
    return observation.reverted;
  }

  if (id === PREDICATE_IDS.INVARIANT_DELTA) {
    const [bound] = decodeWords(params, 1);
    if (observation.reverted) {
      // A missing observation must NOT read as "within bound" — that would report HELD for a
      // job that never produced a measurement.
      log("  INVARIANT_DELTA: final step reverted, so there is no observation -> not held");
      return false;
    }
    const observed = firstWordOf(observation.returnData);
    if (observed === null) {
      throw new MalformedJob("INVARIANT_DELTA requires a uint256 return value; returnData was empty");
    }
    log(`  INVARIANT_DELTA observed=${observed} bound=${bound}`);
    return observed <= bound;
  }

  throw new UnknownPredicate(id);
}

// ----------------------------------------------------------------- replays

/**
 * Full job: certify anchor, snapshot, execute steps, evaluate, revert.
 *
 * Setup steps (all but the last) must SUCCEED — if one fails the claim never reached the code
 * under test, and reporting a verdict for it would be a lie about a job that did not run.
 */
export async function replayJob({ job, provider, forkUrl, log = () => {} }) {
  // 0. Reject an unknown predicate BEFORE touching the anchor or the fork. A job that cannot be
  //    evaluated should never cause state mutation, and failing fast keeps the fork pristine.
  const predicateId = normalizeHash(job.predicateId);
  if (!Object.values(PREDICATE_IDS).includes(predicateId)) {
    throw new UnknownPredicate(predicateId);
  }

  const certified = await certify({
    provider,
    target: job.target,
    blockNumber: job.blockNumber,
    expectedCodehash: job.expectedCodehash,
  });
  log(`anchor OK: ${certified.codehash} (${certified.codeBytes} bytes) @ block ${job.blockNumber}`);

  let steps;
  try {
    steps = decodeSteps(job.steps);
  } catch (e) {
    throw new MalformedJob(e.message);
  }
  log(`${steps.length} step(s); final = ${steps.at(-1).target}.${selectorOf(steps.at(-1).data)}`);

  const snap = await snapshot(forkUrl);
  let observation;
  const setup = [];
  try {
    // Pin the clock INSIDE the snapshot bracket, so a re-run starts from the same time, not from
    // whatever wall-clock time the previous run left behind.
    const ts = await pinClock(forkUrl, job.blockNumber);
    log(`clock pinned to ${ts} (block ${job.blockNumber})`);

    for (let i = 0; i < steps.length - 1; i++) {
      const s = steps[i];
      const r = await sendStep(forkUrl, s);
      setup.push({ index: i, reverted: r.reverted, gasUsed: r.gasUsed ?? null });
      if (r.reverted) {
        throw new SetupStepFailed(i, `${s.target}.${selectorOf(s.data)} reverted`);
      }
    }

    const last = steps.at(-1);
    // The final step may be executed as a call when it is read-only, but a state-changing claim
    // needs a real transaction. `eth_call` cannot distinguish some reverts caused by state that
    // the setup just created, so send it.
    observation = await sendStep(forkUrl, last);
    observation.returnData = observation.returnData ?? "0x";

    const assertionHeld = evaluatePredicate({
      predicateId: job.predicateId,
      params: job.params,
      step: last,
      observation,
      log,
    });

    const traceHash = toHex(
      keccak256(
        new TextEncoder().encode(
          canonical({
            chainId: Number(job.chainId),
            blockNumber: Number(job.blockNumber),
            target: job.target.toLowerCase(),
            codehash: certified.codehash,
            predicateId: normalizeHash(job.predicateId),
            params: job.params.toLowerCase(),
            steps: job.steps.toLowerCase(),
            setup,
            observation: { reverted: observation.reverted, returnData: observation.returnData.toLowerCase() },
            assertionHeld,
          })
        )
      )
    );

    return { assertionHeld, traceHash, observation, certified, setup };
  } finally {
    // ALWAYS restore, even on throw. Leaving the fork mutated would make the next run of the
    // same job observe different state.
    await revert(forkUrl, snap).catch((e) => {
      log(`WARNING: failed to revert snapshot ${snap}: ${e.message}`);
    });
  }
}

/**
 * Replay the same job twice and assert the verdict and trace commit identically.
 * This is the property the entire "anyone can reproduce it" claim depends on.
 */
export async function replayJobTwice({ job, provider, forkUrl, log = () => {} }) {
  const a = await replayJob({ job, provider, forkUrl, log });
  log("--- second run (must be byte-identical) ---");
  const b = await replayJob({ job, provider, forkUrl, log });

  if (a.assertionHeld !== b.assertionHeld) {
    throw new Error(`NON-DETERMINISTIC: verdict differs between runs (${a.assertionHeld} vs ${b.assertionHeld})`);
  }
  if (a.traceHash !== b.traceHash) {
    throw new Error(`NON-DETERMINISTIC: traceHash differs between runs (${a.traceHash} vs ${b.traceHash})`);
  }
  return { first: a, second: b, deterministic: true };
}
