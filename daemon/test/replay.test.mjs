// Phase 2 exit gate — the daemon replays a real claim end-to-end on a fork.
//
// What this proves, in the order the exit gate demands:
//   1. the anchor is certified before execution, and a wrong codehash ABORTS the job;
//   2. a real claim against real historical state produces the expected verdict;
//   3. the SAME assertion on the checked path produces the OPPOSITE verdict (the falsification);
//   4. re-running the same job is byte-identical (determinism / idempotence);
//   5. the fork is left UNMUTATED after replay (the snapshot/revert property).
//
// (4) and (5) are the two that fail silently if the snapshot bracket is wrong, which is why they
// are asserted rather than assumed.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";

import { ProviderPool } from "../src/ProviderPool.mjs";
import { ForkCache } from "../src/ForkCache.mjs";
import { computeCodehash, AnchorMismatch, normalizeHash } from "../src/anchor.mjs";
import { replayJob, replayJobTwice, PREDICATE_IDS } from "../src/replay.mjs";
import { eulerRefutedJob, eulerHeldJob, ADDR, BLOCK, USER } from "../src/fixtures/euler.mjs";

const RPC = "https://eth.drpc.org";

let pool;
let cache;
let fork;
let codehash;

before(async () => {
  pool = new ProviderPool([RPC, "https://mainnet.gateway.tenderly.co"]);
  const code = await pool.getCode(ADDR.EULER, BLOCK);
  codehash = computeCodehash(code);

  cache = new ForkCache({ rpcUrl: RPC, startPort: 8700, log: () => {} });
  fork = await cache.get({ chainId: 1, blockNumber: BLOCK, codehash });
}, { timeout: 180_000 });

after(async () => {
  await cache?.closeAll();
});

/** Independent control: derive the codehash with cast, not with our own code. */
function castCodehash() {
  const code = execFileSync(
    "cast",
    ["code", ADDR.EULER, "--block", String(BLOCK), "--rpc-url", RPC],
    { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 }
  ).trim();
  return execFileSync("cast", ["keccak", code], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 }).trim();
}

async function forkBalanceOf(token, holder) {
  const r = await fetch(fork.url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "eth_call",
      params: [{ to: token, data: "0x70a08231" + holder.slice(2).padStart(64, "0") }, "latest"],
    }),
  });
  const j = await r.json();
  return BigInt(j.result ?? "0x0");
}

test("fixture: our codehash matches cast", () => {
  assert.equal(codehash, castCodehash(), "anchor hash disagrees with cast");
  assert.equal(normalizeHash(codehash), codehash);
});

test("anchor: a wrong codehash ABORTS the job before anything executes", async () => {
  const bad = { ...eulerRefutedJob("0x" + "22".repeat(32)) };
  await assert.rejects(() => replayJob({ job: bad, provider: pool, forkUrl: fork.url }), (e) => {
    assert.ok(e instanceof AnchorMismatch, `expected AnchorMismatch, got ${e.name}`);
    return true;
  });
});

test("replay: the unchecked path REFUTES, and the run is deterministic", async () => {
  const job = eulerRefutedJob(codehash);
  const { first, second, deterministic } = await replayJobTwice({
    job,
    provider: pool,
    forkUrl: fork.url,
    log: () => {},
  });

  assert.equal(first.assertionHeld, false, "donateToReserves did not revert, so the guard is MISSING");
  assert.equal(deterministic, true);
  assert.equal(first.traceHash, second.traceHash, "traceHash must be reproducible");
  assert.match(first.traceHash, /^0x[0-9a-f]{64}$/);
}, { timeout: 180_000 });

test("replay: the SAME assertion on the checked path HOLDS (the falsification)", async () => {
  const job = eulerHeldJob(codehash);
  const r = await replayJob({ job, provider: pool, forkUrl: fork.url, log: () => {} });

  assert.equal(r.assertionHeld, true, "withdraw should have reverted, so the guard is PRESENT");
  assert.equal(r.observation.reverted, true);
}, { timeout: 180_000 });

test("falsification pair: identical predicate, opposite verdicts at the same block", async () => {
  const refuted = await replayJob({
    job: eulerRefutedJob(codehash),
    provider: pool,
    forkUrl: fork.url,
    log: () => {},
  });
  const held = await replayJob({
    job: eulerHeldJob(codehash),
    provider: pool,
    forkUrl: fork.url,
    log: () => {},
  });

  assert.equal(refuted.assertionHeld, false);
  assert.equal(held.assertionHeld, true);
  assert.notEqual(refuted.traceHash, held.traceHash);
}, { timeout: 240_000 });

test("fork mutation: replay leaves the fork exactly as pinned", async () => {
  // The setup wraps 100 ETH into WETH and deposits it. If the snapshot bracket were broken, the
  // user would still hold WETH afterwards. It must be zero.
  const before = await forkBalanceOf(ADDR.WETH, USER);
  assert.equal(before, 0n, "fork was not in its pinned state before the run");

  await replayJob({ job: eulerRefutedJob(codehash), provider: pool, forkUrl: fork.url, log: () => {} });

  const afterBal = await forkBalanceOf(ADDR.WETH, USER);
  assert.equal(
    afterBal,
    0n,
    "replay left the fork MUTATED — a second run would observe different state and the " +
      "determinism claim would be false"
  );
}, { timeout: 180_000 });

test("replay: a malformed predicateId is rejected, not silently passed", async () => {
  const job = { ...eulerRefutedJob(codehash), predicateId: "0x" + "33".repeat(32) };
  await assert.rejects(() => replayJob({ job, provider: pool, forkUrl: fork.url }), /unknown predicateId/);
});
