# remoc — implementation plan

Companion to `IDEA_remoc.md` (the winning-idea brief). This file is the build order, the exact
files, and the **exit gate each phase must pass before the next begins**.

**Byline for any artifact a stranger reads:** Mustapha Fadhlullah — independent security researcher

---

## Ground truth (verified this session — do not re-derive, do re-use)

| Fact | Value / evidence |
|---|---|
| Toolchain | `forge` / `anvil` / `cast` **1.8.1**. Node **v24.14.1**, npm 11.17.0, git 2.50.1. `solc` absent → forge auto-downloads |
| Fixture address | `0x27182842E098f60e3D576794A5bFFb0777E025d3` — Blockscout `name: "Euler"`, `is_contract: true` |
| Fixture incident | Euler V1, 2023-03-13, **$197.0M**, Ethereum, technique "Donation Attack" (DefiLlama) |
| Working pre-hack block | **16,700,000** (`2023-02-24T18:34:47Z`) — code present, 907 bytes |
| Free archive RPCs (live) | `eth.drpc.org`, `eth-mainnet.public.blastapi.io`, `mainnet.gateway.tenderly.co` |
| Cross-provider determinism | 3 providers → **1 distinct blockHash / stateRoot / code-sha256** at block 16,700,000 |
| Rate limits (real) | blastapi → HTTP 429 compute units; merkle.io → rate limit; public-rpc.com → unauthorized |
| Dead / gated RPCs | publicnode (token), ankr (token), llamarpc (525), 1rpc (301) |

**Architectural constraints that are not negotiable:**
1. **Assertion bytes are committed on-chain**, never an off-chain reference. Without this a verifier can
   report on different predicate bytes than were filed — fraud that no one can detect. This is the single
   constraint that turns the verifier from a trust-point into a commodity.
2. **The codehash anchor is checked before execution.** `keccak256(eth_getCode(target, pinnedBlock)) == claimed`.
   Without the anchor, replayed state ≠ claimed state and the whole mechanism is theatre.
3. **The verifier role is permissionless + staked + challengeable.** Correctness is already delegated to
   nobody (proven deterministic); only *liveness* is delegated, and the challenge window closes that.

---

## Phase 0 — Kill-switch. De-risk the two unproven assumptions.

**Do this before writing a single contract.** Both are cheap checks and either one failing changes the
architecture. This phase exists so a dead assumption costs minutes, not the whole build.

### 0.1 — Can `anvil` sustain a forked *execution* workload on a free tier?
Proven so far: single historical reads. **Not** proven: anvil running real txs under rate limits.

```bash
anvil --fork-url https://eth-mainnet.public.blastapi.io \
      --fork-block-number 16700000 --port 8545 &   # background
cast block-number --rpc-url http://localhost:8545   # expect 16700000
cast call 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 "totalSupply()(uint256)" \
     --rpc-url http://localhost:8545                # a real state read, not just header
cast rpc eth_getCode 0x27182842E098f60e3D576794A5bFFb0777E025d3 --rpc-url http://localhost:8545 | wc -c
```

**EXIT GATE:** all three commands return correct values and anvil survives ≥10 consecutive calls without
the upstream 429ing. If it 429s → implement provider rotation in `ProviderPool` (Phase 2) *first* and
re-test. If free tiers cannot carry a full fork at all → the demo runs on a paid endpoint and the README
states the swap plainly. **Record which happened.**

> ### ✅ RESULT 2026-09-23 — PASSED (free tier, no paid endpoint needed)
>
> Run against `https://eth.drpc.org`, fork block 16,700,000, port 8545:
>
> | Check | Command | Result |
> |---|---|---|
> | Fork pinned correctly | `cast block-number` | `16700000` ✔ |
> | Real state, not just header | `cast call WETH "totalSupply()(uint256)"` | `4018217864315500480129075` ✔ |
> | Fixture code present in fork | `cast code 0x2718…25d3` | 1817 hex chars = **907 bytes** — matches the raw-RPC read exactly ✔ |
> | Load gate | 10× `cast call` over the fork | **survived 10/10, failed 0/10**, no upstream 429 ✔ |
>
> **Verdict:** a free public RPC carries a full forked execution workload for the demo's call volume.
> Phase 2's `ProviderPool` rotation is therefore a **hardening** requirement (real 429s were observed on
> blastapi under burst), not a blocker. Note the drift guard: the fork's Euler code must stay at 907 bytes
> — if a future run reports a different size, the pin has moved and the demo is no longer replaying the
> same state. Assert that byte count in Phase 2's anchor check.

