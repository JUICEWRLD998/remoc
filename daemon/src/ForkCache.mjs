// SPDX-License-Identifier: MIT
//
// ForkCache — one anvil fork per (chainId, blockNumber, codehash).
//
// WHY KEYED THIS WAY: the fork's state is a pure function of the pin. Two jobs against the same
// (chain, block, code) must observe identical state, so they must share one fork — otherwise a
// re-run could silently observe a different chain head. Caching by requestId or jobHash would
// defeat the determinism the whole mechanism rests on.
//
// Each entry owns a dedicated PORT so forks do not collide, and a fork is torn down explicitly.

import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";

export class ForkStartFailed extends Error {
  constructor(key, stderr) {
    super(`anvil failed to start for ${key}: ${stderr.slice(0, 400)}`);
    this.name = "ForkStartFailed";
  }
}

export const forkKey = ({ chainId, blockNumber, codehash }) =>
  `${chainId}:${blockNumber}:${codehash.toLowerCase()}`;

export class Fork {
  constructor({ url, port, proc, key }) {
    this.url = url;
    this.port = port;
    this.proc = proc;
    this.key = key;
    this._stopped = false;
  }

  stop() {
    if (this._stopped) return;
    this._stopped = true;
    try {
      this.proc.kill("SIGKILL");
    } catch {
      /* already gone */
    }
  }
}

export class ForkCache {
  /**
   * @param {{rpcUrl: string, startPort?: number, log?: Function}} opts
   */
  constructor(opts) {
    if (!opts?.rpcUrl) throw new Error("ForkCache requires an upstream rpcUrl");
    this.rpcUrl = opts.rpcUrl;
    this.startPort = opts.startPort ?? 8600;
    this.log = opts.log ?? (() => {});
    /** @type {Map<string, Fork>} */
    this._forks = new Map();
    this._nextPort = this.startPort;
  }

  /**
   * Get or create the fork for this key. Concurrent callers for the same key share one fork.
   * @param {{chainId: number, blockNumber: number, codehash: string}} spec
   */
  async get(spec) {
    const key = forkKey(spec);

    const existing = this._forks.get(key);
    if (existing && !existing._stopped) {
      this.log(`fork cache HIT  ${key}`);
      return existing;
    }

    // Store the PROMISE so a second concurrent caller awaits the same spawn rather than
    // starting a duplicate anvil on the same port.
    const pending = this._spawn(key, spec);
    this._forks.set(key, pending);
    try {
      return await pending;
    } catch (e) {
      this._forks.delete(key);
      throw e;
    }
  }

  async _spawn(key, { blockNumber }) {
    const port = this._nextPort++;
    this.log(`fork cache MISS ${key} -> spawning anvil on :${port}`);

    const proc = spawn(
      "anvil",
      [
        "--fork-url",
        this.rpcUrl,
        "--fork-block-number",
        String(blockNumber),
        "--port",
        String(port),
        "--silent",
      ],
      { stdio: ["ignore", "pipe", "pipe"] }
    );

    let stderr = "";
    proc.stderr.on("data", (d) => (stderr += d.toString()));

    let exited = false;
    proc.on("exit", () => (exited = true));

    const url = `http://127.0.0.1:${port}`;

    // Poll readiness. A fixed sleep would be a race on a slow machine, and an unready fork
    // returns EMPTY results rather than failing — the exact silent-wrong we must avoid.
    const deadline = Date.now() + 60_000;
    while (Date.now() < deadline) {
      if (exited) throw new ForkStartFailed(key, stderr || "(exited with no stderr)");
      try {
        const r = await fetch(url, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_blockNumber", params: [] }),
          signal: AbortSignal.timeout(3000),
        });
        const j = await r.json();
        if (j.result !== undefined) {
          const got = parseInt(j.result, 16);
          if (got !== Number(blockNumber)) {
            // A fork serving the wrong height is not a degraded fork, it is a WRONG one.
            proc.kill("SIGKILL");
            throw new Error(`fork pinned at ${blockNumber} reports height ${got}`);
          }
          await this._assertForkServesState(url, key);
          return new Fork({ url, port, proc, key });
        }
      } catch (e) {
        if (/reports height/.test(String(e.message))) throw e;
      }
      await delay(250);
    }

    proc.kill("SIGKILL");
    throw new ForkStartFailed(key, stderr || "(timed out waiting for readiness)");
  }

  /**
   * Positive control at startup: an anvil that answers blockNumber but serves no code is
   * useless, and would look identical to a healthy one until a job silently returned nothing.
   * WETH's code must be present at the pin.
   */
  async _assertForkServesState(url, key) {
    const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
    const r = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "eth_getCode",
        params: [WETH, "latest"],
      }),
      signal: AbortSignal.timeout(5000),
    });
    const j = await r.json();
    const bytes = j.result ? (j.result.length - 2) / 2 : 0;
    if (bytes === 0) {
      throw new Error(`fork ${key} started but serves no state (WETH code empty)`);
    }
  }

  /** Tear down one fork. */
  release(spec) {
    const key = forkKey(spec);
    const f = this._forks.get(key);
    if (f) {
      Promise.resolve(f).then((fork) => fork.stop?.()).catch(() => {});
      this._forks.delete(key);
    }
  }

  /** Tear down every fork. Always call this in a finally block. */
  async closeAll() {
    const all = [...this._forks.values()];
    this._forks.clear();
    for (const f of all) {
      try {
        const fork = await f;
        fork.stop();
      } catch {
        /* never started */
      }
    }
  }

  get size() {
    return this._forks.size;
  }
}
