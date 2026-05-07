# X-Ray Report

> Stable Yield Async Vault | 572 nSLOC | ba1cc7e (`feat/test-coverage`) | Foundry (solc 0.8.34) | 06/05/26

Analyzed branch: `feat/test-coverage` at `ba1cc7e`.

---

## 1. Protocol Overview

**What it does:** Fully asynchronous ERC-7540 vault that pays a capped, smoothed yield to shareholders via a Superfluid GDA stream, with epoch-based forward pricing and a separate treasury contract that holds the yield reserve.

- **Users**: Investors (deposit underlying, claim shares, claim redeems); Fund Operator (runs epoch lifecycle and manages capital); Fund Admin (sets the forward-solvency horizon).
- **Core flow**: `requestDeposit` → operator `closeEpoch` → operator `settleEpoch` → investor `deposit/mint` claim → yield stream begins.
- **Key mechanism**: Epoch-based forward pricing — assets per share is locked at `closeEpoch` from a NAV reported by the operator, then applied at claim time. Yield is paid as a Superfluid GDA stream funded by a SuperToken reserve.
- **Token model**: Underlying ERC-20 (e.g. USDC) → wrapped SuperToken (e.g. USDCx) → distributed via GDA pool to shareholders. Vault shares are non-transferable ERC-20.
- **Admin model**: Two operational roles in `FundManager` (`FUND_OPERATOR_ROLE`, `DEFAULT_ADMIN_ROLE`) plus an internal `VAULT_ROLE` granted only to the paired vault. No timelock, no multisig, no pause.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Vault | `StableYieldAsyncVault` | 363 | ERC-7540 async accounting, epoch lifecycle hooks, claim flow |
| Treasury / Yield | `FundManager` | 209 | Underlying/SuperToken treasury, GDA pool admin, flow rate calibration |

### How It Fits Together

The core trick: the vault never sees the yield. Investors hold non-transferable shares whose NAV is settled epoch-by-epoch, and the actual payout is a Superfluid stream from the FundManager's SuperToken reserve to investor pool units — the two flows are accounted independently.

#### Deposit (request → close → settle → claim)

```
Investor.requestDeposit(assets, controller, owner)
 └─ StableYieldAsyncVault.safeTransferFrom(owner → vault)            *assets escrowed in vault, not FM*
    └─ totalPendingDepositAssets += assets
       └─ cs.depositRequestEpoch = currentEpoch

Operator.closeEpoch(workingAssets)
 └─ FundManager.closeEpoch
    └─ totalAssets = workingAssets + unutilized + scaledYieldAssets    *NAV reported to vault*
       └─ Vault.onCloseEpoch(totalAssets)
          └─ rate = totalAssets · 1e18 / effectiveSupply               *forward price locked*

Operator.settleEpoch()
 └─ FundManager.settleEpoch
    └─ Vault.onSettleEpoch                                             *deposits/redeems netted*
       └─ if surplus: safeTransfer(vault → FM)
       └─ if deficit: safeTransferFrom(FM → vault) [pre-approved max]
    └─ POOL.increaseMemberUnits(self, _toUnit(deposits))               *FM holds units pending claim*
    └─ _rebalanceYieldAssets() + _recalibrateFlow()

Investor.deposit(assets, receiver, controller)
    └─ _resolveClaimableDeposit (lazy-settle)
    └─ _mint(receiver, shares)                                         *shares minted at claim*
       └─ FundManager.onClaimDeposit(receiver, depositAssets)
          └─ POOL.increaseMemberUnits(receiver, units)                  *yield stream begins now*
          └─ POOL.decreaseMemberUnits(FM, units)
```

#### Redeem (request → close → settle → claim)

```
Investor.requestRedeem(shares, controller, owner)
 └─ FundManager.onRequestRedeem(owner, sharesRedeemed, totalOwned)     *units decremented immediately*
    └─ POOL.updateMemberUnits(owner, owned − delta)
    └─ _recalibrateFlow()                                              *yield stops at request*
 └─ _transfer(owner → vault)                                           *shares custodied by vault until claim*
    └─ totalPendingRedeemShares += shares

[close + settle: same as deposit; vault adds redeemingAssets to totalClaimableRedeemAssets]

Investor.redeem(shares, receiver, controller)
 └─ _claimRedeem
    ├─ _burn(vault, shares)
    └─ underlyingAsset.safeTransfer(receiver, assets)                  *assets paid from vault custody*
```