### 0.2 — Is the Euler attack replicable on a fork?
The centrepiece. A green Euler run is the demo.

```bash
# locate the canonical PostMortem PoC (euler-xyz/evk-periphery or the PostMortem repo)
cast call 0x27182842E098f60e3D576794A5bFFb0777E025d3 \
  "moduleIdToImplementation(uint256)(address)" 3 --rpc-url <rpc>   # MODULEID__ETOKEN etc.
```

**EXIT GATE:** one `forge test --fork-block-number 16700000 -vvv` that moves state in the direction the
hack moved it (borrowable capacity rises after `donateToReserves`). **If it does not reproduce → swap the
fixture now** to Beanstalk ($181M, 2022-04-17, flashloan governance) or Curve/Vyper ($61.7M, 2023-07-30).
Both are single-block, fork-replicable, and already have public PoCs. **Do not** discover this in Phase 3.

> ### ✅ RESULT 2026-09-23 — PASSED. Fixture reproduces; **no swap needed.**
>
> `contracts/test/fixtures/EulerInvariant.t.sol` — 2 passed, 0 failed.
>
> ```
> forge test --match-path test/fixtures/EulerInvariant.t.sol \
>   --fork-url https://eth.drpc.org --fork-block-number 16700000 -vv
> ```
>
> | Test | Logs | Verdict |
> |---|---|---|
> | `test_donateToReserves_skipsHealthCheck` | collateral `97529138679506196141` → `1000000000000000000`; **did NOT revert** | defect reproduced ✔ |
> | `test_control_withdraw_isChecked` | withdraw of the same magnitude **reverted `e/collateral-violation`** | control fires ✔ |
>
> **The finding is the asymmetry, not the single call.** The same collateral reduction reverts on the
> checked path (`withdraw` → `e/collateral-violation`) and succeeds on the unchecked one
> (`donateToReserves`). Without the control, the first test could have been asserting a property of the
> fork rather than the defect. This is the shape the daemon must detect: *a call that should have been
> gated by a post-operation check, and was not.*

> ### ⚠️ Euler V1 call routing — required ground truth for the daemon
>
> Three traps cost real time here; all three are now settled and must be encoded, not rediscovered.
>
> 1. **`moduleIdToImplementation` / `moduleIdToProxy` must be read AT THE PINNED BLOCK.** At `latest` the
>    protocol returns its **post-incident disabled set** — modules 2, 3, 6, 7 resolve to a `Reverter`
>    contract, so every call fails with an empty-data revert that looks exactly like a bad signature.
> 2. **Calls route by module, not to the main contract.** `0x2718…25d3` is a *dispatcher* only
>    (`dispatch`, `moduleIdToImplementation`, `moduleIdToProxy`, `name`). At block 16,700,000:
>    id1 `Installer`, **id2 `Markets` proxy `0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3`**,
>    id3 `Liquidation`, id4 `Governance`, id5 `Exec` proxy `0x59828FdF7ee634AaaD3f58B19fDBa3b03E2D9d80`,
>    id6 `Swap`, id7 `SwapHub`. **There is no Borrow module** — `borrow` lives on the dToken.
> 3. **`enterMarket` goes to the MARKETS PROXY and takes the UNDERLYING asset**, not the eToken:
>    `Markets.enterMarket` requires `underlyingLookup[newMarket].eTokenAddress != address(0)`, and
>    `underlyingLookup` is `mapping(address => AssetConfig)` **keyed by underlying**.
>
> Token proxies (`eUSDC`, `eWETH`, `dUSDC` — 519 bytes each) `CALL` the main contract and append their own
> address as a trailing param, which is why `deposit` works on an eToken while `enterMarket` does not.
> **Measured cost of each call** (for `ForkCache` sizing): `deposit` ~126k gas, `borrow`+`enterMarket`
> ~528k gas, `donateToReserves` ~447k gas.

