# System Invariants

Catalogue of invariants the `StableYieldSyncVault` + `SyncFundManager` system is intended to maintain. Each entry names the property, the code paths that enforce or rely on it, and the failure mode if violated. Companion to `docs/sync-vault/design.md` (the locked decisions) and the async `docs/async-vault/invariants.md` (the shared `FundManagerBase` engine).

For each invariant: **State** = the property in plain prose. **Where** = the lines of code that establish or rely on it. **Holds when** = the system states in which the property is meant to hold (hard vs. best-effort / trust-model). **Breaks if** = the failure mode.

Two classes are called out throughout:

- **Hard** — must hold after every op regardless of operator behaviour or external-vault state (modulo external-vault solvency limits).
- **Best-effort** — maintained on every user op and by the operator, but not structurally enforced; degrades gracefully (never bricks user ops) under terminal external impairment. Same trust model as the async family.

This is the **floating-share** model (clamp / `trackedPrincipal` dropped 2026-05-26). There is no protocol-owned buffer excluded from the share price.

---

## A. Custody

### A.1 — Vault holds no assets

**State.**

```
underlyingAsset.balanceOf(vault)  == 0   (at all times)
yieldAsset.balanceOf(vault)       == 0   (at all times)
```

The vault is a pure share/accounting face. On deposit it pulls underlying from the caller straight to the FM; it never custodies underlying or super-token.

**Where.** `StableYieldSyncVault._deposit` forwards to the FM (`StableYieldSyncVault.sol:185`); `_withdraw` hands off to `onWithdraw` which pays the receiver directly (`StableYieldSyncVault.sol:213`). The FM holds the unlimited underlying allowance the base constructor grants the vault (`FundManagerBase.sol:134`) but the vault never pulls into itself.

**Holds when.** Hard, always.

