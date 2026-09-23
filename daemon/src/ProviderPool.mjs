// SPDX-License-Identifier: MIT
//
// ProviderPool — rotates across free archive RPCs, backs off on rate limits, and FAILS LOUDLY
// when every provider is exhausted.
//
// WHY THIS EXISTS (measured, not assumed): free tiers rate-limit. During Phase 0,
// `eth-mainnet.public.blastapi.io` returned HTTP 429 "exceeded its compute units per second"
// under burst, `eth.merkle.io` returned "Rate limit exceeded", and `eth.public-rpc.com`
// returned "Unauthorized". `eth.drpc.org` and Tenderly carried the full run cleanly.
//
// The dangerous failure mode is NOT an exception — it is a provider that returns an empty or
// null result that the caller then treats as real state. A scanner that returns nothing and a
// scanner that is broken look identical from the inside, so every path here either returns
// validated data or throws. No method returns `null` on failure.

/** Raised when every provider has been tried and none produced a usable result. */
export class AllProvidersFailed extends Error {
  constructor(attempts) {
    const detail = attempts.map((a) => `  ${a.url} -> ${a.error}`).join("\n");
    super(`all ${attempts.length} RPC providers failed:\n${detail}`);
    this.name = "AllProvidersFailed";
    this.attempts = attempts;
  }
}

/** Raised when a provider returns a JSON-RPC error we do not retry (e.g. a bad selector). */
export class RpcError extends Error {
  constructor(url, error) {
    super(`${url} returned RPC error: ${JSON.stringify(error).slice(0, 200)}`);
    this.name = "RpcError";
    this.rpcError = error;
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Retryable = worth trying another provider for. Rate limits and transport errors are. */
function isRetryable(message) {
  return /429|rate|limit|compute unit|timeout|ECONNRESET|fetch failed|502|503|504|capacity|unauthoriz|forbidden/i.test(
    String(message)
  );
}

export class ProviderPool {
  /**
   * @param {string[]} urls archive-capable JSON-RPC endpoints
   * @param {{timeoutMs?: number, maxRounds?: number, log?: (msg: string) => void}} [opts]
   */
  constructor(urls, opts = {}) {
    if (!Array.isArray(urls) || urls.length === 0) {
      throw new Error("ProviderPool requires at least one RPC url");
    }
    this.urls = [...urls];
    this.timeoutMs = opts.timeoutMs ?? 20_000;
    this.maxRounds = opts.maxRounds ?? 3;
    this.log = opts.log ?? (() => {});
    // Start each provider at a different offset so concurrent callers do not all stampede
    // the same endpoint first.
    this._cursor = 0;
    this._failures = new Map(this.urls.map((u) => [u, 0]));
  }

  /** Order providers with the currently-healthiest first, breaking ties by rotation. */
  _order() {
    const n = this.urls.length;
    const start = this._cursor++ % n;
    const rotated = Array.from({ length: n }, (_, i) => this.urls[(start + i) % n]);
    return rotated.sort((a, b) => (this._failures.get(a) ?? 0) - (this._failures.get(b) ?? 0));
  }

  /**
   * Perform a JSON-RPC call, rotating providers on retryable failure.
   *
   * @returns the `result` field. Throws `AllProvidersFailed` if none succeed — it NEVER
   *          returns null/undefined to signal failure, because a caller that forgot to check
   *          would then hash `null` into an anchor and produce a confidently wrong verdict.
   */
  async call(method, params) {
    const attempts = [];

    for (let round = 0; round < this.maxRounds; round++) {
      for (const url of this._order()) {
        try {
          const result = await this._callOnce(url, method, params);
          this._failures.set(url, 0);
          return result;
        } catch (e) {
          attempts.push({ url, error: e.message.slice(0, 120) });

          if (e instanceof RpcError && !isRetryable(e.message)) {
            // A genuine protocol-level error (bad selector, unknown block). Retrying another
            // provider would just repeat it, and swallowing it would hide a real bug.
            throw e;
          }
          this._failures.set(url, (this._failures.get(url) ?? 0) + 1);
        }
      }

      if (round < this.maxRounds - 1) {
        const backoff = 500 * 2 ** round; // 500ms, 1s, 2s
        this.log(`all providers failed round ${round + 1}; backing off ${backoff}ms`);
        await sleep(backoff);
      }
    }

    throw new AllProvidersFailed(attempts);
  }

  async _callOnce(url, method, params) {
    let res;
    try {
      res = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (e) {
      throw new Error(e.name === "TimeoutError" ? "timeout" : e.message);
    }

    const text = await res.text();
    if (!res.ok) throw new Error(`HTTP ${res.status}: ${text.slice(0, 100)}`);

    let json;
    try {
      json = JSON.parse(text);
    } catch {
      // Some endpoints return an HTML error page with HTTP 200. Never let that read as data.
      throw new Error(`non-JSON response: ${text.slice(0, 100)}`);
    }

    if (json.error) throw new RpcError(url, json.error);
    if (json.result === undefined) throw new Error("response had no result field");
    return json.result;
  }

  // --------------------------------------------------------------- convenience

  blockNumber() {
    return this.call("eth_blockNumber", []).then((h) => parseInt(h, 16));
  }

  getCode(address, blockNumber) {
    return this.call("eth_getCode", [address, "0x" + Number(blockNumber).toString(16)]);
  }

  getBlockByNumber(blockNumber) {
    return this.call("eth_getBlockByNumber", ["0x" + Number(blockNumber).toString(16), false]);
  }
}
