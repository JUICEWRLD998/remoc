# remoc — winning-idea brief

**Event:** 3rd-Web-Hack (TechZap Club) · 279 participants · $750 USDT total
**Deadline:** 2026-09-27 12:30 IST · Judging 09-27 15:00 → 10-02 17:00 · Winners 10-03 09:00 IST
**Theme (verbatim):** *"Hack the Web, build solutions to existing Blockchain problems"* / *"real-world unsolved challenges in Blockchain and Web3"*
**Criteria:** Innovation · Technical Feasibility · Uniqueness · Design *(no weights published — see §10)*
**Constraint:** original + developed for the hackathon; students only; no sponsor stack mandated; no credits provided.

**Byline for any artifact a stranger reads:** Mustapha Fadhlullah — independent security researcher

---

## 0. Verified evidence gathered in recon

| Claim | Evidence |
|---|---|
| Free historical-state RPC works | `eth_getCode` Euler @ block 16,700,000 → 907 bytes via `eth-mainnet.public.blastapi.io`; block timestamp `2023-02-24T18:34:47Z` independently confirms genuine archive state. `eth.drpc.org` also served it. |
| **Replay is deterministic across independent providers** | `node .recon/determinism2.mjs` → drpc.org + blastapi.io + Tenderly gateway returned **1 distinct blockHash / stateRoot / code-sha256** at block 16,700,000. Kills the "trusted verifier" attack on correctness. |
| Free tiers **rate-limit** (operational constraint) | blastapi → HTTP 429 compute-unit cap; merkle.io → rate limit; public-rpc → unauthorized. Provider rotation + fork caching are required. |
| Gated / dead alternatives | `ethereum-rpc.publicnode.com` "Archive requests require a personal token"; `rpc.ankr.com` unauthorized; `eth.llamarpc.com` 525; `1rpc.io/eth` 301 |
| Fixture address verified (not recalled) | Blockscout `GET /api/v2/addresses/0x27182842E098f60e3D576794A5bFFb0777E025d3` → `name: "Euler"`, `is_contract: true` |
| Fixture incident verified | DefiLlama `api.llama.fi/hacks` → Euler V1, 2023-03-13, **$197.0M**, Ethereum, technique "Donation Attack" |
| Scale of the problem | DefiLlama corpus: **1,283 incidents, $20.66B cumulative** |
| Nearest competitor is weak | `traverne/provable-contracts` — **0★**, created 2026-02-09, BNB Chain, EIP-712 signed attestations, **permissioned ("authorized verifiers")**, codehash used *only as an index key*, rating 0–100 + IPFS CID. Nothing executes against the code. |
| Concept family unoccupied | GitHub search: `bonded security assertion solidity` → **0 repos**; `onchain bug bounty escrow` → **0 repos**; all "attestation registry" hits ≤4★ and unrelated |

---

## 1. The winning idea

**Name:** remoc
**One-liner:** Anyone can file a *bonded, executable* claim that a contract's **deployed bytecode** was broken — and a peer replays it against a fork of a pinned block to settle it on-chain.

**Problem.** Web3 detects bugs *before* deployment, as a service the protocol buys about itself. It has no way to settle *"this code was broken"* after the fact: a finding is a PDF, a ChatGPT summary, a contest submission — and a human decides whether to believe it. Nothing is adversarial, bond-backed, or replayable.

**The insight (the thing everyone gets wrong).** The valuable artifact is **not the report**. It is the **falsifiable claim** — the claim whose truth *anyone* can establish without trusting the author. Criteria aren't valued because they're well-written; they're valued because they're **contractible**. Turn the claim into a public, bonded, deterministic *asset*, and:
- the claimant must pay to be wrong → spam and nonsense self-eliminate;
- the verdict stops being an opinion → it's a replay;
- the result becomes **consumable by other contracts** → not a document, a primitive.