### 0.3 — Pin the falsification fixture
The Aave-holds case (§2 beat 2). Same assertion, must **hold** at the same block.

**EXIT GATE:** the identical predicate returns `held == true` against Aave V2 at block 16,700,000.

> ### ✅ RESULT 2026-09-23 — PASSED against Aave **V3** (V2 not needed)
>
> `contracts/test/fixtures/AaveHolds.t.sol` — 2 passed, 0 failed. Pool `0x8787…A4E2` (V3), confirmed
> to exist at block 16,700,000 before use.
>
> | Test | Result |
> |---|---|
> | `test_predicate_held_withdrawBeyondHealthReverts` | withdrawing 100e18 aEthWETH against 50k USDC debt **reverted**; revert data decodes to `Error(string)` = `"35"` = Aave `HEALTH_FACTOR_LOWER_THAN_LIQUIDATION_THRESHOLD` ✔ |
> | `test_control_smallWithdrawSucceeds` | a safe 1 ETH withdrawal **succeeded** — so the revert is the health check firing, not a broken call path ✔ |
>
> **The predicate, stated once, across two protocols at the same block:**
>
> | Protocol | "unprivileged account can go unhealthy without a revert" | Verdict |
> |---|---|---|
> | Euler V1 | **TRUE** — `donateToReserves` does it | **REFUTED** |
> | Aave V3 | **FALSE** — reverts `35` | **HELD** |
>
> Same predicate, opposite verdicts, **each with its own negative control**. That is the property that
> makes the mechanism worth something: an assertion that always "finds a bug" is a rubber stamp, and an
> always-true predicate would have passed the Euler run too.
>
> *Note: the aEthWETH address `0x4d5F…14E8` was verified by calling `symbol()` on the fork before being
> used as a constant — not carried in from memory.*

> **Why this phase is mandatory:** §9 of the brief names the falsification fixture as "the one move that
> strengthens it most", and Phase 0.2 is the only assumption in the whole plan that could force a redesign.
> A single green Euler run proves nothing — an always-true assertion would also pass it.

### 0.4 — The prospective fixture (the one that makes this a product, not an archive)
**Added 2026-09-23 on review.** Euler is *retrospective*: the bug is already public, so refuting it is a
museum exhibit. A working product refutes code **whose bug nobody yet knows** — that is the difference
between an archive and a market. This is also the answer to *"isn't this just a replayable demo?"*

**Target:** an implementation **behind a timelock that has not yet executed** — pending code, live
timelock contract, no public exploitation. Candidates to pick from (in order):
1. A **TimelockController** (OpenZeppelin) with a queued `upgradeTo` / `setImplementation` whose delay has
   not elapsed — read `getMinDelay()`, the queued operation, and the pending implementation address.
2. Any proxy whose `UpgradeableProxy` admin has a scheduled-but-unexecuted implementation change.
3. Fallback: our own authored contract deployed on a testnet behind a 48h timelock, so the mechanism is
   demonstrable even if no suitable mainnet op is queued at build time.

```bash
# find a queued-but-unexecuted op: TimelockController exposes getMinDelay / isOperationPending
cast call <timelock> "getMinDelay()(uint256)" --rpc-url <rpc>
cast logs --from-block <recent> --address <timelock> \
  "CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)" --rpc-url <rpc>
```

**EXIT GATE:** one queued implementation whose bytecode we can read at the pending address, and a filed
assertion against it that returns a **verdict before the timelock executes**. Whether the verdict is
`REFUTED` or `HELD` is *not* the gate — **the gate is that a verdict exists on code that is not yet live.**