#### Operator capital management (out-of-band)

```
Operator.give(amount)  → safeTransferFrom(operator → FM)              *deposit returns from external strategy*
Operator.take(amount)  → safeTransfer(FM → operator)                  *deploy capital externally; no solvency check*
```

`give` / `take` are not gated by the epoch lifecycle and bypass any solvency precondition. The operator alone is responsible for sequencing them with `canSettleEpoch` / `evaluateFunding` (per E.5 in `docs/invariants.md`).

#### Yield-flow rebalancing

```
FundManager.setStableYieldRate(newRate) | settleEpoch | ensureYieldFlowDuration
 └─ _rebalanceYieldAssets
    ├─ deficit > 0: _upgrade(deficit/SCALING_FACTOR + 1)               *upgrade USDC → USDCx*
    └─ deficit < 0: _downgrade(|deficit|)                              *downgrade USDCx → USDC*
 └─ _recalibrateFlow → YIELD_ASSET.distributeFlow(POOL, _targetFlowRate())
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Yield Aggregator / Vault** with **Liquid-Staking-style streaming** characteristics

ERC-7540 vault primitive (`requestDeposit`, `requestRedeem`, `convertToShares`, share-based accounting, `totalAssets`) drives the primary classification. A stable, operator-set rate paid as a Superfluid GDA stream from a SuperToken reserve adds liquid-staking-style "rewards reporting" risk: the share NAV is *not* derived from real yield — it is reported by the operator at `closeEpoch(workingAssets)` and the stream rate is set by the operator at `setStableYieldRate(newRate)`.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Fund Operator (`FUND_OPERATOR_ROLE`) | Trusted | Reports `workingAssets` for NAV; runs `closeEpoch` + `settleEpoch`; arbitrary `setStableYieldRate` (no minimum era, no rate cap); arbitrary `give` / `take` of underlying with no solvency check; not subject to any pause or timelock — all actions instant. |
| Fund Admin (`DEFAULT_ADMIN_ROLE`) | Trusted | `setGuaranteedFlowDuration` (subject only to `MIN_GUARANTEED_FLOW_DURATION = 1 day` floor); inherits OZ `AccessControl` so can grant/revoke any role including `FUND_OPERATOR_ROLE`. All actions instant. |
| Investor / Controller | Untrusted | Any address: can `requestDeposit` for self or via `setOperator`-approved delegate, `requestRedeem`, `claim`, `setOperator`. |
| Vault contract (`VAULT_ROLE`) | System-internal | Calls FM's `onClaimDeposit` and `onRequestRedeem`; role granted exactly once in FM constructor to deploying vault, then immutably pinned. |

**Adversary Ranking** (ordered by threat level for this protocol type):

1. **Compromised / careless operator** — Operator's `workingAssets` figure feeds NAV directly; `setStableYieldRate` has no rate-bound and no era floor; `take` has no solvency check. This is the single largest blast radius in the system.
2. **First-depositor / share-inflation attacker** — Vault uses `effectiveSupply == 0 ? 1e18 : totalAssets · 1e18 / effectiveSupply`. There is no virtual offset and no minimum first deposit. Manipulation paths are constrained by the operator-reported NAV (donation alone cannot inflate `totalAssets`), but are worth tracing in detail.
3. **Compromised admin** — Can re-grant `FUND_OPERATOR_ROLE`, change forward-solvency horizon. Cannot directly move funds but can rotate operator and is upstream of (1).
4. **Operator front-runs request/claim** — Forward pricing means investors don't know the rate until close; a malicious operator can sandwich requests by manipulating reported NAV between observation and `closeEpoch`.
5. **Composability adversary on Superfluid pool** — The GDA pool admin is FM, but the SuperToken framework is upgradeable by Superfluid governance and the `distributeFlow` / `connectPool` semantics depend on the framework version.

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **Investor → Vault**. Untrusted caller. Per-action checks: `assets/shares > 0`, `owner == msg.sender || _isOperator[owner][msg.sender]`, `EPOCH_SETTLEMENT_IN_PROGRESS` gate. Reentrancy: vault has no `nonReentrant` modifiers — it relies on checks-effects-interactions (state mutations precede `_mint` / external transfer in claim paths).
- **Vault ↔ FundManager**. Pinned at deployment via FM constructor with `VAULT = msg.sender` (immutable) and `_grantRole(VAULT_ROLE, msg.sender)`. Vault's settlement hooks gated by `onlyFundManager` modifier. There is no key rotation for this boundary — if either contract has a critical bug, the pair is unrecoverable (no factory, no proxy).
- **Operator/Admin → FundManager**. Roles via OpenZeppelin `AccessControl`. **No timelock, no multisig at the contract level, no `Pausable`.** Every operator/admin action takes effect instantly and irreversibly. *Git signal: `access_control` security area shows 53 modifying commits — recently and frequently churned.*
- **FundManager → Superfluid framework**. FM is admin of a GDA pool created at construction with `transferabilityForUnitsOwner: false` and `distributionFromAnyAddress: false`. Boundary-broken if Superfluid upgrades alter `distributeFlow` semantics, change SuperToken decimals, or modify pool unit math.

### Key Attack Surfaces

- **`FUND_OPERATOR_ROLE` compromise — full operational blast radius.** A single compromised operator key can: (a) drain the FundManager via `take(amount)` (`FundManager.sol:198`) with no solvency check or epoch-state gate; (b) mis-report NAV through `closeEpoch(workingAssets)` (`FundManager.sol:156`) to set an arbitrary epoch rate; (c) flip `stableYieldRate` every block (`FundManager.sol:204`, `FIXME` flags missing minimum era duration), draining the SuperToken reserve faster than the duration horizon promises; (d) call `give` or `take` between `closeEpoch` and `settleEpoch`, which can either (i) make `settleEpoch` revert with `INSUFFICIENT_ASSETS_IN_FUND_MANAGER` (denying settlement) or (ii) require a re-rebalance after settle.
- **NAV-manipulation through `workingAssets` — rate-locking attack on requests-in-flight.** The operator chooses `workingAssets` at `closeEpoch` (`FundManager.sol:158`); the vault formula is `totalAssets = workingAssets + unutilizedAssetsBalance() + scaledYieldAssetsBalance()`, of which only the first term is operator-controlled. With no oracle and no on-chain truth for working capital, the operator can re-price both depositors and redeemers in either direction relative to true fair value, since they all settle at the same locked `epochRate`.
- **Zero-NAV permanently freezes deposits in the closing epoch.** `onCloseEpoch` does not reject `_totalAssets == 0`. With `effectiveSupply > 0`, `epochRate = 0`, and any subsequent `_settleDepositIfNeeded` call divides by zero in `pendingAssets.mulDiv(1e18, 0)` (`StableYieldAsyncVault.sol:582`). Documented in `docs/invariants.md` §B.4 as an unfixed soft-DoS path.
- **No separate preflight forward-solvency check on rate/duration changes.** `setStableYieldRate` and `setGuaranteedFlowDuration` rely on `_rebalanceYieldAssets` to maintain the reserve horizon. If the required upgrade cannot be funded, the path reverts with `INSUFFICIENT_UNUTILIZED_ASSETS`; otherwise the change is accepted without a distinct post-state invariant assertion.
- **First-epoch / empty-vault rate handling.** `_lastSettledRate` returns `1e18` until any epoch is settled (`StableYieldAsyncVault.sol:551–562`); `effectiveSupply == 0` short-circuits to `1e18`. The first depositor's claim rate is therefore deterministic, but the value of those shares relative to NAV is set by whatever `workingAssets` the operator reports at the first `closeEpoch`. Trace the empty-vault → first-deposit → first-redeem path under different operator-reported NAV scenarios.
- **`int96` / `uint128` truncation in flow-rate and unit math.** `_flowRatePerUnit · totalUnits` is cast to `int96` for `distributeFlow` (`FundManager.sol:401–402`) with no bounds check; pool unit deltas are cast to `uint128` (`FundManager.sol:267, 270, 405–407`). Combined with operator-controlled rate, large pool size + high rate could overflow silently per `docs/invariants.md` §H.1, §H.2.
- **Decimals-clipping `+1` behavior.** `_rebalanceYieldAssets` adds `+1` to the upgrade amount (`FundManager.sol:387`) and `evaluateFunding` adds `+1` on the deficit branch (`FundManager.sol:317`) to cover sub-atom rounding. Verify both behave correctly when the deficit is exactly representable (no over-upgrade) and at the underlying-decimals boundary (6 vs 18).
- **Round-trip rate divergence between `onCloseEpoch` and `onSettleEpoch`.** Rate is computed at close via `totalAssets · 1e18 / effectiveSupply` then applied at settle via `redeemingShares · rate / 1e18` and `depositingAssets · 1e18 / rate` — three separate divisions with floor rounding. `_unclaimedDepositShares` is incremented by `depositingAssets · 1e18 / rate` (`StableYieldAsyncVault.sol:275`) which can drift from the per-controller `pendingAssets · 1e18 / epochRate` lazy-settle math (`StableYieldAsyncVault.sol:582`). Audit whether the dust accumulation can cause `_unclaimedDepositShares` underflow in `_claimDeposit`.
- **`onSettleEpoch` callback ordering with FM state.** `FundManager.settleEpoch` is `nonReentrant` but calls back into the vault, which then calls back into FM on the deficit path (`safeTransferFrom(FM, vault, deficit)` consuming the unlimited approval set in the FM constructor). FM is `ReentrancyGuard`; the `transferFrom` itself doesn't re-enter, but verify the assumption holds across SuperToken / underlying token implementations.

### Protocol-Type Concerns

**As a Yield Aggregator / Vault:**
- Share-price rounding: `_deposit` floors shares (`StableYieldAsyncVault.sol:463`), `_withdraw` ceils shares (`:487`), `_mintShares` ceils assets (`:471`), `_redeem` floors assets (`:478`). Per `docs/invariants.md` §H.3 this is asymmetric in the vault's favor; verify the asymmetry compounds rather than cancels across deposit→redeem round trips.
- `convertToShares(convertToAssets(s))` and the inverse: both use `_lastSettledRate()` at *current* call time but the round-trip preservation invariant from ERC-4626 is undefined for a forward-priced async vault. Behavior across an epoch boundary is unspecified.
- `totalAssets()` returns `_lastReportedTotalAssets` (`StableYieldAsyncVault.sol:391–393`) — stale between settlements. Any integrator relying on it for real-time NAV will read a value that is off by up to one full epoch.

**As a Liquid-Staking-style streaming protocol:**
- The "exchange rate" (epoch rate) is operator-reported, not computed from observable on-chain yield. There is no rebasing-vs-shares ambiguity (shares are non-rebasing) but there is the equivalent rewards-reporting risk: the operator decides what the protocol thinks it earned.
- The yield stream commences at *claim*, not at *request* — D.1 in invariants. A depositor who delays claiming forfeits stream that period; the FM holds the units in self until claim. This is intentional but interacts with redeems: a controller who requests redeem before claiming a pending deposit may end up with a unit balance that doesn't match their share balance (the deposit-claim path expects FM to still hold the units to transfer).

### Temporal Risk Profile

**Deployment & Initialization:**
- **Empty-vault rate is `1e18`; first-depositor share value depends entirely on first reported NAV.** `effectiveSupply == 0` short-circuits to `1e18` (`StableYieldAsyncVault.sol:227`); first depositor's claim rate is therefore deterministic. But the second epoch's rate is `workingAssets + unutilized + scaledYield` divided by their shares — if the operator reports too low or too high `workingAssets` at the first `closeEpoch`, the price discovery is asymmetric. *Mitigation: operator-trust-only.*
- **Constructor pins vault ↔ FundManager irreversibly.** No factory, no proxy, no migration path. A bug in either contract requires a full redeployment and migration coordinated by users — there is no admin recovery.
- **`stableYieldRate`, `guaranteedFlowDuration`, and the first depositor's claim are all gated only by constructor parameters.** No post-deploy validation that the initial rate is reachable given expected pool size.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **Superfluid SuperToken** — via `FundManager._upgrade / _downgrade` and `YIELD_ASSET.distributeFlow(POOL, ...)`
> - Assumes: SuperToken wraps the exact `_asset` (verified at construction via `getUnderlyingToken() != _asset`); `getUnderlyingDecimals()` in `[6, 18]`; `upgrade` mints exactly `underlyingAmount * SCALING_FACTOR`; `downgrade` returns exactly `superTokenAmount / SCALING_FACTOR` units of underlying; `distributeFlow` accepts the computed `int96` flow rate.
> - Validates: asset match (`ASSET_MISMATCH`), decimals range (`UNSUPPORTED_DECIMALS`), `+1` clipping on upgrade.
> - Mutability: SuperToken is upgradeable by Superfluid governance.
> - On failure: revert (Superfluid call propagates).

> **Superfluid GDA Pool** — via `YIELD_ASSET.createPool` and `POOL.{increaseMemberUnits,decreaseMemberUnits,updateMemberUnits,getUnits,getTotalUnits,getTotalFlowRate}`
> - Assumes: pool config (non-transferable units, distribution-only-by-admin) is enforced post-creation; member unit math doesn't truncate under `uint128`; `getTotalUnits` and `getUnits(addr)` are reliable post-mutation.
> - Validates: pool config set at creation (`FundManager.sol:131–135`).
> - Mutability: pool admin is FM (immutable); GDA framework is upgradeable by Superfluid.
> - On failure: revert.

> **Underlying ERC-20 (e.g. USDC)** — via `safeTransfer`, `safeTransferFrom`, `approve(MAX)` (FM → vault) and `approve(YIELD_ASSET, amount)` (FM upgrade)
> - Assumes: standard ERC-20; non-rebasing; non-fee-on-transfer; not blocking the vault or FM via blocklist.
> - Validates: nothing — relies on `SafeERC20` for the non-reverting-on-failure case only.
> - Mutability: USDC is an upgradeable proxy (Centre / Circle controlled).
> - On failure: `SafeERC20` reverts.

**Token Assumptions** (unvalidated):
- **Fee-on-transfer**: `requestDeposit` increments `totalPendingDepositAssets += assets` but only `safeTransferFrom`s — if the underlying takes a fee, internal accounting will exceed actual balance and break invariant A.1 (`underlyingAsset.balanceOf(vault) == totalPendingDepositAssets + totalClaimableRedeemAssets`).
- **Rebasing underlying**: vault has no balance-based reconciliation; rebase events would silently drift accounting.
- **Underlying blocklist**: USDC blocklist of vault, FM, or any holder of pool units would freeze claim and stream paths respectively.

**Shared State Exposure:**
- The GDA pool is exposed to any other contract that reads pool state via Superfluid framework helpers, but member units are non-transferable so cross-protocol arbitrage on units is disabled by design.

---

## 3. Invariants

### Stated Invariants

`docs/invariants.md` enumerates 35+ invariants across A–H sections. Audit-relevant highlights:

- **A.1 — Vault underlying balance partition** (`underlyingAsset.balanceOf(vault) == totalPendingDepositAssets + totalClaimableRedeemAssets`). `StableYieldAsyncVault.sol:67–72`. Holds at quiescent state only; out-of-band transfers in violate one direction.
- **A.3 — Single-snapshot serialization** (`_snapshot.epoch == 0 ⇔ no epoch in close→settle window`). `StableYieldAsyncVault.sol:128, 176, 220, 252, 289`.
- **A.4 — Effective supply correction** (`totalSupply + unclaimedDepositShares − unclaimedRedeemShares`) used for rate calc. `StableYieldAsyncVault.sol:224–227`.
- **B.3 — `canSettleEpoch` preconditions enforced before vault hook runs**. `FundManager.sol:163–165, 331–361`.
- **C.1 — Shares non-transferable**. `StableYieldAsyncVault.sol:303–313`.
- **D.1 — Yield stream commences at claim, not at request**. `FundManager.sol:243–251`.
- **D.2 — Yield stream stops at requestRedeem, not at claim**. `FundManager.sol:254–273`.
- **D.5 — Forward-solvency horizon** (`yieldAssetsBalance() ≥ targetFlowRate · guaranteedFlowDuration`). `FundManager.sol:322–328, 331–361, 382–399`. Per `docs/invariants.md` §D.5 caveat — only enforced via `canSettleEpoch` (pre-settle) and `_rebalanceYieldAssets` revert on missing underlying; no preflight on rate / duration setter.
- **F.5 — Vault/FM pair pinning is immutable** (no factory, no role re-grant path).
- **H.3 — Rate rounding favors vault on every path**.

### Inferred Invariants

- **Authorisation symmetry** — `requestDeposit`/`requestRedeem` check `owner == msg.sender || _isOperator[owner][msg.sender]`; `deposit/mint/redeem/withdraw` (3-arg) check the same against `controller`. Derived from `StableYieldAsyncVault.sol:127, 152, 163, 175, 207, 213`. If violated: arbitrary third party drains another investor's pending or claimable balances.
- **Epoch monotonicity** — `currentEpoch` is monotonically increasing; `_epochSettled[epoch]` is set exactly once per epoch (no clear path). Derived from `StableYieldAsyncVault.sol:242, 280`. If violated: rate replay on a re-opened epoch.
- **`_unclaimedDepositShares` non-negative** — incremented by `depositingAssets · 1e18 / rate` at settle, decremented by per-controller `pendingAssets · 1e18 / epochRate` at lazy-settle and again by `shares` at `_claimDeposit`. The two decrement paths are different formulas; a dust mismatch could underflow. Derived from `StableYieldAsyncVault.sol:275, 526, 582–588`. If violated: claim path reverts and locks all claims for the affected epoch.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `README.md` at repo root |
| NatSpec | Thorough | Every external/public on impls + interfaces; `@inheritdoc` used throughout |
| Spec/Whitepaper | Present | `docs/invariants.md` (per spec); `docs/flow/{deposit,redeem,settlement}-flow.md`; `docs/glossary.md` |
| Inline Comments | Adequate | Section banners (ASCII art) demarcate Storage/Constructor/External/View/Internal/Modifiers; rate-derivation comments explain decimals math |

The `docs/invariants.md` document is unusually complete for a POC and self-flags four `FIXME` items (§I), making it both a spec and an audit pre-brief.

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 3 | File scan |
| Test functions | 100 | `forge test` output (45 + 55) |
| Line coverage (src) | 100% (`FundManager`), 100% (`StableYieldAsyncVault`) | `forge coverage` |
| Branch coverage (src) | 95% (`FundManager`), 100% (`StableYieldAsyncVault`) | `forge coverage` |
| Function coverage (src) | 100% / 100% | `forge coverage` |
| Tests passing | 100/100 | `forge test` |

### Test Depth

| Category | Count | Contracts Covered |
|----------|------:|-------------------|
| Unit | ~30 | `StableYieldAsyncVault`, `FundManager` (broad) |
| Stateless Fuzz | ~70 | `StableYieldAsyncVault`, `FundManager` (broad) |
| Stateful Fuzz (Foundry invariant) | 0 | none |
| Stateful Fuzz (Echidna / Medusa) | 0 | none |
| Formal Verification (Certora / Halmos / HEVM) | 0 | none |
| Scribble Annotations | 0 | none |
| Integration | 0 (test base deploys full Superfluid framework, but tests are in-process units) | n/a |
| Fork | 0 | none |

### Gaps

- **No stateful invariant testing.** `docs/invariants.md` enumerates 35+ properties but none are encoded as `invariant_*` Foundry handlers, Echidna/Medusa harnesses, or Certora rules. A.1 (balance partition), B.3 (`canSettleEpoch` strict precondition), D.5 (forward-solvency horizon), and H.1 / H.2 (`int96` / `uint128` overflow) are all amenable to property-based fuzzing and would meaningfully widen the assurance envelope beyond the current example-based coverage.
- **No fork tests.** Behavior against the production Superfluid framework, real USDC (with proxy upgrades, blocklist, fee semantics), and live network conditions is not exercised.
- **`give`/`take` interaction with the close→settle window** is documented in `docs/invariants.md` §E.5 as an operator-coordination requirement but not directly fuzzed.

---

## 6. Developer & Git History

> Repo shape: **normal_dev** — 100 commits over 36 days (2026-03-31 → 2026-05-06), 63 of them touch source files. Single developer.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| Pilou  | 100     | +3243 / −1496      | 100%                |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 1 | Single-dev — no peer review on commit boundary |
| Merge commits | 1 of 100 (1%) | Linear history; no PR-merge workflow visible |
| Repo age | 2026-03-31 → 2026-05-06 | 36 days |
| Recent source activity (30d) | 20 commits | Active, with several `fix:` commits in the last 8 days |
| Test co-change rate | 16% | Only 16% of source-changing commits also touch tests (file co-modification, not coverage) |
| Fix-without-test rate | 60% | Of fix-tagged commits, 60% don't co-modify tests |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| `src/StableYieldAsyncVault.sol` | 35 | Highest churn — primary target for review |
| `src/FundManager.sol` | 28 | Second-highest churn — recent `fix: generalize flowRatePerUnit formula` (HEAD) |
| `src/interfaces/IFundManager.sol` | 22 | Frequently edited operator/admin interface surface |
| `src/interfaces/vault/IStableYieldAsyncVault.sol` | 11 | Stable |

### Security-Relevant Commits

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| 838c293 | 2026-04-22 | fix: review constructor | 14 | tightens access control + token transfer changes |
| a3bc5f4 | 2026-04-22 | fix: updated fundManager and its interface | 14 | rewrites access control + accounting |
| ba1cc7e | 2026-05-06 | fix: generalize flowRatePerUnit formula | n/a | HEAD; touches flow-rate math (D.4) |
| 315b78a | 2026-04-30 | fix: update pool config to prevent distribution from any address | n/a | pool-config tightening |
| f48f4fe | 2026-04-29 | fix: `evaluateFunding` formula | n/a | NAV-related view |
| 5d77f20 | 2026-04-28 | feat: change access control for `setGuaranteedFlowDuration` | n/a | role boundary moved to admin |
| 558545d | 2026-04-28 | feat: updated constructor — make vault immutable in FundManager | n/a | vault ↔ FM pinning hardened (F.5) |
| 827f4ea | 2026-04-28 | feat: replace `move` callback with unlimited approval + `transferFrom` | n/a | trust model change — see E.4 |

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| access_control | 53 | `FundManager.sol`, `StableYieldAsyncVault.sol` |
| fund_flows | 53 | `FundManager.sol`, `StableYieldAsyncVault.sol`, `IStableYieldAsyncVault.sol` |
| state_machines | (high) | epoch lifecycle in `StableYieldAsyncVault.sol` (closeEpoch / settleEpoch / claim) |

### Forked Dependencies

| Library | Path | Upstream | Status | Notes |
|---------|------|----------|--------|-------|
| ERC-7540-Reference | `lib/ERC-7540-Reference` | ERC-7540 reference impl | Submodule | 100 `.sol` files; the project does **not** import from this library (interfaces are vendored under `src/interfaces/vault/`). Submodule kept for reference only — no live dependency. |
| openzeppelin-contracts-v5 | `lib/openzeppelin-contracts-v5` | OpenZeppelin v5 | Submodule | 274 files; both `@openzeppelin/contracts/` and `@openzeppelin-v5/contracts/` resolve to this single tree — vault and FM use different prefixes for the same code. |
| superfluid-protocol-monorepo | `lib/superfluid-protocol-monorepo` | Superfluid Protocol | Submodule | 1786 files; supplies `SuperTokenV1Library`, `ISuperToken`, `ISuperfluidPool`. Wide pragma fanout in the submodule but only the GDA + SuperToken interfaces are consumed. |
| (removed) openzeppelin-contracts | `lib/openzeppelin-contracts` | OpenZeppelin v4 | Removed at `e92a0b9` | Project consolidated on v5. |

### Technical Debt Markers

| File:Line | Type | Text | Author | Date |
|-----------|------|------|--------|------|
| `src/FundManager.sol:205` | FIXME | enforce minimum era duration | Pilou | 2026-04-28 |
| `src/FundManager.sol:321` | FIXME | add buffer to the required balance | Pilou | 2026-04-29 |

The remaining FIXME markers sit in security-critical paths (`setStableYieldRate`, `evaluateYieldAssetsDeficit`).

There is also a dead statement at `FundManager.sol:246` — `_toUnit(depositAssets);` is called twice in `onClaimDeposit`, the second invocation has no assignment and no effect. Not a `FIXME` marker but worth review.

### Security Observations

- **Single-developer codebase, no peer review at commit boundary.** All 100 commits are by one author; only 1 merge commit. Audit-time review is the first independent inspection of every line.
- **`access_control` is the highest-churn security area (53 commits).** Several recent commits explicitly rework role gating (`5d77f20` moved `setGuaranteedFlowDuration` to admin; `558545d` made the vault address immutable in FM). This area is still settling.
- **Two `score=14` fix commits within four days of each other** (`838c293`, `a3bc5f4`, both 2026-04-22) overlap access control and token-transfer logic — the kind of dual-domain fix that warrants careful review of what they replaced.
- **HEAD is a `fix:` commit** (`ba1cc7e: fix: generalize flowRatePerUnit formula`) touching the core flow-rate derivation and co-modifying tests. Last-second formula change increases risk of regression in §D.4.
- **60% of fix-tagged commits don't co-modify tests** (file-level co-modification metric — coverage itself is 100% on `src/`, so this signals process pattern not coverage gap).
- **Rate/duration enforcement is rebalance-based**: the current invariant docs describe no separate preflight forward-solvency assertion on `setStableYieldRate` or `setGuaranteedFlowDuration`; enforcement depends on `_rebalanceYieldAssets` succeeding.

### Cross-Reference Synthesis

- `StableYieldAsyncVault.sol` is the highest-churn file (35 modifications) **and** carries the most security-critical state (`_snapshot`, `_epochRate`, `_unclaimedDepositShares`, `_unclaimedRedeemShares`). Prioritize the close→settle→claim path for review — this is where the §A.4/§A.5 lag-correction math meets recent edits.
- `access_control` and `fund_flows` security areas have the same 53-commit count, with overlap on `FundManager.sol`. The `give`/`take`/`setStableYieldRate` cluster — flagged in Section 2 as the operator's largest blast radius — is precisely the code that has been edited the most.
- HEAD's `fix: generalize flowRatePerUnit formula` (D.4) lands one day before this audit, on a math-heavy path with no stateful fuzz coverage. Section 5's "no stateful fuzz on rate/horizon math" gap intersects directly with the latest unreviewed change.
- Three of four `FIXME` markers (`FundManager.sol:205, 323, 347`) sit at exactly the locations where `docs/invariants.md` §I.1, §I.3, §I.6, §I.7 acknowledge unfinished enforcement — they are not stray comments, they are the documented known gaps.

---

## X-Ray Verdict

**EXPOSED** — A documented and well-tested POC whose roles have no timelock, no multisig, and no pause; with self-flagged FIXMEs in security-critical paths (rate setter, solvency-deficit math, settle-precondition scaling) and a NAV input that is fully operator-controlled.

Lowest tier across Tests (ADEQUATE — unit + stateless fuzz, 100% line coverage on src, no stateful fuzz / formal verification), Docs (HARDENED — README + thorough NatSpec + spec docs + invariant catalogue), Access Control (FRAGILE — roles exist, no timelock, no multisig, no pause). Lowest = FRAGILE; dropped one tier because three of four `FIXME` markers sit in security-critical paths (setStableYieldRate, evaluateYieldAssetsDeficit, canSettleEpoch).

**Structural facts:**
1. 572 nSLOC across 2 in-scope contracts; pinned 1:1 at construction (no factory, no proxy, no migration path).
2. 100 test functions, 100% line coverage and 95–100% branch coverage on `src/`; 0 stateful fuzz, 0 formal verification, 0 fork tests.
3. Single developer, 100 commits over 36 days, 1 merge commit; 53-commit churn each on `access_control` and `fund_flows` security areas.
4. 4 self-flagged `FIXME` markers; 3 sit in security-critical FundManager paths corresponding to documented gaps in `docs/invariants.md` §I.
5. No oracle, no governance, no upgradeability — but operator-reported NAV (`workingAssets`) and operator-set yield rate are the protocol's two main truth sources, both instant and unbounded.
