// Test: keccak256 must match Ethereum's keccak256 exactly.
//
// The planted positive control here is `cast keccak`, which is authoritative. Known-vector
// literals alone would be checked against my own memory; shelling out to cast checks them
// against the tool the contracts are actually built with.

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";

import { keccak256, keccakUtf8, keccakHex, toHex, fromHex } from "../src/keccak.mjs";

function castKeccakUtf8(s) {
  // `cast keccak` hashes the STRING argument's bytes.
  return execFileSync("cast", ["keccak", s], { encoding: "utf8" }).trim();
}

function castKeccakBytes(hex) {
  return execFileSync("cast", ["keccak", hex], { encoding: "utf8" }).trim();
}

test("keccak256 matches cast for empty input", () => {
  const expected = castKeccakBytes("0x"); // empty byte string
  assert.equal(toHex(keccak256(new Uint8Array())), expected);
});

test("keccak256 matches cast for short strings", () => {
  for (const s of ["", "a", "abc", "hello world", "remoc"]) {
    const expected = castKeccakUtf8(s);
    assert.equal(toHex(keccakUtf8(s)), expected, `mismatch for ${JSON.stringify(s)}`);
  }
});

test("keccak256 matches cast for the well-known long vector", () => {
  const s = "The quick brown fox jumps over the lazy dog";
  assert.equal(toHex(keccakUtf8(s)), castKeccakUtf8(s));
});

test("keccak256 handles inputs spanning multiple absorb blocks", () => {
  // RATE is 136 bytes; cross it deliberately, including exactly on the boundary.
  for (const n of [135, 136, 137, 271, 272, 273, 1000]) {
    const s = "x".repeat(n);
    assert.equal(toHex(keccakUtf8(s)), castKeccakUtf8(s), `mismatch at length ${n}`);
  }
});

test("keccak256 handles all byte values (non-ASCII safe)", () => {
  const bytes = new Uint8Array(256);
  for (let i = 0; i < 256; i++) bytes[i] = i;
  assert.equal(toHex(keccak256(bytes)), castKeccakBytes("0x" + Buffer.from(bytes).toString("hex")));
});

test("keccak256 matches cast for real deployed bytecode", () => {
  // The anchor check hashes contract CODE. Use a real address's code to prove the shape.
  const code = execFileSync(
    "cast",
    ["code", "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", "--rpc-url", "https://eth.drpc.org"],
    { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 }
  ).trim();
  if (!code || code === "0x") {
    // Do not let a network failure masquerade as a pass.
    assert.fail("could not fetch WETH code — cannot run the bytecode vector");
  }
  const mine = toHex(keccakHex(code));
  const theirs = execFileSync("cast", ["keccak", code], { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 }).trim();
  assert.equal(mine, theirs, "code hash mismatch — the anchor would be wrong for every claim");
});

test("NEGATIVE CONTROL: the empty-string hash is NOT the NIST sha3 zero-len hash", () => {
  // Keccak-256("") = c5d24601... ; NIST SHA3-256("") = a7ffc6f8...
  // If these ever collide, this implementation silently became SHA-3 and every anchor is wrong.
  const mine = toHex(keccak256(new Uint8Array()));
  assert.equal(mine, "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
  assert.notEqual(mine, "0xa7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a");
});

test("fromHex/toHex round-trip", () => {
  const hex = "0xdeadbeef";
  assert.equal(toHex(fromHex(hex)), hex);
});