> ### ✅ RESULT 2026-09-23 — PASSED, using the AUTHORED fallback (option 3). Read the limitation below.
>
> `contracts/src/fixture/PendingProtocol.sol` + `contracts/test/fixtures/TimelockPending.t.sol`
> — 3 passed, 0 failed.
>
> The predicate, stated once, evaluated against **two implementations of the same proxy**:
>
> | Target | "an unprivileged address can move the entire balance to itself" | Verdict |
> |---|---|---|
> | **Live** impl (`VaultV1`) | **FALSE** — reverts `not-owner` | **HELD** |
> | **Pending** impl (`VaultV2`) | **TRUE** — attacker takes the full 5 ETH | **REFUTED** |
>
> The "not live" claim is **asserted, not narrated** (`test_preconditions_pendingButNotLive`):
> the pending implementation's bytecode is deployed and readable, `proxy.implementation()` is still `V1`,
> the proxy still behaves as `v1`, and `timelock.isReady(operationId) == false`. The refutation is then
> produced **while the code is still pending**, and the live control proves the predicate is falsifiable
> rather than always-true.
>
> **The narration this unlocks** — the sentence that makes remoc a product rather than an archive:
> *"Euler proves we can be right about a $197M bug that already happened. This one is code that isn't
> live yet — and we have a verdict on it now, before the timelock fires."*
>
> ---
>
> #### ⚠️ LIMITATION — stated plainly, do not let this be overstated
>
> **This fixture is a real mechanism demonstrated on authored code, NOT a bug found in a live protocol.**
> I attempted the preferred options 1 and 2 first and both were blocked:
>
> | Attempt | Outcome |
> |---|---|
> | Scan a real timelock (Uniswap `0x1a9C…35BC`) for queued ops via `eth_getLogs` | **Blocked:** free plan caps `eth_getLogs` at **10,000 blocks** (`"ranges over 10000 blocks are not supported on free plan"`, code 35) |
> | `getMinDelay()` on that address | **Failed** to decode — likely not the OZ `TimelockController` I assumed, and I did not verify its identity before use |
>
> So the honest claim is: **the mechanism is proven end-to-end; the mainnet target is not yet sourced.**
> For the submission this must be described as a demonstration against a pending-upgrade fixture, not as
> a disclosure against a named protocol. Sourcing a real queued operation remains an open item — a single
> correct address plus a paid or rate-unlimited RPC would close it, and until then the README must not
> imply a live target.
>
> *Two build facts worth keeping: OpenZeppelin 5.7 pins solc ≥0.8.20, incompatible with this project's
> 0.8.19 — hence the dependency-free timelock. And a proxy's implementation slot must be unstructured and
> far from slot 0, or the delegatecalled vault's own `owner` variable collides with it.*

> **Honest scoping note.** Beanstalk (0.2 fallback) and the timelock fixture are different things: the
> former is a second retrospective archive case; the latter is the only fixture that demonstrates the
> product thesis. If time forces a cut, **cut 0.3 (Aave), not 0.4** — but only after weighing that 0.3 is
> what proves the mechanism isn't a rubber stamp. Preferred outcome: ship both, in the PoC order below.
>
> **Demo narration this unlocks:** *"Euler proves we can be right about a $197M bug that already happened.
> This one is code that isn't live yet — and we have a verdict on it right now, before the timelock fires."*
> That sentence is the product.

---

## Phase 1 — Scaffold + contract skeletons

Foundation first (orchestrator-owned, then fanned out). Nothing here depends on Phase 2's daemon.

```
remoc/
  contracts/
    src/AssertionRegistry.sol      # assertion bytes on-chain, keyed by assertionHash
    src/ClaimManager.sol           # fileClaim / state machine
    src/BondEscrow.sol             # bond custody + payout / slash
    src/ForkVerifier.sol           # VerificationJob, staked verifier role, challenge window
    src/ProofRegistry.sol          # RefutationProof mint + proofsFor(codehash)
    src/Predicates.sol             # the 3 shipped predicates
    src/libraries/CodeHash.sol     # anchor check
  test/
    AssertionRegistry.t.sol
    ClaimManager.t.sol
    Predicates.t.sol
    fixtures/EulerInvariant.t.sol  # Phase 0.2 output, hardened
    fixtures/AaveHolds.t.sol       # Phase 0.3 output, makes falsification CI-enforced
  script/Deploy.s.sol
  daemon/
    src/index.mjs                  # job loop
    src/ProviderPool.mjs           # rotation across the 3 live RPCs + backoff on 429
    src/ForkCache.mjs              # cache by (chainId, block, codehash)
    src/replay.mjs                 # execute steps, evaluate predicate
    src/fulfill.mjs                # submit verdict
  web/                             # Phase 5
  README.md
```