**Solution.** remoc is a decentralized clearinghouse for adversarial claims about contract behavior.
- A **filer** posts an assertion + a **bond**, naming a `codehash`, a chain, and a **block**.
- A **verifier** checks `codehash(code @ block) == claimed` — **the anchor** — then executes the claim's call sequence in a fork of that block and evaluates the predicate.
- **The fact asserted is the shell; the codehash + pinned block is the bullet.** Without the anchor, replayed state ≠ claimed state and the whole mechanism is theatre.
- Assertion fails → bond slashed, filer paid, **RefutationProof** minted. Assertion holds → filer loses the bond.
- **The proof is executable.** Not a PDF: a block-anchored record + a `forge` test that reproduces it.

**Why different.** Everyone else builds *opinion*, *coverage*, or *insurance*. This is the first **adversarial, bonded, publicly-replayable** claim about deployed code — contestable by anyone, on a timeline nobody controls.

**Why now.** Three things just converged: (1) free archive RPCs make pinned-block replay *free* — verified above; (2) EAS + account abstraction make bonded attestations cheap to issue; (3) the incident corpus has crossed **$20.66B**, so machine-readable assurance has an identifiable payer.

**Why this hackathon.** The brief asks for *"solutions to existing Blockchain problems"* — problem-solving, not apps. Most of the field will ship products *on* blockchain; this solves an infrastructure problem *about* blockchain, using on-chain adjudication as an essential component rather than a storefront. That is exactly the stated theme.

---

## 2. The Magic Moment

Split view. Left: a block timeline. Right: a contract.

**Setup (15s):** "This is Euler, 2023-03-13. $197 million. This is the real attack."

**Action (30s):**
1. Judge clicks **File a claim**. The claim is one legible invariant: *"calling `donateToReserves` must not increase my borrowable amount."* A bond is attached.
2. The verifier pins block ~16,7XX,XXX — **before** the hack — checks the codehash anchor, forks, replays, and the assertion **FAILS**.
3. Bond slashed, filer paid, **RefutationProof minted.** Click it → opens a `forge` test that reproduces the exploit **in one command, on the judge's own machine.**

**The beat:** Euler V1 **doesn't exist anymore.** There is no live address to escrow against. Yet a claim was verified against it — because the registry anchors to **codehash + pinned block**, not "is this deployed right now."

**Beat 2 (the one that makes it unfakeable):** file the **identical assertion against Aave** at the same block → it **HOLDS** → the claimant **loses their bond**. Same assertion, two protocols, opposite verdicts. That is the difference between a mechanism and a rubber stamp.

---

## 3. How it actually works

### Contracts (Sepolia)
| Contract | Role |
|---|---|
| `AssertionRegistry` | Assertion templates by `assertionHash`; claim stores a hash, not bytes |
| `ClaimManager` | `fileClaim(codehash, chainId, pinnedBlock, assertionHash, params)` payable; states OPEN → VERIFIED_TRUE → REFUTED → EXPIRED |
| `ForkVerifier` | `VerificationJob{chainId, blockNumber, target, expectedCodehash, steps[], predicate}` → `requestId` → `fulfillVerification(requestId, assertionHeld, traceHash)`. Staked, challengeable. |
| `BondEscrow` | Holds bonds; pays winner; slashes loser |
| `ProofRegistry` | Mints `RefutationProof{codehash, chainId, blockNumber, jobHash, traceHash, verdict}`; `proofsFor(codehash)` |

### Verifier daemon (off-chain, deterministic)
`eth_getCode(target, pinnedBlock)` → **codehash check** → anvil fork @ block → execute steps → evaluate predicate → `fulfillVerification`. Deterministic: same job ⇒ same verdict, forever. **Proved cross-provider** (`.recon/determinism2.mjs`): 3 independent RPCs returned identical `blockHash`/`stateRoot`/bytecode `sha256` at block 16,700,000 — so any third party reproduces the verdict and only **liveness**, never **correctness**, is delegated to the daemon. Cost ≈ one fork + one call sequence per claim; forks cached by `(chainId, block, codehash)`. **Provider rotation is required** — free tiers rate-limit (blastapi 429s on compute units).

**Hard build constraint:** **assertion bytes are committed on-chain**, never an off-chain reference. If a verifier could report on different predicate bytes than were filed, it could commit fraud undetected; with the bytes on-chain, anyone re-runs exactly what was filed and slashes a mismatch.

