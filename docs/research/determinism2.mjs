import { createHash } from "node:crypto";

const EULER = "0x27182842E098f60e3D576794A5bFFb0777E025d3";
const BLK = 16700000;
const HEX = "0x" + BLK.toString(16);
const sha = (s) => createHash("sha256").update(s).digest("hex");

const RPCS = [
  "https://eth.drpc.org",
  "https://eth-mainnet.public.blastapi.io",
  "https://rpc.payload.de",
  "https://eth.merkle.io",
  "https://mainnet.gateway.tenderly.co",
  "https://ethereum.blockpi.network/v1/rpc/public",
  "https://api.securerpc.com/v1",
  "https://eth.public-rpc.com",
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function rpc(url, method, params, tries = 3) {
  for (let i = 0; i < tries; i++) {
    try {
      const r = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
        signal: AbortSignal.timeout(20000),
      });
      const txt = await r.text();
      let j;
      try { j = JSON.parse(txt); } catch { throw new Error("non-json: " + txt.slice(0, 60)); }
      if (j.error) {
        const msg = JSON.stringify(j.error).slice(0, 100);
        if (/429|compute unit|rate|limit/i.test(msg) && i < tries - 1) { await sleep(4000); continue; }
        throw new Error(msg);
      }
      return j.result;
    } catch (e) {
      if (i === tries - 1) throw e;
      await sleep(3000);
    }
  }
}

const out = [];
for (const url of RPCS) {
  try {
    const block = await rpc(url, "eth_getBlockByNumber", [HEX, false]);
    await sleep(600);
    const code = await rpc(url, "eth_getCode", [EULER, HEX]);
    out.push({
      url, ok: true,
      hash: block.hash,
      stateRoot: block.stateRoot,
      ts: new Date(parseInt(block.timestamp, 16) * 1000).toISOString(),
      bytes: (code.length - 2) / 2,
      codeSha: sha(code),
    });
    console.log("OK   " + url.padEnd(48) + " code=" + out.at(-1).bytes + "B sha=" + out.at(-1).codeSha.slice(0, 16));
  } catch (e) {
    out.push({ url, ok: false, err: e.message.slice(0, 90) });
    console.log("FAIL " + url.padEnd(48) + e.message.slice(0, 80));
  }
  await sleep(1200);
}

const good = out.filter((r) => r.ok);
console.log("\n--- CROSS-PROVIDER VERDICT (" + good.length + " providers answered) ---");
if (good.length < 2) {
  console.log("  fewer than 2 providers answered - cannot conclude");
} else {
  const uniq = (k) => [...new Set(good.map((r) => r[k]))];
  const hashes = uniq("hash"), roots = uniq("stateRoot"), codes = uniq("codeSha");
  console.log("  distinct blockHash values :", hashes.length);
  console.log("  distinct stateRoot values :", roots.length);
  console.log("  distinct code hashes      :", codes.length);
  const okAll = hashes.length === 1 && roots.length === 1 && codes.length === 1;
  console.log("\n  " + (okAll
    ? "DETERMINISTIC: " + good.length + " independent providers returned IDENTICAL state at block " + BLK
    : "DIVERGENCE: providers disagree - determinism claim would be FALSE"));
}