**Key interface — fix this before fanning out:**
```solidity
struct VerificationJob {
    uint64  chainId;
    uint64  blockNumber;
    address target;
    bytes32 expectedCodehash;   // the ANCHOR
    bytes   steps;              // committed CALLDATA, not a reference
    bytes32 predicateHash;      // committed predicate bytes
}
function fulfillVerification(bytes32 requestId, bool assertionHeld, bytes32 traceHash) external;
```

**EXIT GATE:** `forge build` clean; `forge test` green on skeleton tests; repo pushed to a **public** remote
(verify with `git ls-remote`, not the push exit code); git identity set.

**Scope guard — do NOT build:** a token, a DAO, formal verification, full EVM bisection, an LLM verdict path.

---

## Phase 2 — Verifier daemon (the core mechanic)

The thing the entire product rests on. Build it before the frontend.

1. `ProviderPool.mjs` — rotate `drpc.org` / `blastapi.io` / `tenderly`, exponential backoff on 429,
   **fail loudly on all-providers-exhausted** (never silently return empty state).
2. Anchor check first, always: `keccak256(getCode(target, block)) == expectedCodehash` → else `ANCHOR_MISMATCH`.
3. `ForkCache.mjs` — key `(chainId, block, codehash)`; one fork per distinct key.
4. `replay.mjs` — spawn anvil at the pinned block, send the committed `steps`, evaluate the predicate.
5. `fulfill.mjs` — submit `assertionHeld` + `traceHash`, then **assert idempotence**: re-running the same
   job yields the identical verdict. This is the property the whole defense rests on.

**EXIT GATE:** the daemon processes a job end-to-end against a **local** anvil, twice, with byte-identical
verdicts and trace hashes. Then once against the real free tier.

**Plant a positive control:** feed the daemon one job whose `expectedCodehash` is deliberately wrong and
confirm it reports `ANCHOR_MISMATCH` rather than proceeding. **An empty scan and a broken scanner look
identical from inside** — a green path with no planted failure proves nothing.

---

## Phase 3 — Fixtures green, both directions

The demo, made CI-enforced.

- **3.1 Euler refutes** — claim filed → anchor verified → replay → `assertionHeld == false` → bond slashed → `RefutationProof` minted. Emit the real tx hash.
- **3.2 Aave holds** — same assertion bytes, `assertionHeld == true` → claimant loses the bond.
- **3.2b Timelock fixture (prospective)** — Phase 0.4 output. File a claim against a **not-yet-live**
  implementation behind a timelock and produce a verdict before it executes. This is the fixture that
  converts the demo from *archive* to *product*; see the narration in 0.4.
