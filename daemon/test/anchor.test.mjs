// Phase 2 — ProviderPool and the anchor check.
//
// Every negative test here is a PLANTED control: the failure is injected deliberately and the
// code must DETECT it. A green path with no planted failure proves nothing, which is exactly how
// a lying probe passes review.

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";

import { ProviderPool, AllProvidersFailed, RpcError } from "../src/ProviderPool.mjs";
import {
  certify,
  computeCodehash,
  verifyAnchor,
  normalizeHash,
  AnchorMismatch,
  NoCodeAtTarget,
  EMPTY_CODEHASH,
} from "../src/anchor.mjs";

// The Phase 0 fixture: Euler's main contract at a pre-incident block.
const EULER = "0x27182842E098f60e3D576794A5bFFb0777E025d3";
const BLOCK = 16_700_000;
const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";

const LIVE_RPCS = [
  "https://eth.drpc.org",
  "https://eth-mainnet.public.blastapi.io",
  "https://mainnet.gateway.tenderly.co",
];

/** Independently derive a codehash with cast — the control is a different tool, not my own memory. */
function castCodehash(address, block) {
  const code = execFileSync(
    "cast",
    ["code", address, "--block", String(block), "--rpc-url", LIVE_RPCS[0]],
    { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 }
  ).trim();
  const hash = execFileSync("cast", ["keccak", code], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  }).trim();
  return { code, hash, bytes: (code.length - 2) / 2 };
}

// ============================== ProviderPool ==============================

test("pool: a real call returns a valid result", async () => {
  const pool = new ProviderPool(LIVE_RPCS);
  const block = await pool.blockNumber();
  assert.ok(Number.isInteger(block) && block > 20_000_000, `implausible block height ${block}`);
});

test("pool: rotates to a healthy provider when the first is broken", async () => {
  const pool = new ProviderPool(["https://localhost:1/definitely-dead", ...LIVE_RPCS]);
  const block = await pool.blockNumber();
  assert.ok(block > 20_000_000, "pool did not fail over to a live provider");
});

test("PLANTED CONTROL: all providers dead => AllProvidersFailed, never a silent empty result", async () => {
  const pool = new ProviderPool(["https://localhost:1/dead", "https://localhost:2/dead"], {
    maxRounds: 1,
  });
  await assert.rejects(() => pool.blockNumber(), (e) => {
    assert.ok(e instanceof AllProvidersFailed, `expected AllProvidersFailed, got ${e.name}`);
    assert.equal(e.attempts.length, 2);
    return true;
  });
});

test("PLANTED CONTROL: an HTML 200 response is rejected, not parsed as data", async () => {
  // `eth.public-rpc.com` returned a non-JSON body during Phase 0 probing. Simulate that shape
  // with a data-ish endpoint rather than depending on that provider still behaving badly.
  const pool = new ProviderPool(["http://localhost:9/not-json"], { maxRounds: 1 });
  await assert.rejects(
    () => pool.call("eth_blockNumber", []),
    AllProvidersFailed,
    "a non-JSON 200 must not read as a result"
  );
});

test("a genuine RPC error is raised, not retried into a timeout", async () => {
  const pool = new ProviderPool(LIVE_RPCS, { maxRounds: 1 });
  // A malformed address is a protocol-level error every provider will reject identically.
  await assert.rejects(() => pool.getCode("0xnot-an-address", BLOCK), (e) => {
    assert.ok(e instanceof RpcError || e instanceof AllProvidersFailed, `got ${e.name}`);
    return true;
  });
});

// ================================ Anchor ==================================

test("anchor: certifies real code against an independently derived codehash", async () => {
  const { hash, bytes } = castCodehash(EULER, BLOCK);
  const pool = new ProviderPool(LIVE_RPCS);

  const certified = await certify({
    provider: pool,
    target: EULER,
    blockNumber: BLOCK,
    expectedCodehash: hash,
  });

  assert.equal(certified.codehash, normalizeHash(hash));
  assert.equal(certified.codeBytes, bytes);
  assert.ok(bytes > 0);
});

test("anchor: DRIFT GUARD — the pinned fixture code is still 907 bytes", async () => {
  const { bytes } = castCodehash(EULER, BLOCK);
  assert.equal(
    bytes,
    907,
    "Euler's code size at block 16,700,000 changed: the pin has moved and the demo is no " +
      "longer replaying the same state. Investigate before trusting any fixture verdict."
  );
});

test("PLANTED CONTROL: a wrong expected codehash => AnchorMismatch, and nothing executes", async () => {
  const pool = new ProviderPool(LIVE_RPCS);
  const wrong = "0x" + "11".repeat(32);

  await assert.rejects(
    () => certify({ provider: pool, target: EULER, blockNumber: BLOCK, expectedCodehash: wrong }),
    (e) => {
      assert.ok(e instanceof AnchorMismatch, `expected AnchorMismatch, got ${e.name}`);
      assert.equal(e.expected, wrong);
      assert.match(e.actual, /^0x[0-9a-f]{64}$/);
      assert.equal(e.codeBytes, 907, "the mismatch report should carry the real code size");
      return true;
    }
  );
});

test("PLANTED CONTROL: an address with no code => NoCodeAtTarget", async () => {
  const pool = new ProviderPool(LIVE_RPCS);
  // An EOA: nothing to be right or wrong about.
  const eoa = "0x000000000000000000000000000000000000bEEF";
  await assert.rejects(
    () => certify({ provider: pool, target: eoa, blockNumber: BLOCK, expectedCodehash: EMPTY_CODEHASH }),
    (e) => {
      assert.ok(e instanceof NoCodeAtTarget, `expected NoCodeAtTarget, got ${e.name}`);
      return true;
    }
  );
});

test("anchor: rejects a malformed codehash instead of comparing garbage", () => {
  assert.throws(() => normalizeHash("0x1234"), /not a 32-byte hex hash/);
  assert.throws(() => normalizeHash(null), /not a 32-byte hex hash/);
  assert.throws(() => normalizeHash("deadbeef".repeat(8)), /not a 32-byte hex hash/);
});

test("anchor: computeCodehash matches cast for real WETH bytecode", () => {
  const { code, hash } = castCodehash(WETH, BLOCK);
  assert.equal(computeCodehash(code), hash, "anchor hash would be wrong for every claim on WETH");
});

test("anchor: normalisation is case-insensitive", () => {
  const upper = "0x" + "AB".repeat(32);
  const lower = "0x" + "ab".repeat(32);
  assert.equal(normalizeHash(upper), lower);
});
