# System Invariants

Catalogue of invariants the `StableYieldSyncVault` + `SyncFundManager` system is intended to maintain. Each entry names the property, the code paths that enforce or rely on it, and the failure mode if violated. Companion to `docs/sync-vault/design.md` (the locked decisions) and the async `docs/async-vault/invariants.md` (the shared `FundManagerBase` engine).

For each invariant: **State** = the property in plain prose. **Where** = the lines of code that establish or rely on it. **Holds when** = the system states in which the property is meant to hold (hard vs. best-effort / trust-model). **Breaks if** = the failure mode.

Two classes are called out throughout:

- **Hard** — must hold after every op regardless of operator behaviour or external-vault state (modulo external-vault solvency limits).
- **Best-effort** — maintained on every user op and by the operator, but not structurally enforced; degrades gracefully (never bricks user ops) under terminal external impairment. Same trust model as the async family.

Each entry also carries a **verification tag** so the small set worth continuous fuzzing is visually distinct:

- `[echidna]` — a hard, runtime property fuzzed continuously by `test/echidna/EchidnaStableYieldSyncVault.sol`. This is the serious core; a violation is a real bug.
- `[best-effort]` — a real property with legitimate carve-outs (external supply-constrained, deposits closed, terminal impairment); documented, not asserted under fuzzing (too many carve-outs to assert cleanly).
- `[inherited]` — established by `FundManagerBase` (the shared engine) and covered by the async echidna suite, or a one-time constructor-time immutable check; not re-fuzzed here.

**Retired entries.** Some ids below are tombstones (`*removed YYYY-MM-DD*`). The letter+number scheme is **stable** — `docs/sync-vault/design.md` and the echidna harness cross-reference entries by id — so removed invariants leave a stub rather than renumbering the rest. Same convention as `design.md` Invariant 3 and the glossary's retired stubs.

---

## A. Custody

### A.1 — Vault holds no assets `[echidna]`

**State.**

```
underlyingAsset.balanceOf(vault)  == 0   (at all times)
yieldAsset.balanceOf(vault)       == 0   (at all times)
```

The vault is a pure share/accounting face. On deposit it pulls underlying from the caller straight to the FM; it never custodies underlying or super-token.

**Where.** `StableYieldSyncVault._deposit` forwards to the FM (`StableYieldSyncVault.sol:238`); `_withdraw` hands off to `onWithdraw` which pays the receiver directly (`StableYieldSyncVault.sol:253-269`). The FM holds the unlimited underlying allowance the base constructor grants the vault (`FundManagerBase.sol:134`) but the vault never pulls into itself.

**Holds when.** Hard, always.

**Breaks if.** A token is transferred to the vault manually (would not have any inflation impact as the vault's balance is not read by NAV).

### A.2 — Custody hazard: no raw underlying at rest in the FM `[echidna]`

**State.**

```
underlyingAsset.balanceOf(FM) == 0   (between calls)
```

Principal never rests in the FM as raw underlying across calls. It is either deposited into `EXTERNAL_VAULT` or `_upgrade`d into the super-token as part of the yield reserve.

**Where.** `onDeposit` deploys the remainder to external (`SyncFundManager.sol:106-110`); `_rebalanceYieldAssets` `deficit < 0` branch downgrades exactly `underlyingNeeded` super-token and redeposits **exactly** that amount. `onWithdraw` downgrades `fromYieldAssets` and transfers it to the receiver (`SyncFundManager.sol:144-155`).

**Holds when.** Hard, at rest (between external calls). Transiently nonzero mid-call.

**Breaks if.** Any path leaves underlying in the FM at rest **or** the rebalance trim sweeps `balanceOf(FM)` while mid-call raw underlying is present. This is design Invariant 7 and the load-bearing reason every hook ends with the FM flat in underlying. Pinned by `test_prop_aboveTargetReserveDoesNotBlockWithdraw` (multi-op fuzz under `setDepositCap(0)` asserting `balanceOf(FM)_underlying == 0` throughout), `test_deposit_notBrickedAfterSuperTokenDonation`, and `test_deposit_notBrickedAfterRateDropWithClosedExternal`.

### A.3 — *removed 2026-06-03*

Was "FM is the sole custodian and NAV authority." A structural/architectural statement ("hard, by construction"), not a falsifiable runtime property — nothing for echidna to check. The custody facts it asserted are covered operationally by A.1 (vault holds nothing) + A.2 (no raw underlying at rest in the FM). The FM-is-NAV-authority design point lives in `design.md` Decision 11 / Invariant 7.

---

## B. NAV & share accounting

### B.1 — *removed 2026-06-03*

Was "total assets is the sum of recoverable balances" (`totalAssets() == ext.maxWithdraw(FM) + scaledReserve + rawUnderlying`). Near-tautological: `totalManagedAssets()` *literally returns* that sum, so an echidna assertion re-computing the same formula only checks the vault→FM delegation — negligible bug-finding power. The economically-load-bearing consequence (no over-issuance against this NAV) is **B.2**, which is the one worth fuzzing. The unclamped-NAV design rationale lives in `design.md` Invariant 2 / Decision 1.

### B.2 — No share over-issuance `[echidna]`

**State.**

```
convertToAssets(totalSupply()) <= totalManagedAssets()
```

Strictly `<` with the virtual-shares offset. The total claim priced at NAV never exceeds recoverable value.

**Where.** OZ `ERC4626._convertToAssets` against `totalAssets()` (`StableYieldSyncVault.sol:136-138`).

**Holds when.** Hard.

### B.3 — Deposits are NAV-neutral at entry `[echidna]`

**State.** A deposit only changes the *form* of the FM's assets (incoming underlying → external-vault shares + a yield reserve slice), both counted in NAV. Price-per-share immediately before and after a deposit is unchanged (modulo virtual-shares rounding in the vault's favour).

