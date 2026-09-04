# ObscuraLoan — Audit & Rebuild Report

**Date:** 2026-09-04 (rev. 3 — production build verified, QR deploy path)
**Scope:** `src/ObscuraLoan.sol`, `src/ObscuraPQC.sol`, `src/ObscuraLoanGovernor.sol`, `src/OBSGov.sol`
**Target chain:** Arbitrum One
**Toolchain:** Foundry (forge 1.8.1), solc 0.8.36, optimizer on (200 runs)

> The previous version of this file described the pre-rebuild contract and its
> "PASS 6" design. That contract has been replaced. Every claim below was
> produced by executing the test suite in this repository, not by inspection.

---

## 1. Verdict

**The previous contract was NOT production ready.** It shipped with 80 passing
tests and seven independently exploitable defects, including one that made the
headline 150% LTV feature completely non-functional. The passing suite gave
false assurance: it never tested the paths that were broken.

The contract has been rebuilt. Current state:

| | Before | After |
|---|---|---|
| Tests | 80 (7 proven-exploitable bugs uncovered) | 76, green under **both** optimizer profiles |
| Invariant fuzzing | none | 6 invariants × 128,000 calls |
| Native on-chain PQC | none (explicitly removed) | WOTS+ verifier, hybrid-gated |
| 150% LTV | liquidatable in its origination block | functional and capacity-gated |
| Runtime size | 27,192 B (over the 24,576 B EIP-170 limit) | 18,093 B |
| Verified against live OBS | never | 6 fork tests on Arbitrum One |

**Remaining blocker before mainnet: an independent third-party audit.** Nothing
in this report substitutes for one. See §8.

---

## 2. The seven defects, each proven by exploit

Each was demonstrated with a failing proof-of-concept against the old contract
before any fix was written.

### 2.1 Partial repayment destroyed borrower collateral — CRITICAL

```solidity
uint256 collateralBack = (loan.collateral * principalRepayment)
                       / (loan.principal + principalRepayment);
```

`loan.principal` was still the *full* outstanding balance, so the denominator
was inflated. Worse, in the partial-repayment branch `collateralBack` was
subtracted from `loan.collateral` and `loan.collateralUsed` but **never
transferred to anyone** — it was silently orphaned in the contract.

*Measured:* borrower posts 200 OBS, borrows 100, repays in two 50 OBS
instalments → receives **66.67 OBS back instead of 200. Net loss: 133.33 OBS.**

The full-repayment path masked this: `collateral * P / 2P = collateral/2` was
returned twice, coincidentally netting to the right number. That is why the
80-test suite never caught it.

### 2.2 Every 150% LTV loan was liquidatable in its own block — CRITICAL

`LIQUIDATION_THRESHOLD_BPS = 8500` was a single global 85% ceiling, but the
100%, 125% and 150% tiers all originate *above* it.

*Measured:* a fresh top-tier loan returned `isLiquidatable == true`,
`"undercollateralized"`, in the origination block. Anyone could seize the
collateral instantly for a 5% bounty. **The entire high-LTV product was
inoperable.**

Root cause: collateral and debt are the *same token*, so LTV cannot move on
price — only on accrued interest. A global price-style threshold is
categorically the wrong instrument. See §4.

### 2.3 `totalOwedInterest` never decremented on repayment — CRITICAL

`_accrueInterest` added to `totalOwedInterest`; `repayLoan` never subtracted.
The figure grew monotonically and was simultaneously used as the cash ceiling
for staker reward payouts.

*Measured:* borrow 1,000 / 1 year / full repayment → `totalOwedInterest` stayed
at 500e18 after the debt was fully settled. Stakers could claim against
permanently phantom income, draining tokens backing principal and collateral.

### 2.4 Liquidation read a stale struct copy — HIGH

`_executeLiquidation` took `Loan memory loan`, then called `_accrueInterest`
(which writes to *storage*), then read `loan.interestOwed` from the **stale
memory copy**.

*Measured:* `stakerRewardPerToken` delta was exactly `0` after liquidating a
loan carrying 38 days of accrued interest. All interest at liquidation was lost
to stakers, and `totalOwedInterest` was decremented by a stale value.

### 2.5 Borrower collateral counted as lendable liquidity — HIGH

