// SPDX-License-Identifier: MIT
//
// Minimal ABI helpers — enough to decode exactly the shapes remoc commits, and no more.
//
// WHY HAND-ROLLED: the daemon takes no dependencies (Node 24 has fetch/WebSocket built in), and
// remoc's committed shapes are narrow and fixed. But hand-decoding is where silently-wrong values
// come from, so every function here VALIDATES LENGTH and THROWS on anything unexpected. Nothing
// truncates, nothing pads, nothing returns a default. A decoder that guesses produces a confident
// wrong verdict, which is worse than a crash.

export class AbiDecodeError extends Error {
  constructor(msg) {
    super(`ABI decode failed: ${msg}`);
    this.name = "AbiDecodeError";
  }
}

const hexToBytes = (h) => Buffer.from(h.startsWith("0x") ? h.slice(2) : h, "hex");

/** A 32-byte word as a BigInt. */
export function wordToUint(word) {
  if (typeof word !== "string" || word.length !== 64) {
    throw new AbiDecodeError(`expected a 32-byte word, got ${JSON.stringify(word)?.slice(0, 40)}`);
  }
  return BigInt("0x" + word);
}

/** A 32-byte word as a checksum-agnostic lowercase address. */
export function wordToAddress(word) {
  const v = wordToUint(word);
  if (v >> 160n !== 0n) throw new AbiDecodeError("address word has non-zero high bytes");
  return "0x" + v.toString(16).padStart(40, "0");
}

/** uint256 -> decimal string (JSON-safe). */
export const uintToString = (v) => v.toString(10);

/**
 * Decode `abi.encode(address target, address sender, uint256 value, bytes data)`.
 * @param {string} hex
 * @returns {{target: string, sender: string, value: bigint, data: string}}
 */
export function decodeStep(hex) {
  const bytes = hexToBytes(hex);
  if (bytes.length < 128) {
    throw new AbiDecodeError(`step tuple needs >= 128 bytes, got ${bytes.length}`);
  }
  const words = bytes.length / 32;
  if (bytes.length % 32 !== 0) {
    throw new AbiDecodeError(`step tuple must be whole words, got ${bytes.length} bytes`);
  }

  const target = wordToAddress(bytes.subarray(0, 32).toString("hex"));
  const sender = wordToAddress(bytes.subarray(32, 64).toString("hex"));
  const value = wordToUint(bytes.subarray(64, 96).toString("hex"));

  const offset = Number(wordToUint(bytes.subarray(96, 128).toString("hex")));
  if (offset !== 128) {
    throw new AbiDecodeError(`bytes offset must be 128 for a 4-field tuple, got ${offset}`);
  }
  if (offset / 32 >= words) throw new AbiDecodeError("bytes offset points past the payload");

  const len = Number(wordToUint(bytes.subarray(offset, offset + 32).toString("hex")));
  const dataStart = offset + 32;
  if (len > bytes.length - dataStart) {
    throw new AbiDecodeError(`bytes length ${len} exceeds remaining payload ${bytes.length - dataStart}`);
  }
  const data = "0x" + bytes.subarray(dataStart, dataStart + len).toString("hex");

  return { target, sender, value, data };
}

/**
 * Decode fixed-size predicate params: `n` consecutive 32-byte words.
 * @returns {bigint[]}
 */
export function decodeWords(hex, n) {
  const bytes = hexToBytes(hex);
  if (bytes.length !== n * 32) {
    throw new AbiDecodeError(`expected ${n} words (${n * 32} bytes), got ${bytes.length}`);
  }
  const out = [];
  for (let i = 0; i < n; i++) out.push(wordToUint(bytes.subarray(i * 32, i * 32 + 32).toString("hex")));
  return out;
}

/** First 4 bytes of calldata as 0x-prefixed hex, or null when there is no selector. */
export function selectorOf(data) {
  const hex = data.startsWith("0x") ? data.slice(2) : data;
  if (hex.length < 8) return null;
  return "0x" + hex.slice(0, 8).toLowerCase();
}

/** bytes4 right-padded in a word -> "0x12345678" */
export function wordToSelector(word) {
  const v = wordToUint(word);
  const hex = v.toString(16).padStart(8, "0");
  return "0x" + hex;
}

/** A uint256 result word from `returnData`, or null if the payload is empty. */
export function firstWordOf(returnData) {
  const hex = returnData.startsWith("0x") ? returnData.slice(2) : returnData;
  if (hex.length < 64) return null;
  return BigInt("0x" + hex.slice(0, 64));
}

/**
 * Decode `abi.encode(Step[] steps)` where
 * `struct Step { address target; address sender; uint256 value; bytes data; }`.
 *
 * WHY A SEQUENCE AND NOT ONE CALL: the interesting bugs are not reachable from a cold account.
 * Reproducing the Euler V1 defect requires a position and outstanding debt first, exactly as the
 * Foundry fixture sets up with `deal` + `deposit` + `borrow`. A single-call job cannot express
 * that, so jobs carry a step list and the daemon sends real transactions for the leading steps
 * and treats the FINAL step's outcome as the observation.
 *
 * @returns {{target: string, sender: string, value: bigint, data: string}[]}
 */
export function decodeSteps(hex) {
  const bytes = hexToBytes(hex);
  if (bytes.length < 64) throw new AbiDecodeError(`steps payload too short: ${bytes.length} bytes`);
  if (bytes.length % 32 !== 0) {
    throw new AbiDecodeError(`steps payload must be whole words, got ${bytes.length} bytes`);
  }

  const readWord = (at) => {
    if (at + 32 > bytes.length) throw new AbiDecodeError(`read past payload at byte ${at}`);
    return wordToUint(bytes.subarray(at, at + 32).toString("hex"));
  };

  // Single dynamic array parameter: a head word pointing at the array.
  const arrOffset = Number(readWord(0));
  if (arrOffset >= bytes.length) throw new AbiDecodeError(`array offset ${arrOffset} past payload`);

  const len = Number(readWord(arrOffset));
  const elementBase = arrOffset + 32;
  if (len === 0) throw new AbiDecodeError("steps array is empty");
  if (len > 64) throw new AbiDecodeError(`implausible step count ${len}`);

  const out = [];
  for (let i = 0; i < len; i++) {
    const elemRel = Number(readWord(elementBase + i * 32));
    const elemStart = elementBase + elemRel;
    if (elemStart + 128 > bytes.length) {
      throw new AbiDecodeError(`step ${i} tuple head past payload`);
    }

    const target = wordToAddress(bytes.subarray(elemStart, elemStart + 32).toString("hex"));
    const sender = wordToAddress(bytes.subarray(elemStart + 32, elemStart + 64).toString("hex"));
    const value = wordToUint(bytes.subarray(elemStart + 64, elemStart + 96).toString("hex"));
    const dataRel = Number(readWord(elemStart + 96));
    if (dataRel !== 128) {
      throw new AbiDecodeError(`step ${i} bytes offset must be 128, got ${dataRel}`);
    }

    const dataStart = elemStart + dataRel;
    const dataLen = Number(readWord(dataStart));
    const payloadStart = dataStart + 32;
    if (dataLen > bytes.length - payloadStart) {
      throw new AbiDecodeError(`step ${i} data length ${dataLen} exceeds payload`);
    }

    out.push({
      target,
      sender,
      value,
      data: "0x" + bytes.subarray(payloadStart, payloadStart + dataLen).toString("hex"),
    });
  }
  return out;
}