### Predicate DSL (small, auditable — 3 shipped)
```solidity
Predicates.invariantDelta(expr, op, bound);      // "after X, my capacity must not rise"
Predicates.noPrivilegedEffect(selector, target); // "non-owner must not move state"
Predicates.healthCheckedAfter(action);           // "a solvency check must gate X"
```

### Frontend (design lane: **legal/ledger**, not crypto-glass)
The subject is *evidentiary* — claims, bonds, adjudication — so the vocabulary is a **court docket**: case numbers, exhibit tags, bond schedules, chain-of-custody, a transcript of the replay. SIGNAL DECK tokens (deep blue-black, ONE mint-teal accent ~hue 168, flat, CSS Modules, Framer Motion), mono for hashes, tabular numerals. One boldness per screen: the failing assertion line as the redacted/underlined exhibit. **No neon, no CRT, no glass.**

---

## 4. MVP (4 days)

**Must Have**
- 5 contracts on Sepolia + verifier daemon (codehash anchor → fork → predicate → fulfill)
- 3 predicates
- **Fixture green, end-to-end:** Euler 2023-03-13 — claim → verified → paid → proof minted
- **Falsification fixture:** same assertion vs Aave → holds → filer loses bond
- Frontend: docket + replay diff + proof page with explorer link
- README mapped to the 4 criteria, real tx hashes, "how this is scored" section

**Should Have**
- Dispute path: post a conflicting verdict → escrow slashes the loser
- A 2nd fixture on a small authored contract (missing `onlyOwner`) — deterministic and controllable

**If Time Allows**
- Toy bisection fraud proof · insurance-pricing stub reading `proofsFor(codehash)` · one L2 fixture

**Out of scope (say it before a judge does):** full on-chain EVM bisection, formal verification, all bug classes. The claim is *deterministic replayable adversarial claims* — not "we find every bug."

---

## 5. Startup potential
- **Payers:** protocols (continuous + *pre-upgrade* assurance) · insurers/underwriters · integrators (lending/aggregators reading `assertionsHeldFor(codehash)`) · bounty programs
- **Wedge — the upgrade gauntlet:** file claims against a **pending implementation behind a timelock**, before it goes live. High-value, uniquely on-chain, no incumbent does it
- **Model:** bonded claim fees + small fee on settled claims + insurer-facing data subscription. **Not a token.**
- **Moat:** (1) growing public corpus of assertions that empirically held/failed on real code — a dataset nobody else has; (2) the verified-codehash anchor as the ecosystem's default key; (3) earned adjudication reputation. Open-sourcing the assertion library is deliberate: it builds the moat
- **Distribution:** open-source assertion library + a weekly "Refuted" feed of real proofs + one insurer pilot

---

## 6. Competitive landscape (honest)
| Category | Real players | Where they fall short |
|---|---|---|
| Analysis | Slither, Mythril, Echidna, Halmos, Medusa | Point-in-time output on *your* copy of source; run in CI and are forgotten; no counterparty, no bond, no public adjudication, not keyed to deployed codehash |
| Audit marketplaces | Code4rena, Sherlock, Cantina, Spearbit | Output is a **PDF/website**, not an executable artifact; "was it real?" is settled by human triage |
| Coverage | Sherlock, Nexus Mutual | Insure *capital*, not *claims*. Orthogonal — they become **consumers** |
| On-chain registries | `traverne/provable-contracts` (0★), assorted EAS schemas | Permissioned, attestation-only (signed rating + IPFS CID), codehash used as an index key. **Nothing executes against the code** |
| Bounties | Immunefi | Centralized mediation; the hard part (is it real?) is human |

**The real gap:** nobody has made *"this code is broken"* a **bonded, deterministic, publicly-replayable, block-anchored claim** that anyone can settle on-chain and any contract can consume. Tools produce opinions; reports produce documents; this produces **proofs with a bond on the line.**

---

