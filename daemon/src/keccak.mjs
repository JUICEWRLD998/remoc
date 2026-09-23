// SPDX-License-Identifier: MIT
//
// keccak256 — pure JS, no dependencies.
//
// WHY THIS EXISTS: Node's crypto module exposes `sha3-256`, which is NIST SHA-3 and is NOT
// Ethereum's keccak256. They differ only in the domain-separation padding byte (0x06 vs 0x01),
// so `sha3-256` silently produces a DIFFERENT hash for every input. Using it would make every
// anchor check and every predicateId wrong, while looking entirely plausible.
//
// Verified against known vectors and cross-checked against `cast keccak` in test/keccak.test.mjs.
// A hash function with no positive control is the most dangerous kind of wrong.

const MASK64 = (1n << 64n) - 1n;
const RATE = 136; // 1088 bits for keccak-256

// Round constants for Keccak-f[1600], 24 rounds.
const RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];

// Rotation offsets, indexed [x][y].
const ROT = [
  [0, 36, 3, 41, 18],
  [1, 44, 10, 45, 2],
  [62, 6, 43, 15, 61],
  [28, 55, 25, 21, 56],
  [27, 20, 39, 8, 14],
];

function rotl(v, n) {
  if (n === 0) return v & MASK64;
  const b = BigInt(n);
  return ((v << b) | (v >> (64n - b))) & MASK64;
}

function keccakF(A) {
  for (let round = 0; round < 24; round++) {
    // theta
    const C = new Array(5);
    for (let x = 0; x < 5; x++) {
      C[x] = A[x][0] ^ A[x][1] ^ A[x][2] ^ A[x][3] ^ A[x][4];
    }
    for (let x = 0; x < 5; x++) {
      const D = C[(x + 4) % 5] ^ rotl(C[(x + 1) % 5], 1);
      for (let y = 0; y < 5; y++) A[x][y] ^= D;
    }

    // rho + pi
    const B = Array.from({ length: 5 }, () => new Array(5).fill(0n));
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        B[y][(2 * x + 3 * y) % 5] = rotl(A[x][y], ROT[x][y]);
      }
    }

    // chi
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        A[x][y] = B[x][y] ^ ((~B[(x + 1) % 5][y] & MASK64) & B[(x + 2) % 5][y]);
      }
    }

    // iota
    A[0][0] ^= RC[round];
  }
}

/// @notice keccak256 of a byte array (Uint8Array) -> 32-byte Uint8Array.
export function keccak256(bytes) {
  const input = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);

  // pad10*1 with the Keccak domain byte 0x01 (Ethereum), NOT 0x06 (NIST SHA-3).
  const padded = new Uint8Array(Math.ceil((input.length + 1) / RATE) * RATE);
  padded.set(input);
  padded[input.length] ^= 0x01;
  padded[padded.length - 1] ^= 0x80;

  const A = Array.from({ length: 5 }, () => new Array(5).fill(0n));

  for (let off = 0; off < padded.length; off += RATE) {
    // Absorb: XOR each 8-byte little-endian word into lane (x + 5y).
    for (let i = 0; i < RATE / 8; i++) {
      let lane = 0n;
      for (let b = 7; b >= 0; b--) {
        lane = (lane << 8n) | BigInt(padded[off + i * 8 + b]);
      }
      const idx = i;
      A[idx % 5][Math.floor(idx / 5)] ^= lane;
    }
    keccakF(A);
  }

  // Squeeze 32 bytes.
  const out = new Uint8Array(32);
  for (let i = 0; i < 4; i++) {
    let lane = A[i % 5][Math.floor(i / 5)];
    for (let b = 0; b < 8; b++) {
      out[i * 8 + b] = Number(lane & 0xffn);
      lane >>= 8n;
    }
  }
  return out;
}

/// @notice keccak256 of a UTF-8 string -> 32-byte Uint8Array.
export function keccakUtf8(str) {
  return keccak256(new TextEncoder().encode(str));
}

export function toHex(bytes) {
  return "0x" + Buffer.from(bytes).toString("hex");
}

export function fromHex(hex) {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  return new Uint8Array(Buffer.from(h, "hex"));
}

/// @notice keccak256 of a hex string's BYTES (not of the hex characters).
export function keccakHex(hex) {
  return keccak256(fromHex(hex));
}