`availableLiquidity()` = `balanceOf(this) - totalBorrowed - ...`, with no term
for collateral held.

*Measured:* borrowing 100 against 4,000 collateral **increased** reported
available liquidity from 5,000,000 to 5,003,800. Collateral could be lent out
to other borrowers, so it might not exist when its owner repaid.

### 2.6 Top-tier exposure cap trivially bypassed — HIGH

The cap keyed off `requestedBps == TOP_TIER_LTV_BPS` — exact equality.

*Measured:* borrowing at 14,999 bps (149.99% LTV) set `isTopTier = false` and
`topTierExposureOutstanding = 0`. The 20% concentration cap was bypassed
entirely by rounding down one basis point.

### 2.7 Liquidation confiscated all surplus collateral — HIGH

*Measured:* a borrower with 1,000 collateral against a 100 debt, liquidated one
day past grace, received **0 OBS back**. A 10% LTV loan was penalised at 1000%
of the debt.

---

## 3. Post-quantum cryptography

### 3.1 Did the contract have native hybrid PQC on-chain? No.

The old contract stated this honestly in its own header, and the test suite
contained `test_NoNativePqcVerification` and `test_NoPqcFunctionOrStorage`
asserting the *absence*. Git history shows a `PQC_VERIFIER_ROLE` and
`setPqcMerkleRootFor` existed in earlier passes and were deleted in "Pass 6". A
Merkle root of off-chain material is not verification in any case.

### 3.2 What exists now

`src/ObscuraPQC.sol` is a **real WOTS+ verifier executing in EVM bytecode** —
not a stub, not a commitment, not an attestation.

WOTS+ is the one-time signature underlying **SLH-DSA (SPHINCS+), NIST FIPS 205**.
Its security rests only on hash preimage resistance, so Shor's algorithm does
not apply; Grover's gives only a quadratic speed-up, leaving ~128-bit security
against a quantum adversary from keccak256.

Parameters: `w = 16`, `n = 32`, `len1 = 64`, `len2 = 3`, **`len = 67` chains**.

**Why "hybrid":** a PQ signature never *replaces* `msg.sender`. It is required
**in addition** to ordinary ECDSA transaction authorisation. An attacker must
break secp256k1 **and** keccak256 preimage resistance — security is the *max*
of the two primitives, not the min.

**Key evolution:** WOTS+ keys are strictly one-time (signing twice leaks the
secret key). Every signed message commits to the hash of the *next* public key,
and the contract rotates to it in the same transaction. A consumed key is never
accepted again.

**Measured verification cost: 654,660 gas.** Negligible on Arbitrum; would be
material on L1. This is the reason the gate is opt-in per account rather than
mandatory for everyone.

**Verified by:** 9 tests including round-trip, wrong-message, wrong-seed,
wrong-key, tampered-word, and a checksum-forgery test that confirms the
chain-advance attack is blocked — plus 256-run fuzzing of both round-trip and
forgery rejection.

**Cross-language agreement:** `tools/wots.js` is a reference signer whose output
matches the on-chain verifier **byte for byte**, locked by a frozen test vector
in `test/Vector.t.sol` and `tools/wots-check.js`. This matters more than it
looks: a signer that disagreed with the verifier would permanently lock every
enrolled account out of its own funds.

### 3.3 Honest limits

- Enrolment is **opt-in and irreversible**. Accounts that never enrol have
  exactly the quantum exposure of any standard Arbitrum contract.
- Key management is the user's burden. **Losing the key chain means losing
  access to the account's funds.** There is no recovery path.
- This protects *this contract's* entry points. It cannot protect the OBS token
  itself, the sequencer, or the bridge.

---

## 4. Liquidation, rebuilt for a same-asset loan

Because collateral and debt are both OBS, LTV never moves on price. It moves
only as interest accrues. Each loan therefore carries **its own** threshold,
fixed at origination:

```
liquidationLtvBps = originationLtvBps × (1 + LIQUIDATION_HEADROOM_BPS)
                  = originationLtvBps × 1.25
```

A loan is liquidatable when **either**:
1. `debt / collateral > liquidationLtvBps` — interest ate the buffer; or
2. `now > maturity + 7 days` grace.

This algebraically reduces to a single clean servicing rule, uniform across
every tier:

> **A loan becomes liquidatable once accrued interest reaches 25% of principal.**