**Where.** `onDeposit`: units granted (`SyncFundManager.sol:87-91`), pre-fund slice upgraded (`SyncFundManager.sol:97-103`), remainder deployed to external (`SyncFundManager.sol:106-110`). Mint happens in the vault before the hook (`StableYieldSyncVault.sol:240`, ahead of the `onDeposit` call at `:242`).

**Holds when.** Hard for the entry transition.

### B.4 — Stayers are not diluted by another holder's op `[echidna]`

**State.** With external NAV and the reserve held fixed, a deposit or withdraw by user X does not decrease `convertToAssets(balanceOf(Y))` for an untouched holder Y. Deposits are NAV-neutral (B.3); withdraws are floor-priced (`shares · NAV / supply`), so rounding leaves residual value with stayers.

**Where.** OZ proportional accounting; withdraw is priced by `_withdraw` → `previewWithdraw`/`_convertToShares` with floor rounding; `onWithdraw` removes exactly the pro-rata slice (`SyncFundManager.sol:116-167`).

**Holds when.** Hard, isolating same-block other-user activity from stream drain (D.3) and external performance (B.5).

### B.5 — *removed 2026-06-03*

Was "share floats with external performance." Explicitly an **economic / directional** property, not a hard equality ("the relevant fuzz check is directional; no clamp pins the price"). There is no invariant equation to falsify — it is the design's intended *behaviour*, documented in `design.md` Core principle / Decision 1 / Invariant 1. The hard accounting guarantees that survive it are B.2 (no over-issuance) and B.4 (no stayer dilution).


### B.6 — Withdrawal pays exactly the priced amount `[echidna]`

**State.**

```
fromReserve + fromExternal == redeemingAssets
receiver underlying balance increases by exactly redeemingAssets
```

**Where.** `onWithdraw`: `fromYieldAssets = ceil(scaledYieldAssetsBalance() · shares / supplyBeforeBurn)` clamped at `redeemingAssets`; `fromExternal = redeemingAssets − fromYieldAssets`; external leg via `EXTERNAL_VAULT.withdraw(fromExternal, receiver, FM)`; reserve leg via `_downgrade(fromYieldAssets · SCALING_FACTOR)` + `safeTransfer(receiver, fromYieldAssets)`.

**Holds when.** Hard, when the call does not revert. Under R-shares, the external leg `fromExternal = f · ext.maxWithdraw + f · raw ≤ ext.maxWithdraw(FM)` is bounded for a compliant external, so F.2 guarantees the call lands for `request ≤ max*` in any loss state. The external leg reverts only on a non-compliant external (decision 5, accepted as a known limitation).

**Breaks if.** `fromYieldAssets` is computed against the wrong divisor, or `_downgrade` yields less underlying than requested (decimals clipping — guarded by `Ceil` rounding on `fromYieldAssets`).

---

## C. Shares & GDA units

### C.1 — Units are granted on deposited principal; transfers move a share-proportional slice `[echidna]`

**State.** On deposit a holder's units increase by `_toUnit(assets) = assets / RAW_PER_UNIT` — proportional to **underlying contributed**, not to shares minted. On a shareholder↔shareholder transfer, units move proportional to the *shares* transferred relative to the sender's share balance. On withdraw, units decrease proportional to *shares* burned.

