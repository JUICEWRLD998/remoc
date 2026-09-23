// SPDX-License-Identifier: MIT
//
// Minimal ABI encoder — just enough to build the step lists remoc commits.
// Mirrors `decodeSteps` in abi.mjs; the two are tested against each other and against `cast`.

import { keccakUtf8, toHex } from "./keccak.mjs";

const strip = (h) => (h.startsWith("0x") ? h.slice(2) : h);

/** 4-byte function selector for a signature string. */
export function selector(sig) {
  return toHex(keccakUtf8(sig)).slice(0, 10);
}

export const padWord = (v) => BigInt(v).toString(16).padStart(64, "0");

export const encodeAddress = (a) => strip(a).toLowerCase().padStart(64, "0");
export const encodeUint = (v) => padWord(v);

/** bytes: length word + data right-padded to a whole word. */
export function encodeBytes(hexData) {
  const h = strip(hexData);
  const pad = h.length % 64 === 0 ? "" : "0".repeat(64 - (h.length % 64));
  return padWord(h.length / 2) + h + pad;
}

/** bytes4 right-aligned in a word (as Solidity stores it). */
export const encodeBytes4 = (sel) => strip(sel).toLowerCase().padStart(64, "0");

/**
 * `abi.encode(Step[] steps)` for
 * `struct Step { address target; address sender; uint256 value; bytes data; }`.
 *
 * @param {{target: string, sender: string, value?: bigint|number, data: string}[]} steps
 */
export function encodeSteps(steps) {
  if (!Array.isArray(steps) || steps.length === 0) throw new Error("encodeSteps needs >= 1 step");

  const encoded = steps.map((s) => {
    const head =
      encodeAddress(s.target) + encodeAddress(s.sender) + padWord(s.value ?? 0n) + padWord(128);
    return head + encodeBytes(s.data);
  });

  // Element offsets are relative to the START OF THE OFFSETS REGION (i.e. right after the length
  // word), per the ABI spec — NOT relative to the elements that follow it. Getting this wrong by
  // one region is a silent mis-decode, so the decoder asserts the offsets it reads are sane.
  const offsetsBytes = steps.length * 32;
  let running = 0;
  const offsets = encoded.map((e) => {
    const off = padWord(running + offsetsBytes);
    running += e.length / 2; // bytes
    return off;
  });

  const arrayBody = padWord(steps.length) + offsets.join("") + encoded.join("");
  // Single dynamic parameter: a head word pointing past itself to the array.
  return "0x" + padWord(32) + arrayBody;
}

/** Convenience: build one step. */
export function step(target, sender, data, value = 0n) {
  return { target, sender, value, data };
}