At 50% APR that is ~6 months; at 2% APR, ~12.5 years. `payInterest()` exists to
cure it, which is what makes the 10-year product coherent — long loans must be
serviced, exactly like a real amortising loan.

**Waterfall:** bounty (5%) → principal → interest → **surplus returned to the
borrower**. Principal shortfall draws the insurance reserve first; only the
residual is socialised across stakers.

---

## 5. How 150% LTV unlocks — mathematically

The only value stakers can lose is the **unsecured slice**,
`unsecured = principal − collateral`. That is what the protocol caps, so gates
are keyed to it rather than to gross principal.

A top-tier loan is admitted only when **all** hold:

| Gate | Requirement | Why |
|---|---|---|
| `onchain-score` | earned score ≥ 800 | **an AI attestation alone can never unlock 150%** |
| `credit-score` | effective score == 850 | AI may bridge only the final 50 points |
| `pqc-key` | PQ key registered | hybrid PQC mandatory on the riskiest product |
| `unsecured-cap` | aggregate unsecured ≤ 10% of pool | bounds total staker downside |
| `toptier-cap` | aggregate top-tier principal ≤ 20% of pool | bounds concentration |
| `reserve-coverage` | reserve ≥ 25% of aggregate unsecured | **the "enough staking funds" gate** |
| utilisation | post-loan utilisation ≤ 90% | stakers retain an exit |

`reserve-coverage` is the gate the pool *grows into*: the reserve is funded by
5% of all interest, so undercollateralised lending switches itself on only once
the pool has earned a real buffer. No admin action unlocks it.

> **Gap found and closed during the rebuild.** These capacity gates initially
> ran only above 125% LTV. But the **125% tier also creates unsecured exposure**
> (20% of principal) and has no principal cap of its own — so a score-800
> borrower could create uncapped unsecured exposure. `_requireUnsecuredCapacity`
> now applies to *every* loan above 100% LTV. Regression tests:
> `test_Tier3IsAlsoSubjectToUnsecuredCap`,
> `test_Tier3IsAlsoSubjectToReserveCoverage`.

At 150% LTV the 20% top-tier cap binds before the 10% unsecured cap can
(unsecured is only a third of principal there); the unsecured cap is the
binding constraint on the 125% tier. Both are tested at the tier where they
actually bite.

---

## 6. Staker economics

Stakers hold **shares** (ERC-4626 style), not a balance plus a reward debt.
Pool value rises with accrued interest and falls when a default is written off,
so yield and loss distribute pro-rata automatically. This structurally
eliminates the reward-debt desynchronisation class of bug that produced §2.3.

- **Fee split:** 95% of interest to stakers, 5% to the insurance reserve.
- **APR visibility:** `stakerAprBps()` returns gross and net APR, diluted by
  idle liquidity — what a staker actually experiences, not a headline number.
- **Loss order:** insurance reserve absorbs a default before stakers do.
- **Share-price manipulation:** `totalPoolAssets` is an internal accumulator,
  never `balanceOf(this)`, so raw donations cannot move share price
  (`test_DonationCannotMoveSharePrice`). A virtual-offset defeats the classic
  first-depositor inflation attack
  (`test_FirstDepositorInflationAttackNotProfitable`).

*Measured:* 10M staked, 1M borrowed for 1 year at the 50% APR ceiling →
**+475,000 OBS to stakers** (95% of 500,000 interest), distributed pro-rata.

---

## 7. Credit scoring, 500–850 — every repayment raises LTV

**On-chain base (trustless).** Genesis 500.

**Every full repayment increases the score**, by an amount proportional to how
much of the term the borrower actually carried:

```
credit = fullTermCredit(term) × min(held, term) / term
```

| Term | Full-term credit | Rate |
|---|---|---|
| 30 days | +12 | 0.400 pts/day |
| 90 days | +40 | 0.444 pts/day |
| 1 year | +175 | 0.479 pts/day |
| 10 years | +2000 | 0.548 pts/day |

As the score crosses 600 / 700 / 800 / 850 the LTV ceiling steps up
50% → 75% → 100% → 125% → **150%**. `test_EveryRepaymentRaisesScoreAndLtv`
walks a borrower through all five tiers and asserts the ceiling never stalls or
regresses. `previewRepayCredit()` lets a UI show credit accruing live.