**Where.** Grant: `onDeposit` (`SyncFundManager.sol:87-91`). Transfer: `_update` → `onShareTransfer`, `delta = ceil(senderUnits · shares / vault.balanceOf(sender))` (`StableYieldSyncVault.sol:275-279`, `FundManagerBase.sol:236-244`). Withdraw: proportional decrease `ceil(holderUnits · shares / totalSharesOwned)` (`SyncFundManager.sol:130-138`).

**Holds when.** Hard, per-op (deposit grants exactly `_toUnit(assets)`; transfer moves `ceil(senderUnits · shares / senderShares)`; withdraw decreases `ceil(holderUnits · shares / totalSharesOwned)` — full exit zeros).

**Breaks if.** A deposit grants units off any base other than `_toUnit(assets)`; a transfer/withdraw delta is computed against the wrong sender-side denominator; a unit move escapes `onDeposit` / `onWithdraw` / `onShareTransfer`.

**Resolved-by-design (2026-05-28).** Under the floating share, `units / shares` is **NOT** a global constant — units track nominal contributed principal; shares track NAV. This is intentional and matches the design's total-return decomposition: the streamed component is sized to **nominal principal** (the "stable yield on what you put in" narrative — `_toUnit(assets) = assets / RAW_PER_UNIT` is NAV-independent), while the residual `external − promised` is delivered as share-price appreciation. A secondary-market buyer of appreciated shares inherits the seller's slot's `units / share`, distinct from what a fresh deposit at the same cash would mint — informational, not a value leak. See `docs/sync-vault/design.md` Invariant 6 (restated 2026-05-28) and the `test_prop_units*` suite in `test/vault/sync/StableYieldSyncVault.props.t.sol`. §H.1 retired.

### C.2 — Yield stream starts at deposit and stops proportionally at withdraw `[echidna]`

**State.** A depositor accrues stream from deposit time (units granted + `_recalibrateFlow()` in the same call). A full exit removes all the holder's units; a partial exit removes a `shares/totalSharesOwned` slice.

**Where.** Start: `onDeposit` (`SyncFundManager.sol:87-91`, `:112`). Stop: `onWithdraw` (`SyncFundManager.sol:130-138`).

**Holds when.** Hard for the unit moves; the *flow* (re)start is best-effort (guarded `_recalibrateFlow()`, see D.2).

### C.3 — Dust position (shares but zero units) does not brick withdraw `[echidna]`

**State.** A sub-`RAW_PER_UNIT` deposit can mint shares but 0 units. `onWithdraw` skips the unit decrease when `holderUnits == 0` rather than reverting.

**Where.** `SyncFundManager.sol:126-138`.

**Holds when.** Hard.

### C.4 — *removed 2026-06-03*