- **3.3 Encode fixture invariants as tests** (from the skill's own rule): each bond amount under any cap,
  the parts summing to the whole, the expected verdict asserted. A later re-scale must fail a test, not a
  recording.
- **3.4 Generate the one-command reproducer** — the artifact that makes the proof unfakeable:
  `forge test --match-path test/fixtures/EulerInvariant.t.sol --fork-block-number 16700000 -vvv`

**EXIT GATE:** `forge test` green for all three fixtures; `node daemon/src/index.mjs --fixture euler` prints
`REFUTED` and a tx hash; `--fixture aave` prints `HELD`; `--fixture timelock` prints a verdict **against
code that is not yet deployed**. Same assertion hash across the first two runs — printed, not implied.

---

## Phase 4 — Bonds, proofs, dispute path

Wires the economics and the anti-rubber-stamp mechanism.

- `BondEscrow` payout/slash on both verdicts.
- `ProofRegistry.mint` — `{codehash, chainId, blockNumber, jobHash, traceHash, verdict}`; `proofsFor(codehash)`.
- **Dispute path:** post a conflicting verdict → challenge window → escrow slashes the loser and pays the
  challenger. This is the answer to judge question 3.
- Verifier staking: unregistered/unstaked verifier cannot `fulfill`.

**EXIT GATE:** a `forge test` that drives `file → fulfill(true) → challenge → fulfill(false) → slash` and
asserts the final balances. The challenge must **actually** move money, not just emit an event.

---

## Phase 5 — Frontend (docket surface)

Design lane from the brief: **legal/ledger, not crypto-glass.** The subject is evidentiary, so the
vocabulary is a court docket — case numbers, exhibit tags, bond schedules, chain-of-custody, a replay
transcript. SIGNAL DECK tokens: deep blue-black, **ONE mint-teal accent (~hue 168)**, flat, CSS Modules,
Framer Motion. Mono for hashes, tabular numerals. **One boldness per screen** — the failing assertion line
as the redacted/underlined exhibit. No neon, no CRT, no glass, no violet.

Screens: docket list → claim detail with **replay diff** → proof page with the explorer link.

**EXIT GATE — drive a browser, never infer.** Launch Chrome headless over CDP
(`--headless=new --remote-debugging-port=9333 --user-data-dir=<tmp>`, zero deps on Node 24), click by text
via `Runtime.evaluate`, `Page.captureScreenshot`. **A screenshot beats a grep every time.** Confirm the
primary CTA is visible and clickable — not merely present in the DOM.

Two traps already paid for in this codebase's history, both apply here:
- **Measure contrast, don't eyeball it.** Write the WCAG ratio for every foreground/background pair; 1:1
  silently deletes a button.
- **Kill CSS transitions (`transition: none !important`) before reading `getComputedStyle`**, or the
  sampler photographs the previous frame.
- **WCAG ratio is the wrong instrument for "are these two colours different?"** Use CIE Lab ΔE. And for
  "which element is quietest?" use **chroma**, not luminance.

---

## Phase 6 — Hardening + submission artifacts

- **README as an AI-judge artifact**: problem → insight → architecture → safety rails → deployed Sepolia
  addresses → **real receipts** (tx hashes, block numbers, verdicts) → an explicit **"how this is scored"**
  section mapping Innovation / Technical Feasibility / Uniqueness / Design to shipped features. No claim
  the repo cannot back.
- **Honest limitations section** — predicate coverage, the liveness assumption, the unproven item still open.
  Say it before a judge does.
- **Demo video** — the three beats from §2, screen-recorded, deterministic. Pre-seed the replay so nothing
  depends on a live network call mid-take. Ship a `--dry-run` mode that exercises the **real** path while
  writing nothing, and **assert the dry run mutates nothing** (that is the bug that matters).
- **Pitch deck** — problem, solution, innovation, impact, future scope (the 5 items the rules require).

**EXIT GATE:** fresh clone → `README` instructions → fixtures green in one command; every deployed address
resolves on the Sepolia explorer; the video plays the three beats without a retry.

---

## Fan-out plan (parallel, not serial)

Orchestrator does the shared foundation **first**, then one agent per disjoint file set:
1. **Foundation (serial, orchestrator):** repo, git identity, `contracts/` layout, the `VerificationJob`
   interface, `CodeHash.sol`. Nothing else can start until the interface is frozen.
2. **Then, in parallel:** (a) `AssertionRegistry` + `ClaimManager` · (b) `BondEscrow` + `ProofRegistry` ·
   (c) `daemon/*` · (d) `Predicates.sol` + predicate tests · (e) frontend scaffold.
3. Orchestrator re-verifies every gate itself, then commits → merges → pushes. **Verify pushes with
   `git ls-remote`, never the push exit code.**

---

## Risk register

| # | Risk | Impact | Mitigation | Status |
|---|---|---|---|---|
| 1 | anvil cannot carry a full fork on free tiers | Demo needs a paid endpoint | — | ✅ **CLOSED** — 10/10 calls on free tier, no paid endpoint needed |
| 2 | Euler attack not fork-replicable | Centrepiece fixture dies | — | ✅ **CLOSED** — reproduces; fallbacks unused |
| 3 | Aave does not *hold* the same predicate | Falsification beat vanishes → looks like a rubber stamp | — | ✅ **CLOSED** — Aave V3 reverts `35`, predicate held |
| 11 | **Real mainnet timelock target unsourced** (0.4 authored fallback) | Cannot claim a live pending-upgrade finding | Source a verified OZ `TimelockController` + an RPC without the 10k-block `eth_getLogs` cap; until then describe 0.4 as a fixture demonstration | **OPEN — disclosure wording constrains it** |
| 4 | Free-tier 429 during the recording | Take dies on camera | Provider rotation + `--dry-run` + pre-seeded replay | Mitigated by design |
| 5 | Verifier seen as a trusted oracle | Judge lands the "trustless" knockout | Proven cross-provider determinism; staked + challengeable; assertion bytes on-chain | **Downgraded on evidence** |
| 6 | Scope creep (token, bisection, LLM verdict) | Nothing ships | Explicit scope guard in Phase 1 | Guarded |
| 7 | Predicate coverage attack | "You can't express every bug" | Say it first in the README; 3 solid predicates > 10 broken | Accepted |
| 8 | 4 days, one builder | Execution shortfall | Phase 0 kill-switch first; fan-out; fixtures are non-negotiable | Sequencing |
| 9 | **No claim-authoring path** — only hand-written predicates | The demo works; a real user cannot file anything | *Post-hackathon.* Never shipped in 4 days; the README states it as the known product gap | **Accepted (out of scope)** |
| 10 | **No paying actor** — bond punishes a wrong filer but never rewards a correct one | The market only adjudicates undisputed claims | *Post-hackathon.* Answer = prospective/timelock claims (Phase 0.4) have real value before execution | **Mitigated in-demo by 0.4** |

---

## Progress tracker

- [x] **Phase 0.1** anvil fork under rate limits — ✅ **PASSED 2026-09-23** (10/10 calls, free tier)
- [x] **Phase 0.2** Euler attack replicates on fork — ✅ **PASSED 2026-09-23** (no fixture swap needed)
- [x] **Phase 0.3** Aave holds the same predicate — ✅ **PASSED 2026-09-23** (Aave V3, reverts `35`)
- [x] **Phase 0.4** prospective fixture: verdict on not-yet-live timelocked code — ✅ **PASSED 2026-09-23** (authored fallback; mainnet target still unsourced — see limitation)
- [ ] **Phase 1** scaffold + interface frozen + public repo pushed (`git ls-remote` verified)
- [ ] **Phase 2** daemon end-to-end, idempotent, anchor-mismatch control fires
- [ ] **Phase 3** Euler refutes **and** Aave holds **and** timelock verdicts, all CI-enforced, reproducer generated
- [ ] **Phase 4** dispute path moves money
- [ ] **Phase 5** frontend driven in a real browser, contrast measured
- [ ] **Phase 6** README mapped to criteria, video, deck

## ✅ PHASE 0 COMPLETE — all four kill-switch gates green

Every assumption that could have forced a redesign is now settled by execution, not argument. No fixture
swap was needed, and the two pre-chosen fallbacks (Beanstalk, Curve/Vyper) were never required.

```
forge test --fork-url https://eth.drpc.org --fork-block-number 16700000
→ 3 suites, 7 tests passed, 0 failed, 0 skipped in 2.82s
```

| Fixture | Proves | Verdict shape |
|---|---|---|
| `EulerInvariant.t.sol` | a real $197M exploit reproduces on a fork | **REFUTED** + control |
| `AaveHolds.t.sol` | the same predicate is NOT universally true | **HELD** + control |
| `TimelockPending.t.sol` | a verdict exists on code that is **not live** | **REFUTED / HELD** + control |

**Two open items carried forward (neither blocks Phase 1):**
1. **Phase 0.4's mainnet target is unsourced** — the mechanism is proven on authored code. Do not describe
   it as a live-protocol finding anywhere in the submission.
2. **`ProviderPool` rotation is a hardening requirement, not a blocker** — real 429s were observed on
   blastapi under burst; drpc carried the full run cleanly.

*Phases 0→2 are strictly serial. 3→6 can overlap once the frozen interface is in place.*