> **Changed in rev. 2.** Rev. 1 used a pass/fail cliff: carry ≥50% of the term
> or earn nothing. That was both unfair (49% earned zero) and contrary to the
> requirement that repayment always builds credit. Proportional accrual is
> strictly better and *keeps the anti-farming property* — see below.

**Why this cannot be farmed.** Credit accrues per unit of time under loan, so N
short loans spanning T seconds earn the same as one loan of length T. Splitting
a position gains nothing, and a loan opened and closed in the same block spans
zero time and earns zero. Rates are near-equal per day across terms, so no term
is a shortcut either. Proven by `test_SplittingLoansGainsNoAdvantage`
(three 30-day loans → 536; one 90-day loan over the same 90 days → 540) and
`test_InstantRepayEarnsNothing`.

This matters: without it, the score-farming path used by the §2.2
proof-of-concept — open and close repeatedly to reach 850 and take 150%
unsecured credit for the price of gas — would be live. A full 500 → 850 climb
now takes roughly **two years** of continuous, well-behaved borrowing. That is
deliberate; 150% unsecured credit should be expensive to earn. The increments
in `_repayIncrement` are the knob if you want it faster.

**AI layer (bounded).** An optional oracle signs an EIP-712 attestation applying
a **±50 point** adjustment, with expiry and a per-user nonce. Constraints:

- It can never unlock the 150% tier alone (`onchain-score` gate requires 800
  *earned*).
- Attestations expire (≤ 7 days) and are non-replayable.
- A default zeroes any live uplift.
- **A fully compromised oracle cannot pause, drain, or re-parameterise the pool.**
- Pass `address(0)` at deployment to disable AI scoring entirely, leaving **no
  privileged key of any kind**.

---

## 7a. Verified against the live OBS token

`test/ForkArbitrum.t.sol` runs against a fork of **Arbitrum One** using the real
token at `0xa473…D7B0`. Confirmed on-chain:

| Check | Result |
|---|---|
| Chain | 42161, Arbitrum One |
| Token | **Obscura (OBS)**, 18 decimals, 100,000,000,000 supply |
| Fee-on-transfer? | **No** — a 1,000 OBS transfer arrives as exactly 1,000 |
| `address(0)` constructor | resolves to the live OBS address |
| Full lifecycle | stake → borrow 1M → accrue 1y → repay: staker **+474,999.99 OBS**, borrower 500 → 675, ceiling 50% → 75% |
| Liquidation | real OBS moved: **50,000 bounty** to liquidator, **844,794 surplus** returned to borrower |
| Hybrid PQC | enrolment enforced; unsigned action rejected on a real fork |

The fee-on-transfer result is the important one: it is the property that would
have silently corrupted pool accounting, and it is now measured rather than
assumed. The suite skips itself cleanly when no RPC is available.

---

## 8. Production-readiness: what is and is not done

**Done and verified**
- 76 tests passing under the DEFAULT **and** the PRODUCTION (via_ir) profile;
  6 stateful invariants over **128,000 randomised calls** under both
- Invariant runs proven **non-vacuous** via an `afterInvariant` coverage
  assertion (a run reached 20 loans, 16 repayments, 14 liquidations, 51
  withdrawals). This matters — every handler action is wrapped in `try/catch`,
  so silently-reverting actions would have made all six invariants pass while
  proving nothing.
- Solvency invariant: cash always covers collateral + reserve
- Aggregate bookkeeping reconciles against per-loan records every call
- `SafeERC20` throughout; fee-on-transfer and rebasing tokens rejected via
  measured balance deltas
- 18,093 B runtime — 6,483 B under the EIP-170 limit
- End-to-end verified against the **live OBS token** on an Arbitrum One fork (§7a)
- Deployment tooling exercised end-to-end: preflight against live Arbitrum One,
  and a full broadcast + post-deploy verification run on a local chain (§12)
- Reproducible deploy script; constructor refuses an undeployed OBS address

**Not done — required before mainnet**
1. **Independent third-party audit.** Non-negotiable. This rebuild was written
   and reviewed in one session by one author.
2. **Economic review of the parameters.** The gate *structure* is tested; the
   *values* (25% headroom, 10%/20% caps, 25% coverage, the score curve) are
   reasoned defaults, not the output of risk modelling against OBS liquidity.