**Breaks if.** A future code path mints/holds assets in the vault, or a token is transferred to the vault out-of-band (would inflate nothing — the vault's balance is not read by NAV — but violates the "thin face" assumption).

### A.2 — Custody hazard: no raw underlying at rest in the FM

**State.**

```
underlyingAsset.balanceOf(FM) == 0   (between calls)
```

Principal never rests in the FM as raw underlying across calls — within each call it is either deposited into `EXTERNAL_VAULT` or `_upgrade`d into the super-token reserve.

**Where.** `onDeposit` deploys the remainder to external (`SyncFundManager.sol:106-110`); `_rebalanceYieldAssets` `deficit < 0` branch downgrades then redeposits its *entire* underlying balance — and the branch is **skipped entirely if `EXTERNAL_VAULT.maxDeposit(FM)` is insufficient** (Revision 2026-05-28, `SyncFundManager.sol` `_rebalanceYieldAssets`), so the downgrade never happens when the redeposit can't follow it; `onWithdraw` downgrades `fromReserve` and transfers it to the receiver (`SyncFundManager.sol:160-162`).

**Holds when.** Hard, at rest (between external calls). Transiently nonzero mid-call.

**Breaks if.** Any path leaves underlying in the FM at rest — the next `_rebalanceYieldAssets()` `deficit < 0` branch would sweep it into the reserve, silently converting unaccounted underlying into reserve and disturbing NAV partitioning. This is design Invariant 7 and the load-bearing reason every hook ends with the FM flat in underlying. The 2026-05-28 best-effort-trim gate preserves this hard even when the external is deposits-closed: skipping the *whole* branch (rather than a `try/catch` around the deposit) avoids any post-downgrade "underlying-at-rest" state. Pinned by `test_prop_aboveTargetReserveDoesNotBlockWithdraw` (multi-op fuzz under `setDepositCap(0)` asserting `balanceOf(FM)_underlying == 0` throughout).

### A.3 — FM is the sole custodian and NAV authority

**State.** All vault-controlled assets — external-vault shares, the super-token reserve, and (transiently) raw underlying — live in the FM. The vault proxies `totalAssets` / `max*` to FM views.

**Where.** `totalManagedAssets` (`SyncFundManager.sol:176-179`), `maxExternalDeposit` (`SyncFundManager.sol:182-184`); vault delegates `totalAssets` (`StableYieldSyncVault.sol:136-138`), `maxDeposit`/`maxMint` (`StableYieldSyncVault.sol:144-156`), `maxWithdraw`/`maxRedeem` (`StableYieldSyncVault.sol:159-170`).

**Holds when.** Hard, by construction (`EXTERNAL_VAULT` is immutable on the FM; the vault has no external-vault reference of its own).

---

## B. NAV & share accounting

### B.1 — Total assets is the unclamped sum of recoverable balances

**State.**

```
totalAssets() == EXTERNAL_VAULT.maxWithdraw(FM)
              +  scaledYieldAssetsBalance()
              +  underlyingAsset.balanceOf(FM)
```

A plain sum — **no clamp, no `trackedPrincipal`**. The external surplus is included and accrues to holders as share appreciation; under impairment the sum falls and the share takes the loss immediately and honestly.

**Where.** `SyncFundManager.totalManagedAssets` (`SyncFundManager.sol:176-179`); `scaledYieldAssetsBalance` (`FundManagerBase.sol:258-260`). Design Invariant 2.

**Holds when.** Hard, by definition. The meaningful fuzz target is that the sum never reverts (overflow / external-vault view revert) and that the third term is 0 at rest (A.2).

**Breaks if.** A clamp or counter is reintroduced, or `maxWithdraw` of a non-standard external vault reverts / rebases unexpectedly.

### B.2 — No share over-issuance

**State.**

```
convertToAssets(totalSupply()) <= totalManagedAssets()
```

Strictly `<` with the virtual-shares offset. The total claim priced at NAV never exceeds recoverable value.

**Where.** OZ `ERC4626._convertToAssets` against `totalAssets()` (`StableYieldSyncVault.sol:136-138`).

**Holds when.** Hard.

**Breaks if.** Shares are minted without a matching NAV increase (e.g. units/shares granted on a deposit whose principal didn't reach the FM), or NAV is read before the deposit lands.

### B.3 — Deposits are NAV-neutral at entry

**State.** A deposit only changes the *form* of the FM's assets (incoming underlying → external-vault shares + a reserve slice), both counted in NAV. Price-per-share immediately before and after a deposit is unchanged (modulo virtual-shares rounding in the vault's favour).

**Where.** `onDeposit`: units granted (`SyncFundManager.sol:87-91`), pre-fund slice upgraded (`SyncFundManager.sol:97-103`), remainder deployed to external (`SyncFundManager.sol:106-110`). Mint happens in the vault before the hook (`StableYieldSyncVault.sol:187-189`).

**Holds when.** Hard for the entry transition. (Thereafter the share floats — see B.5.)

**Breaks if.** Some incoming underlying is consumed without entering NAV (would dilute), or the pre-fund pulls more than `assets` (capped at `assets`, `SyncFundManager.sol:101`).

### B.4 — Stayers are not diluted by another holder's op

**State.** With external NAV and the reserve held fixed, a deposit or withdraw by user X does not decrease `convertToAssets(balanceOf(Y))` for an untouched holder Y. Deposits are NAV-neutral (B.3); withdraws are floor-priced (`shares · NAV / supply`), so rounding leaves residual value with stayers.

**Where.** OZ proportional accounting; withdraw is priced by `_withdraw` → `previewWithdraw`/`_convertToShares` with floor rounding; `onWithdraw` removes exactly the pro-rata slice (`SyncFundManager.sol:116-167`). This is the property that replaced the old `trackedPrincipal` decrement (design Invariant 1, Revision 2026-05-26).

**Holds when.** Hard, isolating same-block other-user activity from stream drain (D.3) and external performance (B.5).

**Breaks if.** A withdraw removes less NAV than the shares it burns are worth (over-payment to leaver), or a deposit mints more shares than `assets · supply / NAV`.

### B.5 — Share floats with external performance

**State.** Between rebalances and across external NAV changes, price-per-share = `totalManagedAssets() / totalSupply` moves: up by `external yield − promised rate` while the external vault out-earns the rate, down (honest, immediate) under impairment. A holder's total return = streamed promised rate **plus** this appreciation — single-counted (the stream is funded by pulling from external, lowering `maxWithdraw(FM)` by exactly the streamed amount).

**Where.** Design Core principle / Invariant 1. NAV reads live values (`SyncFundManager.sol:176-179`); the rebalance pulls only the *deficit*, leaving surplus compounding externally (`SyncFundManager.sol:204-217`).

**Holds when.** Economic property, not a hard equality — the relevant fuzz check is directional (no clamp pins the price; price tracks external NAV minus streamed drain).

**Breaks if.** A clamp is reintroduced, or the rebalance pulls the full external position rather than the deficit.

### B.6 — Withdrawal pays exactly the priced amount

**State.**

```
fromReserve + fromExternal == redeemingAssets
receiver underlying balance increases by exactly redeemingAssets
```

**Where.** `onWithdraw`: `fromExternal = redeemingAssets − fromYieldAssets` (`SyncFundManager.sol:155`), external leg (`:156-159`), reserve leg transfer (`:160-162`).

**Holds when.** Hard, when the call does not revert. The external leg reverts only if `EXTERNAL_VAULT` is illiquid (accepted, decision 5).

**Breaks if.** `fromYieldAssets` is computed against the wrong sign of the deficit, or `_downgrade` yields less underlying than requested (decimals clipping — guarded elsewhere by the `+1`).

---

## C. Shares & GDA units

### C.1 — Units are granted on deposited principal; transfers move a share-proportional slice

**State.** On deposit a holder's units increase by `_toUnit(assets) = assets / RAW_PER_UNIT` — proportional to **underlying contributed**, not to shares minted. On a shareholder↔shareholder transfer, units move proportional to the *shares* transferred relative to the sender's share balance. On withdraw, units decrease proportional to *shares* burned.

**Where.** Grant: `onDeposit` (`SyncFundManager.sol:87-91`). Transfer: `_update` → `onShareTransfer`, `delta = ceil(senderUnits · shares / vault.balanceOf(sender))` (`StableYieldSyncVault.sol:222-227`, `FundManagerBase.sol:236-244`). Withdraw: proportional decrease `ceil(holderUnits · shares / totalSharesOwned)` (`SyncFundManager.sol:130-138`).

**Holds when.** Hard, per-op (deposit grants exactly `_toUnit(assets)`; transfer moves `ceil(senderUnits · shares / senderShares)`; withdraw decreases `ceil(holderUnits · shares / totalSharesOwned)` — full exit zeros).

**Breaks if.** A deposit grants units off any base other than `_toUnit(assets)`; a transfer/withdraw delta is computed against the wrong sender-side denominator; a unit move escapes `onDeposit` / `onWithdraw` / `onShareTransfer`.

**Resolved-by-design (2026-05-28).** Under the floating share, `units / shares` is **NOT** a global constant — units track nominal contributed principal; shares track NAV. This is intentional and matches the design's total-return decomposition: the streamed component is sized to **nominal principal** (the "stable yield on what you put in" narrative — `_toUnit(assets) = assets / RAW_PER_UNIT` is NAV-independent), while the residual `external − promised` is delivered as share-price appreciation. A secondary-market buyer of appreciated shares inherits the seller's slot's `units / share`, distinct from what a fresh deposit at the same cash would mint — informational, not a value leak. See `docs/sync-vault/design.md` Invariant 6 (restated 2026-05-28) and the `test_prop_units*` suite in `test/vault/sync/StableYieldSyncVault.props.t.sol`. §H.1 retired.

### C.2 — Yield stream starts at deposit and stops proportionally at withdraw

**State.** A depositor accrues stream from deposit time (units granted + `_recalibrateFlow()` in the same call). A full exit removes all the holder's units; a partial exit removes a `shares/totalSharesOwned` slice.

**Where.** Start: `onDeposit` (`SyncFundManager.sol:87-91`, `:112`). Stop: `onWithdraw` (`SyncFundManager.sol:130-138`).

**Holds when.** Hard for the unit moves; the *flow* (re)start is best-effort (guarded `_recalibrateFlow()`, see D.2).

### C.3 — Dust position (shares but zero units) does not brick withdraw

**State.** A sub-`RAW_PER_UNIT` deposit can mint shares but 0 units. `onWithdraw` skips the unit decrease when `holderUnits == 0` rather than reverting.

**Where.** `SyncFundManager.sol:126-138`.

**Holds when.** Hard.

### C.4 — Withdraw argument sanity

**State.** `onWithdraw` reverts `BAD_WITHDRAW_ARGS` if `totalSharesOwned == 0` or `shares > totalSharesOwned`.

**Where.** `SyncFundManager.sol:124`.

**Holds when.** Hard. (The vault burns before the hook, so these reflect pre-burn snapshots passed by the vault — `StableYieldSyncVault.sol:208-213`.)

---

## D. Yield stream & reserve

### D.1 — Forward-solvency horizon (best-effort)

**State.**

```
yieldAssetsBalance() >= _targetFlowRate · guaranteedFlowDuration   (+ fee leg)
```

i.e. `evaluateYieldAssetsDeficit() <= 0` after every user op, **unless** the rebalance was supply-constrained by the external vault.

**Where.** `evaluateYieldAssetsDeficit` (`FundManagerBase.sol:263-273`); replenished by `_rebalanceYieldAssets` `deficit > 0` branch, `pulled = min(need, EXTERNAL_VAULT.maxWithdraw(FM))` (`SyncFundManager.sol:204-217`); pre-funded from the incoming deposit, capped at `assets` (`SyncFundManager.sol:97-103`); operator `ensureYieldFlowDuration()` (`FundManagerBase.sol:185-194`). Design Invariant 5.

**Holds when.** Best-effort. Clean terminal form: after a deposit large enough to cover its own residual, `deficit > 0 ⇒ EXTERNAL_VAULT.maxWithdraw(FM) == 0` (terminal impairment).

**Breaks if.** Nothing structurally enforces it — same trust model as async. Operator must call `ensureYieldFlowDuration()` between periods of user inactivity (no permissionless `harvest()`).

### D.2 — User ops never bricked: terminal external impairment ⇒ full pause

**State.** Under terminal external impairment (`EXTERNAL_VAULT.maxWithdraw(FM) == 0` while the FM holds an external position) the vault is **fully paused** — deposits/mints/withdraws/redeems revert cleanly with `ERC4626ExceededMax*`, never `GDA_INSUFFICIENT_BALANCE`. The Superfluid stream keeps paying existing holders from the reserve until it is naturally liquidated.

**Where.** `StableYieldSyncVault._isExternallyPaused()` forces all four `max*` to `0` when `FUND_MANAGER.maxExternalVaultWithdraw() == 0` and `EXTERNAL_VAULT.balanceOf(FM) > 0` (the position gate excludes the empty-vault bootstrap). Resolution chosen 2026-05-27 over the never-implemented "guarded recalibrate" (Revision 2026-05-22, row θ): there are **no** `_recalibrateFlow()` guards — the user hooks (`onDeposit`/`onWithdraw`) can't run while paused, so the drained-reserve recalibrate-revert is unreachable. Operator setters are allowed to revert under terminal impairment (accepted); `setStableYieldRate(0)` always works (a zero-flow recalibrate is a *close*, needs no GDA buffer). Pinned by `test_terminalImpairment_pausesAllEntrypoints`, `test_terminalImpairment_resumesAfterUnfreeze`, `test_terminalImpairment_operatorCanZeroRate` in `StableYieldSyncVault.t.sol`. See `docs/sync-vault/design.md §Revision 2026-05-27`.

**Holds when.** Hard for user ops (the `max*` gate is deterministic). Operator-call liveness under terminal impairment is best-effort / accepted-to-revert.

### D.3 — Share price ticks down between rebalances as the stream drains the reserve

**State.** `scaledYieldAssetsBalance()` decreases as the GDA flow drains the reserve, so NAV (and price-per-share) decays between rebalances and recovers at each funded rebalance. This is the async forward-priced property made continuously observable.

**Where.** Reserve drained by the live `distributeFlow` (`FundManagerBase._recalibrateFlow`, `:290-296`); replenished per-op and by the operator.

**Holds when.** Expected behaviour, not a violation. Timing/MEV is a known consideration — mitigated by per-op rebalance, virtual shares, rounding in the vault's favour, `nonReentrant`.

### D.4 — Reserve returns to target after withdraw (best-effort, gated on external `maxDeposit`)

**State.** Under normal operation (external vault accepting deposits), after `onWithdraw` the post-payout `_rebalanceYieldAssets()` trims any residual freed excess back into the external vault, so the reserve is at target (not above) and the FM is flat in underlying (A.2). When the external signals deposits closed (`EXTERNAL_VAULT.maxDeposit(FM) < underlyingNeeded`), the trim is **skipped entirely** (Revision 2026-05-28) and the freed excess stays as above-target super-token slack in the reserve until the external accepts deposits again.

**Where.** `SyncFundManager.sol` `_rebalanceYieldAssets` (`deficit < 0` branch with the `maxDeposit` gate); called from `onWithdraw` post-payout. Design Revision 2026-05-22 row η + Revision 2026-05-28; design.md Invariant 5 / Decision 2.

**Holds when.** Best-effort. Drops to "reserve sits above target" while external deposits are closed; idempotent retry on every subsequent `_rebalanceYieldAssets()` call (no accumulation pathology — `deficit < 0` is the steady-state cue, retried until the trim takes). Above-target slack is **safe**: it just funds the stream for longer, doesn't over-issue shares, doesn't transfer value between holders. Inv. 7 / A.2 ("no raw underlying at rest") is preserved hard throughout — the whole branch is skipped rather than down­graded-then-stuck, so we never end up holding raw underlying with nowhere to send it.

**Known limitation.** A non-compliant external vault whose `deposit` reverts despite reporting `maxDeposit > 0` would bypass the pre-check, propagate its revert, and brick the calling op. Pinned by `test_withdraw_brickedByNonCompliantExternal` in `StableYieldSyncVault.t.sol`. Accepted; design.md §Security requires standard, audited ERC-4626 externals.

### D.5 — Flow & fee rate relationships (inherited)

**State.**

```
_targetFlowRate  = _flowRatePerUnit · YIELD_POOL.getTotalUnits()
_flowRatePerUnit = 1e12 · stableYieldRate / (YEAR · BP_DENOMINATOR)
feeFlowRate      = _targetFlowRate · FEE_BPS / BP_DENOMINATOR
```

Treasury retains its 1 fee-pool unit for the FM's lifetime.

**Where.** `_targetFlowRate` (`FundManagerBase.sol:300-302`), `_flowRatePerUnit` set in constructor / `setStableYieldRate` (`FundManagerBase.sol:172`, `:205`), fee leg in `_recalibrateFlow` (`FundManagerBase.sol:294-295`), treasury unit (`FundManagerBase.sol:164`).

**Holds when.** Hard (shared engine; see async D.4).

### D.6 — Duration floor (inherited)

**State.** `guaranteedFlowDuration >= MIN_GUARANTEED_FLOW_DURATION` (= 1 day). Enforced in the base constructor and `setGuaranteedFlowDuration`.

**Where.** `FundManagerBase.sol:174`, `:215`.

**Holds when.** Hard.

---

## E. Scaling & decimals (inherited)

### E.1 — Yield asset wraps the underlying

**State.** `YIELD_ASSET.getUnderlyingToken() == underlyingAsset`; constructor reverts `ASSET_MISMATCH` otherwise.

**Where.** `FundManagerBase.sol:137`.

### E.2 — External vault asset matches underlying

**State.** `EXTERNAL_VAULT.asset() == asset()`; the vault constructor reverts `EXTERNAL_ASSET_MISMATCH` otherwise. Not re-validated in the FM.

**Where.** `StableYieldSyncVault.sol:71`.

### E.3 — Scaling factors

**State.**

```
SCALING_FACTOR = 10 ** (18 − underlyingDecimals)
RAW_PER_UNIT   = 10 ** (underlyingDecimals − 6)
```

`underlyingDecimals ∈ [6, 18]`; constructor reverts `UNSUPPORTED_DECIMALS` outside. The hard-coded `1e12 = SCALING_FACTOR · RAW_PER_UNIT` carries the existing 18-dec `FIXME` over from async.

**Where.** `FundManagerBase.sol:143-146`, `:171-172`.

---

## F. ERC-4626 compliance

### F.1 — Preview functions work synchronously

**State.** `previewDeposit/Mint/Redeem/Withdraw` use the OZ default and do **not** revert (unlike the async vault). They price off live `totalAssets()`.

**Where.** Inherited OZ `ERC4626`; no override in `StableYieldSyncVault`.

**Holds when.** Hard.

### F.2 — `max*` are honest, never-bricking bounds

**State.** `maxDeposit/maxMint` capped by `EXTERNAL_VAULT.maxDeposit(FM)`; `maxWithdraw/maxRedeem` capped by `totalManagedAssets()` (the reserve-inclusive NAV is the global upper bound a redeem can source). A request at exactly `max*` is serviceable.

**Where.** `StableYieldSyncVault.sol:144-170`; `maxExternalDeposit` (`SyncFundManager.sol:182-184`).

**Holds when.** Hard, modulo external-vault liquidity on the external leg (decision 5).

**Breaks if.** External vault reports a `maxWithdraw` larger than it can actually service on `withdraw` (non-standard external vault).

### F.3 — Conversion round-trips favour the vault

**State.** `convertToAssets(convertToShares(a)) <= a` and `convertToShares(convertToAssets(s)) <= s` (OZ rounding).

**Where.** Inherited OZ `ERC4626`.

**Holds when.** Hard.

---

## G. Access control

### G.1 — Value-bearing FM hooks are vault-only

**State.** `onDeposit`, `onWithdraw`, `onShareTransfer` revert for any caller other than the pinned vault (`VAULT_ROLE`, granted to `msg.sender` at FM construction).

**Where.** `onlyRole(VAULT_ROLE)` (`SyncFundManager.sol:86`, `:123`; `FundManagerBase.sol:236`); role grant (`FundManagerBase.sol:151`).

**Holds when.** Hard. These hooks now move principal + reserve (not just units), so the gate is load-bearing.

### G.2 — Operator / admin setters

**State.** `setStableYieldRate` and `ensureYieldFlowDuration` are `FUND_OPERATOR_ROLE`; `setGuaranteedFlowDuration` is `DEFAULT_ADMIN_ROLE`. The sync FM adds **no** extra operator entrypoint (no `harvest()`, no `fundReserve`).

**Where.** `FundManagerBase.sol:185`, `:197`, `:214`.

**Holds when.** Hard.

---

## H. Open tensions / gaps (for audit attention)

These are not settled invariants — they are properties the design claims but the code does not yet robustly enforce, or where the design prose and the floating-share model are in tension. Listed so they are not lost.

1. **Units vs. shares under the floating share — RESOLVED 2026-05-28.** Confirmed intended: units track **nominal contributed principal** (the streamed component is sized to what each holder put in — the "stable yield on what you put in" narrative), not shares. Design Invariant 6 restated; §C.1 promoted to a confirmed invariant with the "no global `units == k · shares`" property captured explicitly. Pinned by `test_prop_unitGrantEqualsToUnitAssets`, `test_prop_unitsTrackPrincipalAcrossPrices`, `test_prop_unitsPerShareNotGlobal`, `test_prop_transferConservesUnits`, `test_prop_withdrawDecreasesUnitsProportional` in `test/vault/sync/StableYieldSyncVault.props.t.sol`. See `docs/sync-vault/open-questions.md` (OQ #3 RESOLVED).

2. **First-deposit inflation mitigation — RESOLVED 2026-05-27.** `StableYieldSyncVault` now overrides `_decimalsOffset()` to return `12` (hardcoded for the 6-dec USDC deployment → `10 ** 12` attack-cost multiplier, 18-dec shares). The classic ERC-4626 first-deposit inflation attack is closed; the pinned `test_firstDepositInflation_victimMintsNonZero` passes. Offset alone — no dead-shares seed, no min-shares-minted guard (the guard was deferred). For a non-6-dec underlying the value must be revisited (the bare `18 − d` normalize form gives `0` protection at 18-dec underlyings; floor it). See `docs/sync-vault/open-questions.md`.

3. **Terminal-impairment recalibrate-brick — RESOLVED 2026-05-27 by a full pause.** The design's guarded-recalibrate (Revision 2026-05-22, row θ) had **never actually landed** — all four callsites called `_recalibrateFlow()` unguarded, so they could revert `GDA_INSUFFICIENT_BALANCE` from a drained, un-refillable reserve under terminal external impairment. Resolved **not** by guarding the recalibrate but by treating terminal impairment as a **full vault pause** (`maxWithdraw(FM) == 0 ⇒ all max* = 0`, see D.2): the user hooks never run while paused, so there is nothing to brick; operator setters may revert (accepted), and `setStableYieldRate(0)` (a flow-close) always works. The GDA-buffer modeling of item 5 below is unrelated and stays separately open.

4. **Donations raise the share price (floating share).** With the clamp gone, a super-token or raw-underlying transfer to the FM raises NAV and the price for existing holders — an irrational gift, not a profitable attack, but worth a characterisation test on both donation paths (design §Security).

5. **Inherited `FIXME`s carry over** from the shared engine: no minimum era duration on `setStableYieldRate` (`FundManagerBase.sol:198`); `evaluateYieldAssetsDeficit` neglects the Superfluid GDA buffer/security deposit (`FundManagerBase.sol:264`), so the literal reserve inequality (D.1) can read false immediately after a successful recalibrate even though the missing amount is locked as protocol buffer rather than lost; the 18-dec underlying assumption (`SCALING_FACTOR` math).
