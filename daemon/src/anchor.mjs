// SPDX-License-Identifier: MIT
//
// The anchor: `keccak256(getCode(target, pinnedBlock)) === expectedCodehash`.
//
// This is remoc's second non-negotiable constraint. A claim asserts something about a SPECIFIC
// contract's DEPLOYED BYTECODE at a SPECIFIC BLOCK. If the daemon executes the steps without
// first certifying that the code really hashes to what the claim committed, then it is replaying
// against whatever happens to be at that address — and the verdict, however confidently
// reported, is about different code than the one filed.
//
// The check is deliberately a hard precondition, not a warning: `AnchorMismatch` aborts the job.
// A verifier that "proceeds anyway and notes the discrepancy" has already produced a lie.

import { keccak256, toHex } from "./keccak.mjs";

/** The code hash of an address holding no code. Matches Solidity `keccak256("")`. */
export const EMPTY_CODEHASH = toHex(keccak256(new Uint8Array()));

export class AnchorMismatch extends Error {
  constructor({ target, blockNumber, expected, actual, codeBytes }) {
    super(
      `ANCHOR_MISMATCH: codehash at ${target} @ block ${blockNumber} is ${actual}, ` +
        `but the claim committed ${expected} (code is ${codeBytes} bytes). ` +
        `Refusing to execute: the verdict would be about different code than was filed.`
    );
    this.name = "AnchorMismatch";
    this.expected = expected;
    this.actual = actual;
    this.codeBytes = codeBytes;
  }
}

export class NoCodeAtTarget extends Error {
  constructor(target, blockNumber, actual) {
    super(
      `NO_CODE_AT_TARGET: ${target} @ block ${blockNumber} has no code (codehash ${actual}). ` +
        `There is nothing to be right or wrong about.`
    );
    this.name = "NoCodeAtTarget";
  }
}

/** Normalise a codehash for comparison: lowercase, 0x-prefixed, 32 bytes. */
export function normalizeHash(h) {
  const s = String(h ?? "").trim().toLowerCase();
  if (!/^0x[0-9a-f]{64}$/.test(s)) {
    throw new Error(`not a 32-byte hex hash: ${JSON.stringify(h)}`);
  }
  return s;
}

/** Hash raw `eth_getCode` output. */
export function computeCodehash(codeHex) {
  if (typeof codeHex !== "string" || !codeHex.startsWith("0x")) {
    throw new Error(`getCode returned a non-hex value: ${JSON.stringify(codeHex)}`);
  }
  return toHex(keccak256(Buffer.from(codeHex.slice(2), "hex")));
}

/**
 * Certify the anchor. Throws rather than returning a boolean, so no caller can forget to check
 * the result and proceed with an uncertified job.
 *
 * @returns {{codehash: string, codeBytes: number, code: string}} the certified code
 */
export function verifyAnchor({ codeHex, expectedCodehash, target, blockNumber }) {
  const expected = normalizeHash(expectedCodehash);
  const codeBytes = (codeHex.length - 2) / 2;
  const actual = computeCodehash(codeHex);

  if (codeBytes === 0) throw new NoCodeAtTarget(target, blockNumber, actual);

  if (actual !== expected) {
    throw new AnchorMismatch({ target, blockNumber, expected, actual, codeBytes });
  }

  return { codehash: actual, codeBytes, code: codeHex };
}

/**
 * Fetch code at a pinned block and certify it in one step.
 * @param {{getCode: Function}} provider
 */
export async function certify({ provider, target, blockNumber, expectedCodehash }) {
  const codeHex = await provider.getCode(target, blockNumber);
  return verifyAnchor({ codeHex, expectedCodehash, target, blockNumber });
}