3. **Testnet soak** on Arbitrum Sepolia across a full 30-day term.
4. **Liquidation keeper.** Liquidation is permissionless with a 5% bounty, but
   protection is only as good as the bots watching. Run one; do not assume the
   market will.
5. **Arbiscan source verification** immediately after deploy — the command is
   printed by both deploy paths. Unverified lending contracts should not
   attract deposits.

**Accepted, documented risks**
- **No pause. No upgrade. No admin.** A bug found post-deployment cannot be
  contained by anyone. This is the unhedged cost of immutability.
- **150% LTV is unsecured lending.** A borrower who takes 150% and walks away
  costs stakers up to a third of that principal, capped in aggregate at 10% of
  the pool. Reputation is the only recourse; there is no off-chain collections
  process.
- **Same-asset collateral.** Posting OBS to borrow OBS provides no
  diversification. A collapse in OBS price does not change LTV but does destroy
  the real value of both sides at once.
- **PQ key loss is unrecoverable.**

---

## 9. OBS token placeholder

```solidity
address public constant OBS_ARBITRUM_ONE =
    0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0;
```

Passing `address(0)` to the constructor selects this address. The constructor
probes `code.length` and `totalSupply()` and reverts with `TokenNotDeployed`
otherwise, so a pool can never be pointed at an empty address.

**Status: OBS is already deployed and live at this address on Arbitrum One** —
"Obscura" (OBS), 18 decimals, 1e29 base-unit supply, no `owner()` and no
`paused()` surface. It is not fee-on-transfer (§7a). No placeholder swap is
needed; the constant is correct as compiled.

OBS must be a **plain, non-rebasing, non-fee-on-transfer ERC-20**. Fee-on-transfer
is rejected at runtime (`test_FeeOnTransferTokenRejectedAtBorrow`), but a
*rebasing* token would silently corrupt accounting and is not detectable at
deployment. Do not point this pool at one.

---

## 10. Governance contracts — status

`ObscuraLoanGovernor` and `OBSGov` compile but **govern nothing**. ObscuraLoan
is fully immutable: there is no admin role, no pause, no parameter setter, so no
proposal has anything to call.

The governor's documentation previously claimed control over
`addCommitteeMember`, `setScoreThreshold`, `setTopTierExposureCap`,
`setPqcMerkleRootFor` and `DEFAULT_ADMIN_ROLE` on ObscuraLoan — **none of those
functions exist**. It also described a "72-hour guardian pause" that was never
implemented. Those claims have been removed rather than left to mislead a
deployer or token holder.

**Decide before launch:** wire the governor to a future periphery contract, or
delete both files. Shipping a governance token whose only real function is to
imply control it does not have is a disclosure problem, not just dead code.

---

## 11. Reproducing this report

```bash
forge test                             # 66 tests
forge test --match-path test/Invariant.t.sol -vv   # invariants + coverage
forge build --sizes                    # EIP-170 headroom
node tools/wots-check.js               # JS signer vs on-chain verifier
```

The seven proof-of-concept exploits in §2 were run against the pre-rebuild
contract (git `2eda814`) and all seven failed as predicted. They are preserved
in the session record; the fixes are covered by `RegressionTest` in
`test/ObscuraLoan.t.sol`, which asserts the corrected behaviour for each.


---

## 12. Deployment

Two paths, one artifact, identical preflight. Both read the ABI and bytecode
that `forge build` produced (via `deploy/export-artifacts.js`), so neither can
drift from `src/`.

**`deploy/deploy.js`** — automated, key from `PRIVATE_KEY`.
**`deploy/index.html`** — signs in MetaMask; adds/switches Arbitrum One for you.

Neither will broadcast unless the chain is Arbitrum One, OBS has code and
responds as an ERC-20 with non-zero supply, the deployer holds ETH, **and the
constructor succeeds in simulation**. After deploying, both re-read the
contract and verify OBS wiring, oracle wiring, the 150% top tier, the 500–850
band, and an empty pool.

**Verified in this session:**

- `--dry-run` against **live Arbitrum One**: all preflight checks green,
  constructor simulated at 4,054,702 gas ≈ **0.000081 ETH** at 0.02 gwei.
