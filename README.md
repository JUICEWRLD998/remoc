# remoc

**Bonded, executable claims about deployed contract code — settled by replay, not opinion.**

Anyone can file a claim that a contract's deployed bytecode was broken, backed by a bond. A verifier
pins the block, checks the codehash anchor, replays the call sequence against a fork, and the assertion
either holds or fails. The verdict is on-chain, reproducible by any third party, and consumable by other
contracts.

Built for **3rd-Web-Hack** (TechZap Club).

---

## Why this exists

1,283 incidents and **$20.66B** in cumulative losses (DefiLlama incident corpus). Not one of those
verdicts is a fact anybody can replay — a finding is a PDF, a contest submission, or a summary, and a
human decides whether to believe it.

remoc makes the claim itself the artifact. A claim is **falsifiable** — anyone can establish its truth
without trusting its author — and because it is bonded, nonsense self-eliminates. The verdict is not an
opinion, it is a replay.

**What blockchain adds here is not storage.** The verdict is consumed by other contracts — a lending
market can read `assertionsHeldFor(codehash)` before accepting collateral. That composability is the
reason this is on-chain.

---

## Verified fixtures

Every claim below is reproducible by a third party on a plain fork of a pinned block. All four run on
**free public infrastructure** — no API key, no paid endpoint.

```
forge test --fork-url https://eth.drpc.org --fork-block-number 16700000
→ 3 suites, 7 tests passed, 0 failed
```

### The predicate, stated once, evaluated on two protocols

> *"An unprivileged account can reduce its own collateral until the account is unhealthy, and the call
> does not revert."*

| Protocol | At block 16,700,000 | Verdict |
|---|---|---|
| **Euler V1** | **TRUE** — `donateToReserves` does exactly this, with no post-op liquidity check | **REFUTED** |
| **Aave V3** | **FALSE** — reverts `35` (`HEALTH_FACTOR_LOWER_THAN_LIQUIDATION_THRESHOLD`) | **HELD** |

Same assertion, opposite verdicts. This falsification pair is the point: an assertion that always "finds
a bug" is a rubber stamp, and an always-true predicate would have "passed" the Euler run too.

`EulerInvariant.t.sol` reproduces the defect behind the **2023-03-13 Euler V1 incident ($197M,
Ethereum)** — collateral `97.529e18 → 1e18` with debt outstanding, call **not** reverting, while the
equivalent checked withdrawal reverts `e/collateral-violation`.

### Prospective: a verdict on code that is not live

`TimelockPending.t.sol` produces a verdict against an implementation the timelock has only **scheduled** —
`proxy.implementation()` is still `V1`, `timelock.isReady(id) == false`, and the verdict exists anyway.

> *"Euler proves we can be right about a $197M bug that already happened. This one is code that isn't
> live yet — and we have a verdict on it now, before the timelock fires."*

**Limitation, stated plainly:** this fixture is a real mechanism demonstrated on **authored** code, not a
bug found in a live protocol. The mainnet target is not yet sourced (see `IMPLEMENTATION.md` §0.4 and
risk #11). Do not read it as a disclosure against any named protocol.

---

## Design constraints

Three rules are load-bearing. Breaking any one turns the mechanism into theatre.

1. **Assertion bytes are committed on-chain**, never an off-chain reference. If a verifier could report
   on different predicate bytes than were filed, it could commit fraud undetected. With the bytes
   on-chain, anyone re-runs exactly what was filed.
2. **The codehash anchor is checked before execution** — `keccak256(getCode(target, pinnedBlock)) ==
   claimed`. Without it, replayed state ≠ claimed state.
3. **The verifier role is permissionless, staked, and challengeable.** Only *liveness* is delegated —
   never correctness. Verified cross-provider: three independent RPCs returned identical `blockHash`,
   `stateRoot`, and bytecode `sha256` at block 16,700,000.

---

## Repository layout

```
contracts/                      Foundry project (forge 1.8.1, solc 0.8.19)
  src/fixture/PendingProtocol.sol   Phase 0.4 prospective fixture (dependency-free)
  test/fixtures/EulerInvariant.t.sol  the $197M defect reproduces
  test/fixtures/AaveHolds.t.sol       the falsification pair
  test/fixtures/TimelockPending.t.sol verdict on not-yet-live code
docs/research/                  evidence scripts (re-run them yourself)
  determinism2.mjs              cross-provider replay determinism
  fixture.mjs                   historical bytecode retrieval
  probe.sh                      free-tier RPC capability probe
IMPLEMENTATION.md               build plan, phase gates, risk register
IDEA_REMOC.md                   the idea brief
```

`contracts/lib/forge-std` is **vendored** deliberately, so `forge test` works on a plain `git clone`
with no submodule step.

---

## Setup

Requires [Foundry](https://book.getfoundry.sh/) (tested with 1.8.1) and Node 24+ for the research
scripts. No API keys needed.

```bash
git clone https://github.com/JUICEWRLD998/remoc.git
cd remoc/contracts
forge build
forge test --fork-url https://eth.drpc.org --fork-block-number 16700000
```

The `--fork-url` and `--fork-block-number` flags are required for the fixture suites. `drpc.org` carried
the full run without rate-limiting; `eth-mainnet.public.blastapi.io` also works but 429s under burst
(free tiers are compute-unit capped), so the daemon rotates providers.

### Reproduce the headline claim

```bash
forge test --match-test test_donateToReserves_skipsHealthCheck \
  --fork-url https://eth.drpc.org --fork-block-number 16700000 -vv
```

Expect: collateral falls `97.529e18 → 1e18` against outstanding debt, and the call **does not revert**.
Then run `test_control_withdraw_isChecked` and watch the same collateral reduction revert
`e/collateral-violation`.

---

## Status

| Phase | Scope | State |
|---|---|---|
| **0** | Kill-switch de-risking (4 gates) | ✅ **complete** — all green, no fixture swap needed |
| **1** | Protocol contracts + frozen interface | ✅ **complete** — 8 contracts, 27 tests, build exit 0 |
| 2 | Verifier daemon | not started |
| 3 | Fixtures wired to the protocol | not started |
| 4 | Bonds, proofs, dispute path | partially done (bond/proof path live and tested; bisection + reward pool deferred) |
| 5 | Frontend | not started |
| 6 | Submission artifacts | not started |

See `IMPLEMENTATION.md` for the phase gates, the risk register, and the open items.

---

## Known gaps

Honest list — these are real, and they are stated here rather than left for a judge to find:

- **No claim-authoring layer.** Assertions are currently hand-written. A non-expert cannot yet state a
  falsifiable claim, and that gap is what stands between this and a product.
- **No paying actor yet wired.** The bond punishes a wrong filer but does not yet reward a correct one.
- **Predicate coverage is narrow by design** — deterministic classes only (unauthorized privileged state
  change, invariant/bound violations, malformed accounting, missing post-op checks). Everything else
  stays human.
- **Phase 0.4's mainnet target is unsourced** — the mechanism is proven, the live disclosure is not.
- **The verifier daemon is off-chain.** Correctness is not delegated (replay is deterministic and
  cross-provider reproducible); *liveness* is, and that is closed by permissionless staking plus a
  challenge window.