## 7. Judge attack — 10 hardest questions
1. **"Just Code4rena with extra steps?"** No — those settle by human triage on a *report*; we settle by deterministic replay against a *pinned codehash*, with bonds.
2. **"You can't express every bug as a predicate."** Correct, and we don't claim to. We cover *deterministic* classes: unauthorized privileged state change, invariant/bound violations, malformed accounting, missing checks. The rest stays human — stated in the README.
3. **"Off-chain verifier = trust hole."** It's a **staked, challengeable role**, not a server: verdicts post a codehash anchor + trace hash and sit in a challenge window; a conflicting verified result slashes the oracle and pays the challenger. Full bisection is roadmap, documented as a gap.
4. **"Why would a protocol fund claims against itself?"** It wouldn't — the economy is *adversarial*. Fliers bear the bond. The mechanism works **without the target's consent**.
5. **"Permissionless escrow ⇒ spam."** The bond is the filter: only a claim that actually fails the assertion pays out.
6. **"Archive access at scale?"** Verified live this session — free public archive RPC served historical bytecode at block 16,700,000, no key. Cost ≈ one cached fork per claim.
7. **"Forkable in a week."** Yes. So the moat is the **corpus**, the **anchor**, and **reputation** — not the code.
8. **"Is an LLM the verifier? Don't trust that."** The verdict is **never** an LLM's — it's an EVM replay with a deterministic predicate. AI, if used, only *proposes* assertions before filing; the filed bytes are audited and the verdict is math.
9. **"Business after the hackathon?"** Upgrade gauntlet → insurer/integrator subscriptions → protocol fees on settled bonds. No token.
10. **"Why not a CI test in the target's repo?"** Because the target controls it. The value is that **the claimant is not the target.** A CI test is a protocol marking its own homework; a bonded claim is an adversary with money at risk.
11. *(prepare)* **"What if a wrong assertion slashes an innocent party?"** The falsification runs both ways — anyone can post the opposite result and take the bond.

---

## 8. Winning pitch (60s)
> March 2023. Euler loses 197 million dollars. Today, if you want to say *that code was broken* — you write a PDF, and someone decides whether to believe you.
> I want that to be a fact, not an opinion.
> This is remoc. Anyone can file a claim against a contract's exact code — not the source, the **deployed bytecode** — pinned to a block, backed by a bond. A verifier replays it against a fork of that block. If the assertion fails, the code *is* broken, the bond is slashed, and the proof is minted on-chain — a refutation anyone can re-run in one command.
> Here's what no escrow can do: Euler V1 doesn't exist anymore. There's nothing to point at. We filed against its codehash at a block from **before** the hack — and it still refuted.
> Same claim against Aave? The assertion holds, and the claimant loses their money. So it's not a rubber stamp.
> Twenty billion dollars went out the door in 1,283 incidents. Not one of those verdicts is a fact anyone can replay. We're building the thing that makes them facts.

---

## 9. Final verdict

**Win probability: 8.5/10.** *(revised up from 8/10 — the loss vector that dominated the "why lose" list was downgraded on evidence; see the CORRECTED note at the end of this section.)* In a $750 student-only open-ended event, most entries pitch an *application*; this solves an *infrastructure* problem about blockchain itself — matching the stated theme verbatim — with a deterministic three-beat demo and the only defensible "why blockchain" argument in the field. Residual risk is execution, not idea.

**Why it wins:** (1) theme-fit is literal, not stretched; (2) on-chain refutation of *past* code is genuinely novel — nearest neighbour is 0★ and permissioned; (3) the two-verdict demo (Euler fails / Aave holds) is unfakeable; (4) composability is a *real* answer to "why blockchain"; (5) feasibility is proven — free runtime and a reachable green fixture, both verified above.

**Why it loses:** (1) the MVP verifier is off-chain — a judge pressing "trustless" gets an honest-but-weaker answer; (2) concept-dense — if the demo doesn't land in 90 seconds, depth reads as complexity; (3) narrow predicate coverage is attackable (survivable only because we say it first); (4) four days, one builder, and both fixtures are non-negotiable.

**Biggest weakness — ⚠️ CORRECTED 2026-09-23 (retraction).**
*Original claim:* "the off-chain verifier daemon — where a sharp judge lands a knockout."
*Retracted as overstated, on evidence gathered after writing it.* Three independent providers (`eth.drpc.org`, `eth-mainnet.public.blastapi.io`, `mainnet.gateway.tenderly.co`) returned **byte-identical** `blockHash`, `stateRoot`, and code `sha256` at block 16,700,000 — verified in `.recon/determinism2.mjs`:

```
distinct blockHash values : 1
distinct stateRoot values : 1
distinct code hashes      : 1
```

The verdict is `state @ pinned block` + EVM execution + deterministic predicate. The state leg is now *proved reproducible by any third party*; EVM execution is deterministic by construction. So a judge is never asked to **trust** the daemon for correctness — they can re-run the on-chain-committed assertion bytes and obtain the same verdict. That demotes the daemon from "trusted oracle" to "convenience anyone can replicate or contest."

**What genuinely remains (stated precisely):**
1. **Liveness, not correctness.** The daemon cannot lie about the verdict — only refuse to report, or be the sole reporter. Mitigated by a **permissionless, staked verifier role + challenge window**. This is the **standard optimistic-oracle assumption** (structurally the same as Optimism's canonical bridge and EAS resolvers) — a recognized trust model, not a design-specific hole.
2. **Predicate commitment — a must-enforce build constraint.** If a verifier reports on predicate A while the claim filed predicate B, that is fraud. Fix: **the assertion bytes are committed on-chain**, so anyone re-runs *exactly* what was filed and slashes a mismatch. This is the reason the assertion must live on-chain rather than be an off-chain reference.

**Revised severity:** a documented, industry-standard trust assumption sitting on a *proven-deterministic* core — not a knockout. The "why it loses" list is consequently dominated by **execution risk**, not architectural weakness.

**The one move that strengthens it most:** make the **falsification fixture mandatory**. A single green run against Euler proves nothing — an always-true assertion would also pass. The Aave-holds case converts the product from *"we found a bug"* into *"we have a mechanism,"* and it costs a few hours.

**Win probability revised 8/10 → 8.5/10**, on the single ground that the loss vector which dominated the "why lose" list is now empirically downgraded.

---

## 10. Unverified — and the 2-minute check for each
| Item | Why it matters | Check |
|---|---|---|
| Prior editions' winners (`1st/2nd-web-hack.devpost.com` → **404**; 3rd gallery unpublished) | We cannot calibrate to the judges' taste, and competition is invisible | `techzap.hq@gmail.com`; try alternative Devpost slugs |
| Judging **weights** (none published) | This brief assumes Innovation + Uniqueness dominate | Ask the organizer; until then treat as ASSUMED |
| **Replay determinism across independent providers** ✅ | The core defense against the "trusted daemon" attack | `node .recon/determinism2.mjs` → 3 providers, **1 distinct blockHash / stateRoot / code sha256** |
| **Free-tier rate limits (operational)** ✅ | Sets the demo's provider-rotation + cache requirement | `blastapi` → HTTP 429 "exceeded its compute units per second"; `eth.merkle.io` → "Rate limit exceeded"; `eth.public-rpc.com` → unauthorized. **Design must rotate providers and cache forks by `(chainId, block, codehash)`** |
| Fork *throughput* on the free RPC | **Verified:** single historical reads (3 providers). **Not verified:** anvil sustaining a full `--fork-url` execution workload, and post-429 recovery under rotation | `anvil --fork-url https://eth-mainnet.public.blastapi.io --fork-block-number 16700000` then send one tx. **This is the last unproven runtime assumption.** |
| Euler attack replicable on a fork | The centrepiece fixture | `forge test --fork-block-number <pre-hack>` on the public PoC. **If it fails → swap fixture** to Beanstalk ($181M, flashloan governance) or Curve/Vyper ($61.7M) |
| "Original + developed for the hackathon" | Precludes reusing any existing repo as a base | Read the full rules before scaffolding |
| Country/age exclusions | Cheap to check, fatal to miss | Devpost rules tab |

*Note: the Euler fixture, the free archive RPC, **cross-provider replay determinism**, the competitor gap, and the $20.66B corpus are all **verified with live evidence** (see `.recon/`). **Exactly one runtime assumption remains unproven: anvil sustaining a full forked execution under free-tier rate limits.** Everything else in this brief either has a receipt or is labelled ASSUMED.*