Was "withdraw argument sanity" (`onWithdraw` reverts `BAD_WITHDRAW_ARGS` on `totalSharesOwned == 0` or `shares > totalSharesOwned`). A defensive internal guard, **unreachable from echidna**: `onWithdraw` carries `VAULT_ROLE`, and the only caller (the vault's `_withdraw`) always passes a consistent pre-burn snapshot, so the fuzzer cannot drive the guard true. It is a unit-test concern (a direct-call negative test), not a system invariant.

---

## D. Yield stream & reserve

### D.1 — Forward-solvency horizon `[best-effort]`

**State.**

```
yieldAssetsBalance() >= _targetFlowRate · guaranteedFlowDuration   (+ fee leg)
```

i.e. `evaluateYieldAssetsDeficit() <= 0` after every user op, **unless** the rebalance was supply-constrained by the external vault.

**Where.** `evaluateYieldAssetsDeficit` (`FundManagerBase.sol:263-273`); replenished by `_rebalanceYieldAssets` `deficit > 0` branch, `pulled = min(need, EXTERNAL_VAULT.maxWithdraw(FM))` (`SyncFundManager.sol`); pre-funded from the incoming deposit, capped at `assets` (`SyncFundManager.sol` `onDeposit`); operator `ensureYieldFlowDuration()` (`FundManagerBase.sol:185-194`); **post-payout `_rebalanceYieldAssets()` in `onWithdraw`** cures any deficit (`f > f_u`) or surplus (`f < f_u`) left by shares-proportional reserve sourcing (R-shares, Revision 2026-05-29) — best-effort, bounded by `EXTERNAL_VAULT.maxWithdraw(FM)` on the deficit branch and the OQ #4 `maxDeposit` gate on the surplus branch. Design Invariant 5.

**Holds when.** Best-effort. Clean terminal form: after a deposit large enough to cover its own residual, `deficit > 0 ⇒ EXTERNAL_VAULT.maxWithdraw(FM) == 0` (terminal impairment).

**Breaks if.** Nothing structurally enforces it — same trust model as async. Operator must call `ensureYieldFlowDuration()` between periods of user inactivity (no permissionless `harvest()`).

### D.2 — User ops never bricked: terminal external impairment ⇒ full pause `[echidna]`

**State.** Under terminal external impairment (`EXTERNAL_VAULT.maxWithdraw(FM) == 0` while the FM holds an external position) the vault is **fully paused** — deposits/mints/withdraws/redeems revert cleanly with `ERC4626ExceededMax*`, never `GDA_INSUFFICIENT_BALANCE`. The Superfluid stream keeps paying existing holders from the reserve until it is naturally liquidated.

**Where.** `StableYieldSyncVault._isExternallyPaused()` forces all four `max*` to `0` when `FUND_MANAGER.maxExternalVaultWithdraw() == 0` and `EXTERNAL_VAULT.balanceOf(FM) > 0` (the position gate excludes the empty-vault bootstrap). Resolution chosen 2026-05-27 over the never-implemented "guarded recalibrate" (Revision 2026-05-22, row θ): there are **no** `_recalibrateFlow()` guards — the user hooks (`onDeposit`/`onWithdraw`) can't run while paused, so the drained-reserve recalibrate-revert is unreachable. Operator setters are allowed to revert under terminal impairment (accepted); `setStableYieldRate(0)` always works (a zero-flow recalibrate is a *close*, needs no GDA buffer). Pinned by `test_terminalImpairment_pausesAllEntrypoints`, `test_terminalImpairment_resumesAfterUnfreeze`, `test_terminalImpairment_operatorCanZeroRate` in `StableYieldSyncVault.t.sol`. See `docs/sync-vault/design.md §Revision 2026-05-27`.

**Holds when.** Hard for user ops (the `max*` gate is deterministic). Operator-call liveness under terminal impairment is best-effort / accepted-to-revert.

### D.3 — *removed 2026-06-03*

Was "share price ticks down between rebalances as the stream drains the reserve." Explicitly **"expected behaviour, not a violation"** — an anti-invariant (it describes NAV *decaying*, which is by design). Nothing to assert; asserting it would be asserting a non-property. The timing/MEV consideration it raised is captured in `design.md §Security` ("Share price ticks between rebalances").

### D.4 — Reserve returns to target after withdraw (gated on external `maxDeposit`) `[best-effort]`

**State.** Under normal operation (external vault accepting deposits), after `onWithdraw` the post-payout `_rebalanceYieldAssets()` trims any residual freed excess back into the external vault, so the reserve is at target (not above) and the FM is flat in underlying (A.2). When the external signals deposits closed (`EXTERNAL_VAULT.maxDeposit(FM) < underlyingNeeded`), the trim is **skipped entirely** (Revision 2026-05-28) and the freed excess stays as above-target super-token slack in the reserve until the external accepts deposits again.

**Where.** `SyncFundManager.sol` `_rebalanceYieldAssets` (`deficit < 0` branch with the `maxDeposit` gate); called from `onWithdraw` post-payout. Design Revision 2026-05-22 row η + Revision 2026-05-28; design.md Invariant 5 / Decision 2.

**Holds when.** Best-effort. Drops to "reserve sits above target" while external deposits are closed; idempotent retry on every subsequent `_rebalanceYieldAssets()` call (no accumulation pathology — `deficit < 0` is the steady-state cue, retried until the trim takes). Above-target slack is **safe**: it just funds the stream for longer, doesn't over-issue shares, doesn't transfer value between holders. Inv. 7 / A.2 ("no raw underlying at rest") is preserved hard throughout — the whole branch is skipped rather than down­graded-then-stuck, so we never end up holding raw underlying with nowhere to send it.

**Known limitation.** A non-compliant external vault whose `deposit` reverts despite reporting `maxDeposit > 0` would bypass the pre-check, propagate its revert, and brick the calling op. Pinned by `test_withdraw_brickedByNonCompliantExternal` in `StableYieldSyncVault.t.sol`. Accepted; design.md §Security requires standard, audited ERC-4626 externals.

### D.5 — Flow & fee rate relationships `[inherited]`

**State.**

```
_targetFlowRate  = _flowRatePerUnit · YIELD_POOL.getTotalUnits()
_flowRatePerUnit = 1e12 · stableYieldRate / (YEAR · BP_DENOMINATOR)
feeFlowRate      = _targetFlowRate · FEE_BPS / BP_DENOMINATOR
```

Treasury retains its 1 fee-pool unit for the FM's lifetime.

**Where.** `_targetFlowRate` (`FundManagerBase.sol:300-302`), `_flowRatePerUnit` set in constructor / `setStableYieldRate` (`FundManagerBase.sol:172`, `:205`), fee leg in `_recalibrateFlow` (`FundManagerBase.sol:294-295`), treasury unit (`FundManagerBase.sol:164`).

**Holds when.** Hard (shared engine; see async D.4).

### D.6 — Duration floor `[inherited]`

**State.** `guaranteedFlowDuration >= MIN_GUARANTEED_FLOW_DURATION` (= 1 day). Enforced in the base constructor and `setGuaranteedFlowDuration`.

**Where.** `FundManagerBase.sol:174`, `:215`.

**Holds when.** Hard.

---

## E. Scaling & decimals (inherited)

### E.1 — Yield asset wraps the underlying `[inherited]`

**State.** `YIELD_ASSET.getUnderlyingToken() == underlyingAsset`; constructor reverts `ASSET_MISMATCH` otherwise.

**Where.** `FundManagerBase.sol:137`.

### E.2 — External vault asset matches underlying `[inherited]`

**State.** `EXTERNAL_VAULT.asset() == asset()`; the vault constructor reverts `EXTERNAL_ASSET_MISMATCH` otherwise. Not re-validated in the FM.

**Where.** `StableYieldSyncVault.sol:71`.

### E.3 — Scaling factors `[inherited]`

**State.**

```
SCALING_FACTOR = 10 ** (18 − underlyingDecimals)
RAW_PER_UNIT   = 10 ** (underlyingDecimals − 6)
```

`underlyingDecimals ∈ [6, 18]`; constructor reverts `UNSUPPORTED_DECIMALS` outside. The hard-coded `1e12 = SCALING_FACTOR · RAW_PER_UNIT` carries the existing 18-dec `FIXME` over from async.

**Where.** `FundManagerBase.sol:143-146`, `:171-172`.

---

## F. ERC-4626 compliance

### F.1 — Preview functions work synchronously `[echidna]`

**State.** `previewDeposit/Mint/Redeem/Withdraw` use the OZ default and do **not** revert (unlike the async vault). They price off live `totalAssets()`.

**Where.** Inherited OZ `ERC4626`; no override in `StableYieldSyncVault`.

**Holds when.** Hard.

### F.2 — `max*` are honest, never-bricking bounds `[echidna]`

**State.** `maxDeposit/maxMint` capped by `EXTERNAL_VAULT.maxDeposit(FM)`; `maxWithdraw/maxRedeem` capped by `totalManagedAssets()` (the reserve-inclusive NAV is the global upper bound a redeem can source). A request at exactly `max*` is serviceable.

**Where.** `StableYieldSyncVault.sol:144-170`; `maxExternalDeposit` (`SyncFundManager.sol:182-184`). Delivered by **shares-proportional reserve sourcing in `SyncFundManager.onWithdraw`** (R-shares, Revision 2026-05-29 / OQ #5): `fromReserve = ceil(scaledReserve · shares / supplyBeforeBurn)`, leaving `fromExternal = f · ext.maxWithdraw + f · raw ≤ ext.maxWithdraw(FM)` for a compliant external. Pinned by `test_redeem_serviceableUnderLoss`, `test_withdraw_serviceableUnderLoss`, `test_redeem_atMaxRedeemUnderLoss` (`StableYieldSyncVault.t.sol`) and the multi-holder fuzz `test_prop_F2_neverBricksUnderLoss` (`StableYieldSyncVault.props.t.sol`).

**Holds when.** Hard, modulo external-vault liquidity on the external leg (decision 5). End-to-end against a compliant external in any loss state with any `units / share` drift.

**Breaks if.** External vault reports a `maxWithdraw` larger than it can actually service on `withdraw` (non-standard external vault).

### F.3 — Conversion round-trips favour the vault `[echidna]`

**State.** `convertToAssets(convertToShares(a)) <= a` and `convertToShares(convertToAssets(s)) <= s` (OZ rounding).

**Where.** Inherited OZ `ERC4626`.

**Holds when.** Hard.

---