- Full broadcast on a local chain: deployed, confirmed, and **all five
  post-deploy checks passed**; deployment record written.

**Not done: the contract has NOT been deployed to Arbitrum One mainnet.** That
needs a funded deployer key, which this session does not have and should not
have. Run `npm run deploy:dry` first, then `PRIVATE_KEY=0x… npm run deploy`, or
open `deploy/index.html`.

A note on tooling: `anvil` 1.8.1 cannot `eth_call` against forked Arbitrum
headers (`Excess blob gas not set`) at any pinned block. This is an
anvil/Arbitrum incompatibility, not a contract issue — forge's own fork backend
handles the same chain correctly, which is why §7a runs there.


---

## 13. The deployed build is the tested build

The bytecode that ships is compiled with `FOUNDRY_PROFILE=production`
(`via_ir = true`, `optimizer_runs = 1000`), which is **not** the profile the
suite runs under by default. Testing one build and deploying another is a real
and commonly-missed gap, so the production build is now tested explicitly.

Doing that surfaced a genuine defect — in the tests, not the contract:

> **Finding: `vm.warp(block.timestamp + X)` inside a loop is unsound under
> via_ir.** `TIMESTAMP` is loop-invariant from the optimizer's point of view,
> so an IR build legitimately hoists it out of the loop. Every iteration then
> warps to the *same absolute time* and the clock advances only once.
>
> *Observed:* under `via_ir`, iterations 2 and 3 of a three-loan sequence
> emitted identical `maturity` values and `interest: 0`. Ten tests failed,
> including the entire top-tier suite, purely because time stopped moving.
>
> *Fix:* the test clock lives in storage (`clockNow` / `_advance()`), so the
> read-modify-write around the cheatcode call cannot be hoisted.

This mattered: had the production build been shipped on the strength of a
default-profile green run, the suite covering it would have been partly
vacuous — long-dated loans, interest accrual, liquidation-by-interest and every
150% LTV gate were the exact paths that stopped executing.

**Current status — both profiles, full suite:**

| Profile | Unit + fork | Invariants |
|---|---|---|
| default (`optimizer_runs 200`) | 76 pass | 6 pass / 128,000 calls |
| production (`via_ir`, `runs 1000`) | 76 pass | 6 pass / 128,000 calls |

`export-artifacts.js` stamps the profile into the artifact and both deploy
paths surface it, so a deployment cannot be silently made from an untested
build.

### Deployment cost

The production build is meaningfully cheaper to deploy:

| | Init code | Deploy gas | Cost @ 0.02 gwei |
|---|---|---|---|
| default | 19,118 B | 4,054,702 | 0.0000810 ETH |
| production | 17,702 B | **3,764,162** | **0.0000753 ETH** |

Arbitrum bills L2 execution plus an L1 calldata surcharge that tracks
Ethereum's base fee. `deploy.js` reads `ArbGasInfo` (`0x…6C`) and reports the
split, warning when L1 data exceeds 40% of the total — at that point waiting
for a quieter L1 window is the largest saving available. At the time of
writing the L1 share was under 1%.

### QR deployment

> **A rendered QR is not evidence of a live channel.** MetaMask's Node SDK
> (`@metamask/sdk` 0.34) generates a well-formed `metamask.app.link` pairing QR
> while never contacting its relay — measured at **zero packets to the relay
> over 15 s of 50 ms socket-table polling**. Scanning it does nothing, and
> neither side reports an error: the phone opens the channel and finds nobody
> there. The deploy path therefore now blocks on the relay actually opening the
> channel before printing anything, and fails loudly otherwise. The default
> transport is WalletConnect, whose relay is verified live before the QR is
> shown.


`node deploy/deploy.js --qr` runs the full preflight, then serves the MetaMask
page and prints a scannable QR.

**A QR code cannot carry the deployment.** Capacity is 2,953 bytes (binary,
version 40); the init code is 17,702 bytes — roughly 6x over. The QR therefore
encodes a **URL**, and the phone signs. This is how wallet "scan to sign" flows
work generally: the QR carries a short pointer (a URL, or a WalletConnect `wc:`
pairing URI) and the payload travels over the network.

The signing key stays on the phone and never reaches the build machine, which
is a genuine security improvement over `PRIVATE_KEY=` in a shell.
