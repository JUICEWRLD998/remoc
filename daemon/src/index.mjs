#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// remoc verifier daemon — CLI entry point.
//
// Usage:
//   node src/index.mjs --fixture euler          # the unchecked path -> REFUTED
//   node src/index.mjs --fixture euler-held     # the checked path   -> HELD
//   node src/index.mjs --fixture pair           # both, proving the falsification
//   node src/index.mjs --fixture euler --control # planted anchor-mismatch control
//   node src/index.mjs --fixture euler --once    # single run (default is run-twice)

import { ProviderPool } from "./ProviderPool.mjs";
import { ForkCache } from "./ForkCache.mjs";
import { computeCodehash, AnchorMismatch, NoCodeAtTarget, certify } from "./anchor.mjs";
import { replayJob, replayJobTwice, UnknownPredicate } from "./replay.mjs";
import { eulerRefutedJob, eulerHeldJob, ADDR, BLOCK } from "./fixtures/euler.mjs";

const RPCS = [
  "https://eth.drpc.org",
  "https://mainnet.gateway.tenderly.co",
  "https://eth-mainnet.public.blastapi.io",
];

function parseArgs(argv) {
  const out = { fixture: "pair", control: false, once: false, verbose: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--fixture") out.fixture = argv[++i];
    else if (a === "--control") out.control = true;
    else if (a === "--once") out.once = true;
    else if (a === "--verbose" || a === "-v") out.verbose = true;
    else if (a === "--help" || a === "-h") out.help = true;
  }
  return out;
}

const log = (m) => console.log(m);
const step = (m) => console.log(`\n=== ${m} ===`);

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(
      "remoc daemon\n\n" +
        "  --fixture euler|euler-held|pair   which claim to replay (default pair)\n" +
        "  --once                            run once instead of twice\n" +
        "  --control                         also run the planted anchor-mismatch control\n" +
        "  --verbose                         per-step logging\n"
    );
    return;
  }

  const pool = new ProviderPool(RPCS, { log: args.verbose ? log : () => {} });
  const cache = new ForkCache({
    rpcUrl: RPCS[0],
    startPort: 8800,
    log: args.verbose ? log : () => {},
  });

  try {
    step("anchor: certifying the pinned bytecode");
    const code = await pool.getCode(ADDR.EULER, BLOCK);
    const codehash = computeCodehash(code);
    const bytes = (code.length - 2) / 2;
    log(`target   ${ADDR.EULER}`);
    log(`block    ${BLOCK}`);
    log(`codehash ${codehash}`);
    log(`size     ${bytes} bytes`);

    const fork = await cache.get({ chainId: 1, blockNumber: BLOCK, codehash });
    log(`fork     ${fork.url}`);

    // PLANTED POSITIVE CONTROL: a deliberately wrong codehash must abort the job. If this does
    // NOT throw, the anchor is decorative and every verdict below is untrustworthy.
    if (args.control) {
      step("control: wrong codehash must ABORT, not proceed");
      const wrong = "0x" + "11".repeat(32);
      try {
        await certify({
          provider: pool,
          target: ADDR.EULER,
          blockNumber: BLOCK,
          expectedCodehash: wrong,
        });
        log("FAIL: a wrong codehash was ACCEPTED — the anchor is not enforced");
        process.exitCode = 1;
      } catch (e) {
        if (e instanceof AnchorMismatch || e instanceof NoCodeAtTarget) {
          log(`PASS: ${e.name} — job aborted before execution`);
        } else {
          log(`FAIL: unexpected error type ${e.name}: ${e.message}`);
          process.exitCode = 1;
        }
      }
    }

    const want = args.fixture;
    const cases = [];
    if (want === "euler" || want === "pair") cases.push(["donateToReserves (unchecked)", eulerRefutedJob(codehash), false]);
    if (want === "euler-held" || want === "pair") cases.push(["withdraw (checked)", eulerHeldJob(codehash), true]);

    const results = [];
    for (const [name, job, expectedHeld] of cases) {
      step(`replay: ${name}  (same predicateId for both cases)`);
      log(`predicateId ${job.predicateId}`);

      const run = args.once
        ? { first: await replayJob({ job, provider: pool, forkUrl: fork.url, log: args.verbose ? log : () => {} }), deterministic: null }
        : await replayJobTwice({ job, provider: pool, forkUrl: fork.url, log: args.verbose ? log : () => {} });

      const r = run.first;
      log(`verdict   ${r.assertionHeld ? "HELD" : "REFUTED"}`);
      log(`reverted  ${r.observation.reverted}`);
      log(`traceHash ${r.traceHash}`);
      if (run.deterministic !== null) log(`deterministic ${run.deterministic}`);

      if (r.assertionHeld !== expectedHeld) {
        log(`FAIL: expected ${expectedHeld ? "HELD" : "REFUTED"}, got ${r.assertionHeld ? "HELD" : "REFUTED"}`);
        process.exitCode = 1;
      }
      results.push({ name, held: r.assertionHeld, trace: r.traceHash });
    }

    if (results.length === 2) {
      step("falsification: one predicate, two protocols states, opposite verdicts");
      const [a, b] = results;
      if (a.held === b.held) {
        log("FAIL: both cases agreed — the assertion cannot distinguish a real bug from correct code");
        process.exitCode = 1;
      } else {
        log(`${a.name.padEnd(30)} -> ${a.held ? "HELD" : "REFUTED"}`);
        log(`${b.name.padEnd(30)} -> ${b.held ? "HELD" : "REFUTED"}`);
        log("PASS: the mechanism discriminates. An always-true assertion would have passed both.");
      }
    }
  } catch (e) {
    if (e instanceof UnknownPredicate || e instanceof AnchorMismatch) {
      console.error(`ABORTED: ${e.message}`);
    } else {
      console.error(`ERROR: ${e.name}: ${e.message}`);
    }
    process.exitCode = 1;
  } finally {
    await cache.closeAll();
  }
}

main();
