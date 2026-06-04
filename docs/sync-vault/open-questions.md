# Open Questions

Open questions, things to figure out, and things to fix for the sync vault (`StableYieldSyncVault` + `SyncFundManager`), as of the floating-share model (clamp / `trackedPrincipal` dropped 2026-05-26). Cross-references `docs/sync-vault/design.md` (locked decisions) and `docs/sync-vault/invariants.md` (§H lists the same items in invariant terms).

Each entry is tagged:

- **[FIX]** — a concrete code change is needed (a bug or a missing-but-decided mitigation).
- **[DECIDE]** — a design/policy question to resolve before it can be encoded or tested.
- **[VERIFY]** — believed correct, but needs a property test / characterisation to confirm.

---

## [RESOLVED 2026-05-29] `maxRedeem` / `maxWithdraw` are genuinely never-bricking — fixed by shares-proportional reserve sourcing (R-shares)

**Finding (verified).** The prior `onWithdraw` shipped a pre-payout `_rebalanceYieldAssets()` that physically evicted the redeemer's proportional reserve slice back to the external vault before they could consume it. Under any **loss** state (`EXTERNAL_VAULT.maxWithdraw(FM) > 0` but the external position has lost some principal), redeems within `maxRedeem` then asked the external for the redeemer's full NAV slice, exceeding `ext.maxWithdraw(FM)` and reverting `ERC4626ExceededMaxWithdraw`. F.2 (`request ≤ max* ⇒ never reverts`) was violated against a compliant external — a bug, not a doc limitation. Pinned previously by the RED `test_maxRedeem_neverBricks` in `openQuestions.t.sol`.

**Resolution (Option R-shares).** `onWithdraw` now sources the redeemer's reserve slice **directly and shares-proportionally**:

```
fromReserve = ceil(scaledYieldAssetsBalance() · shares / supplyBeforeBurn)
              (clamped at redeemingAssets)
```

The pre-payout `_rebalanceYieldAssets()` is **removed** (it was the eviction mechanism); the post-payout `_rebalanceYieldAssets()` keeps the same OQ #4 `maxDeposit`-gated trim/refill and cures any deficit/surplus the shares-proportional sourcing leaves (`(f − f_u) · scaledReserve`; best-effort, D.1). `_recalibrateFlow()` moves to the end of the call so the new (lower) flow rate reflects the steady-state reserve balance; flow-rate decreases never need GDA buffer and cannot revert from a drained reserve.

The algebra:

```
f             = sharesBurnt / supplyBeforeBurn   (the redeemer's NAV fraction)
redeemingAssets ≈ f · NAV                        (OZ floor)
fromReserve   ≈ f · scaledReserve                (Ceil; safe rounding direction)
fromExternal  = redeemingAssets − fromReserve
              = f · ext.maxWithdraw + f · raw
              ≤ ext.maxWithdraw(FM)              (raw = 0 at rest by Inv. 7)
```

Decisions taken (loss vs. terminal-impairment terminology adopted):

- **"Partial impairment" terminology dropped.** Going forward: **loss** = `ext.maxWithdraw(FM) > 0` but the external position has lost some principal; **terminal impairment** = `ext.maxWithdraw(FM) == 0` (→ D.2 vault pause). The "partial impairment" label mixed liquidity caps and principal loss and confused the model.
- **Q1-Keep / S2 stance.** F.2's "Hard, modulo non-compliant external" wording stays untouched; the algorithm now actually delivers it end-to-end. Rejected alternatives: Q1-Carve (scoped promise + named known-limit corner — added complexity for no F.2 win) and Q1-Tighten (per-holder cap shrinks under loss — under-promises vs. recoverable NAV).
- **Decision 5 softened.** "Preserves stayers' horizon **by construction**" → "best-effort, via the post-payout rebalance (D.1)". The "by construction" claim was written under the dropped clamp where `units / share` was effectively uniform; under the floating share + locked C.1 (units track principal), drift is the normal state and either Decision 5 or F.2 must give. R-shares picks F.2 (the user-visible API contract); D.1 already names stayers' horizon as best-effort, so the trade is a doc edit, not a regression.
- **`Ceil` rounding on `fromReserve`** is the symmetric safe choice — `previewRedeem` rounds floor in vault's favour, so rounding the reserve slice up keeps `fromExternal ≤ s · ext.maxWithdraw / supply` without the 1-atom residual that pure floor on both legs can leave. `Ceil` still satisfies `fromReserve ≤ scaledReserve` because `shares ≤ supplyBeforeBurn`.

Tests:

- **`test_maxRedeem_neverBricks` is gone** along with `openQuestions.t.sol` (deleted; all OQs resolved).
- **New positive pins in `StableYieldSyncVault.t.sol`** (risk-characterisations section): `test_redeem_serviceableUnderLoss`, `test_withdraw_serviceableUnderLoss`, `test_redeem_atMaxRedeemUnderLoss`. Use `simulateLoss` (loss framing), replacing the prior `setLiquidityCap` framing.
- **New multi-holder property test** in `StableYieldSyncVault.props.t.sol`: `test_prop_F2_neverBricksUnderLoss` — two holders at different entry prices (NAV drifted between deposits), external loss, either holder redeems within `maxRedeem`, payout = `previewRedeem(s)`. 258 runs.
- **Known-limit pin shifted** (paired with a positive characterisation):
  - Positive: `test_withdraw_singleHolderFullExit_notBrickedByNonCompliantExternal` — under R-shares, sole-holder full exits have `f == f_u ⇒ deficit ≈ 0 ⇒ no trim attempt`, so the non-compliant deposit path is never reached. Previously this case bricked.
  - Negative (known limit): `test_withdraw_lateEntrantAfterGain_brickedByNonCompliantExternal` — the trim path is still reachable via multi-holder exits where the holder has higher-than-average `units / share` (`f < f_u ⇒ surplus ⇒ trim ⇒ non-compliant deposit reverts`). Bob (late entrant after gain) is the holder with higher `units / share` because his shares are "expensive" — same units packed into fewer shares. His partial exit triggers the surplus.
- **Temporary repro file** `_oq5Repro.t.sol` deleted.

Doc edits landed: `docs/sync-vault/design.md` (Revision 2026-05-29 block at top; Decision 5 row rewritten; `SyncFundManager.onWithdraw` contract section rewritten; `SyncFundManager` view-helper rationale + `StableYieldVault` `max*` rationale updated to "shares fraction"; withdraw Mermaid diagram rewritten; §Security external-illiquidity bullet restated under loss framing). `docs/sync-vault/invariants.md` (B.6 code references updated; D.1 gains a sentence on the post-payout cure path; F.2 pinning-by line updated to name the new R-shares tests). `CLAUDE.md` `onWithdraw` bullet updated.

## [RESOLVED 2026-05-27] First-deposit inflation mitigation — `_decimalsOffset() = 12`

`StableYieldSyncVault` now overrides `_decimalsOffset()` to return a hardcoded `12`
(`StableYieldSyncVault.sol`), giving a `10 ** 12` attack-cost multiplier and 18-dec shares for
the 6-dec USDC deployment. This closes the classic ERC-4626 first-deposit inflation attack: an
attacker who seeds the empty vault then donates to inflate price-per-share must donate
`~10 ** 12 ×` the victim's deposit and forfeit ~half of it to the (unowned) virtual shares —
economically dead. The pinned characterisation test
`test_firstDepositInflation_victimMintsNonZero` (open-questions suite) now passes.

Decisions taken:

- **Value = 12, hardcoded** (`pure`), not the programmatic `max(6, 18 − underlyingDecimals)`.
  Targets the 6-dec USDC POC deployment; revisit for a non-6-dec underlying. Note the naive
  "normalize to 18 decimals" formula (`offset = 18 − d`) collapses to `0` for an 18-dec
  underlying (e.g. WETH) — i.e. *no* protection — so a future multi-underlying deployment must
  floor it (`max(K, 18 − d)`), not use the bare normalize form.
- **Offset alone; no dead-shares seed, no min-shares-minted guard.** The offset makes the attack
  infeasible on its own; the dead-shares seed was rejected (redundant + complicates the
  constructor, which would have to route real underlying through `onDeposit` at deploy with the
  external vault live). The cheap "mint 0 shares ⇒ revert" guard was considered belt-and-suspenders
  and deferred — reopen if dust handling later warrants it.

The offset is isolated to share ↔ `totalAssets` pricing (applied consistently across
`convert*`/`preview*`/`max*`); it does not touch the GDA units (`_toUnit(assets)`), the
super-token reserve, or `SCALING_FACTOR`. `totalAssets()` is denominated in underlying (6-dec)
atoms — `scaledYieldAssetsBalance()` divides the 18-dec super-token balance back down before it
reaches the share layer — so the 18-dec super-token integration does not interact with the offset.

Mid-life donation characterisation (both paths raise NAV → gift existing holders, not an attack)
remains tracked under the "[DECIDE] Donation characterisation under the floating share" entry below.

## [RESOLVED 2026-05-27] Per-op / setter `_recalibrateFlow()` under terminal impairment — fixed by a full pause (not by guards)

**Finding (verified):** the design's guarded-recalibrate rule (Revision 2026-05-22, row θ) had **never actually landed in code** — all four `_recalibrateFlow()` callsites (`setStableYieldRate`, `ensureYieldFlowDuration`, `onDeposit`, `onWithdraw`) were effectively unguarded. `_recalibrateFlow()` → `distributeFlow(YIELD_POOL, targetFlowRate)` needs the distributor to fund Superfluid's GDA buffer; when the reserve is drained and can't be refilled (terminal external impairment), starting/raising a flow reverts `GDA_INSUFFICIENT_BALANCE`.

**Resolution (chosen over guards):** treat **terminal external impairment as a full pause** at the vault's `max*` layer rather than guarding the recalibrate. Scope and reasoning were worked through deliberately:

- We **discard** the no-liquidator, year-long-insolvency scenario (a Superfluid sentinel keeps the account from sitting deeply insolvent; and in normal operation the operator calls `ensureYieldFlowDuration()` often enough that the reserve never drains). The only in-scope failure is **terminal external impairment**: `EXTERNAL_VAULT.maxWithdraw(FM) == 0`, where the reserve can't be refilled.
- **Policy:** `maxWithdraw(FM) == 0` ⇒ full pause. The vault forces `maxDeposit = maxMint = maxWithdraw = maxRedeem = 0` (`StableYieldSyncVault._isExternallyPaused()`, gated on `totalSupply() > 0` so the empty-vault bootstrap isn't paused — revised 2026-06-04 from the spoofable `EXTERNAL_VAULT.balanceOf(FM) > 0` clause, audit Finding 3 + share-burn lead), and OZ reverts every entrypoint with `ERC4626ExceededMax*`. No deposits (we don't route users into a vault they can't exit); no withdrawals (the surviving reserve is reserved for the stream, not a first-come reserve grab); the stream keeps paying existing holders from the reserve until it is naturally liquidated.
- **No `_recalibrateFlow()` guards anywhere** — `onDeposit`/`onWithdraw` never run while paused, so there is nothing to brick. The operator's bleed-stopping lever `setStableYieldRate(0)` still works unguarded (recalibrating to a **zero** flow is a *close*, which needs no buffer). Other operator calls (`setStableYieldRate(>0)`, `ensureYieldFlowDuration`) are **allowed to revert** under terminal impairment — accepted; the operator is knowledgeable about the state.
- **No permanent-loss exit hatch.** `maxWithdraw(FM) == 0` does not distinguish a temporary freeze from a permanent loss; both pause. If permanent, the remaining reserve simply streams out to holders — accepted (unlikely tail), no impaired-NAV exit is designed.
- The GDA-buffer FIXME (`evaluateYieldAssetsDeficit` :264, "Inherited FIXMEs" item 1 below) is unrelated to this resolution and stays separately open.

Pinned by `test_terminalImpairment_pausesAllEntrypoints`, `test_terminalImpairment_resumesAfterUnfreeze`, `test_terminalImpairment_operatorCanZeroRate` (in `StableYieldSyncVault.t.sol`). See `docs/sync-vault/design.md §Revision 2026-05-27`.

## [RESOLVED 2026-05-28] Units track nominal contributed principal — Invariant 6 restated

**Decision (Option A — current code, intended).** The streamed component of total return is keyed to **nominal contributed principal**, not to current share value. Units are granted on **underlying deposited** (`_toUnit(assets) = assets / RAW_PER_UNIT`, NAV-independent); shares mint on **NAV** (`assets · supply / NAV`). Under the floating share these diverge — `units / shares` is **not** a global constant once NAV departs from `supply · RAW_PER_UNIT`. The narrative is straightforward and matches the async vault's behaviour: *Alice deposits 100 USDC at 5% — she receives 5 USDCx over one year, and if the external vault was earning 10% her shares are worth 105 USDC at exit*. The residual (`external − promised`) is delivered as share-price appreciation. No code change — the current `_toUnit(assets)` grant + share-proportional transfer/withdraw slicing implements this directly.

Secondary-market consequence (accepted, informational): a buyer of appreciated shares inherits the seller's per-slot `units / share`, i.e. a smaller stream-per-dollar-paid than a fresh deposit at the same cash would give. This is **not a value leak** — the seller realises NAV value in cash, the buyer inherits the embedded units slice; an efficient secondary market would discount accordingly. The secondary market is not a core feature of the vault, just a permissionless exit avenue; the wrinkle is documented for off-chain pricing integrators, not encoded on-chain.

The dropped alternative (Option B) — making the stream track current share value — would require continuous GDA-unit rebasing as NAV moves (and would re-absorb the external surplus into the stream, contradicting the floating-share decision of 2026-05-26 that the surplus accrues to holders as share appreciation). Infeasible in GDA's discrete-units model and incoherent with the floating-share product.

Decisions taken:

- **Invariant 6 restated** in `docs/sync-vault/design.md` from *"units proportional to share balance"* (the loose-but-true form under the dropped clamp) to *"units track contributed principal; transfers move a share-proportional slice; the buyer inherits the sender's per-slot `units / share` ratio."*
- **`docs/sync-vault/invariants.md §C.1` promoted** from open tension (§H.1) to a confirmed invariant with the "no global `units == k · shares`" property explicitly captured.
- **`CLAUDE.md` "Shares & roles"** addended to call out the sync-vault unit-grant rule.
- **Pinned by five property tests** in `test/vault/sync/StableYieldSyncVault.props.t.sol` (§C.1 block): `test_prop_unitGrantEqualsToUnitAssets`, `test_prop_unitsTrackPrincipalAcrossPrices`, `test_prop_unitsPerShareNotGlobal`, `test_prop_transferConservesUnits`, `test_prop_withdrawDecreasesUnitsProportional`.

## [RESOLVED 2026-05-28] Withdraw bricked by external rejecting post-payout redeposit — fixed with a best-effort trim (α: maxDeposit pre-check)

**Decision (Option α — maxDeposit pre-check, no try/catch).** `_rebalanceYieldAssets()`'s `deficit < 0` branch now gates the whole trim on `EXTERNAL_VAULT.maxDeposit(FM) >= (uint256(-deficit) / SCALING_FACTOR)`. If the external will accept the redeposit, the trim runs as before (downgrade + redeposit). If it won't, the **whole branch is skipped** — the excess stays as above-target super-token slack in the reserve; the next rebalance retries idempotently. The fix lives inside `_rebalanceYieldAssets()` so every caller benefits (`onDeposit` pre-rebalance, `onWithdraw` pre-rebalance + post-payout trim, `setStableYieldRate`, `ensureYieldFlowDuration`).

Rejected alternatives:

- **β — `try/catch` around `EXTERNAL_VAULT.deposit`**: handles non-compliant externals too, but the failure path leaves raw underlying at rest in the FM (violating Inv. 7 / A.2) and would need a re-upgrade rollback. Over-engineered.
- **γ — α + defensive `try/catch`**: pre-check AND catch — most defensive but redundant given the design already requires standard, audited ERC-4626s (§Security).

Why α won:

- **Inv. 7 / A.2 preserved hard** — skipping the whole branch (rather than downgrading first) means we never end up holding raw underlying with nowhere to send it.
- **Only D.4 weakens** (reserve may sit above target while external deposits are closed) — and the relaxation is safe: above-target slack just funds the stream for longer, doesn't over-issue shares, doesn't transfer value between holders.
- **Trusts ERC-4626 compliance** — consistent with the existing §Security stance ("integrate only standard, audited, non-rebasing 4626s").

Decisions taken:

- **`docs/sync-vault/design.md`** — Decision 2 row reworded ("best-effort, gated on external `maxDeposit`"); `SyncFundManager` contract section's `deficit < 0` bullet rewritten; `onWithdraw` step 6 reworded; new Revision 2026-05-28 section added; Invariant 5 / §Security extended.
- **`docs/sync-vault/invariants.md`** — D.4 rewritten ("best-effort, gated on external `maxDeposit`"); A.2 / Inv. 7 cross-referenced to the new gate; known-limitation note added.
- **`CLAUDE.md`** — sync vault paragraph noted the best-effort trim.
- **Code** — `SyncFundManager._rebalanceYieldAssets()` gained the `EXTERNAL_VAULT.maxDeposit(this) >= underlyingNeeded` pre-check.
- **Tests** —
  - `test_withdraw_notBrickedByRedepositCap` (formerly `test_withdraw_notBrickedByRedepositRevert`) — repinned to use `setDepositCap(0)` (the standard ERC-4626 deposits-closed signal) and **moved out of `openQuestions.t.sol` into `StableYieldSyncVault.t.sol`** (risk-characterisations section, next to the OQ #1 first-deposit-inflation test). Now passes.
  - `test_withdraw_brickedByNonCompliantExternal` — new known-limitation pin: asserts the withdraw *does* brick when the external reverts despite `maxDeposit > 0` (via `setDepositReverts(true)`). Documents the trust boundary.
  - `test_prop_aboveTargetReserveDoesNotBlockWithdraw` — new property test in `StableYieldSyncVault.props.t.sol`: fuzz two withdraws at `setDepositCap(0)` + reopen + operator rebalance; assert exact payouts, no reverts, and `balanceOf(FM)_underlying == 0` throughout (Inv. 7 holds across the slack state).

## [DECIDE] Minimum deposit / dust shares (carried over from async)

The shared `_toUnit` floors underlying into pool units:

```solidity
units = uint128(underlyingAmount / RAW_PER_UNIT);   // RAW_PER_UNIT = 10 ** (underlyingDecimals − 6)
```

For >6-decimal underlyings, a sub-`RAW_PER_UNIT` deposit mints shares but 0 units. `onWithdraw` already tolerates the zero-unit holder (`SyncFundManager.sol:126-138`, skips the unit decrease rather than reverting), so the async `BAD_REDEEM_ARGS` brick does **not** reproduce here. But the holder still owns shares that accrue no stream, and partial deposits claimed in dust pieces can strand units.

Open question:

Same policy question as async: enforce a minimum deposit of `RAW_PER_UNIT`, or explicitly support sub-unit share balances? For 6-dec USDC (`RAW_PER_UNIT == 1`) this is moot; it only bites >6-dec underlyings, which also hit the 18-dec `SCALING_FACTOR` `FIXME` below.

## [RESOLVED 2026-06-02] Donation characterisation under the floating share — deposit-brick DoS surface closed; donations are an irrational gift

**Finding (verified).** With the clamp gone, a super-token transfer to the FM raises `totalManagedAssets()` and thus the share price for **existing** holders. The donor strictly loses and mints no shares — so the **value-flow direction** was always "donor → holders" (an irrational gift), confirming the doc-level characterisation.

**But the previous implementation also opened a deposit-bricking DoS surface.** Pre-fix, `_rebalanceYieldAssets()` `deficit < 0` branch read `UNDERLYING_ASSET.balanceOf(this)` and redeposited the **whole** balance — which during `onDeposit` includes the user's just-arrived `assets`. After the trim ran, the FM was empty, and the explicit `EXTERNAL_VAULT.deposit(toExternal, …)` later in `onDeposit` reverted with `ERC20InsufficientBalance(FM, 0, assets)`. An attacker could trigger this by donating any non-trivial amount of super-token to the FM (donor loses the donation amount, but **every subsequent `deposit`/`mint` reverts** until the operator un-bricks via `ensureYieldFlowDuration()` — which an attacker can immediately re-brick). Low-cost persistent DoS. A non-malicious trigger also existed: operator drops the rate while `EXTERNAL_VAULT.maxDeposit(FM) == 0` (the 2026-05-28 best-effort gate skips the trim, leaving the reserve above the new target); when external reopens, the next deposit bricks on the now-reachable trim path.

**Resolution.** `SyncFundManager._rebalanceYieldAssets()` `deficit < 0` branch redeposits **exactly** `underlyingNeeded` (the converted excess) instead of sweeping `balanceOf(FM)`:

```solidity
} else if (deficit < 0) {
    uint256 excessYield = uint256(-deficit);
    uint256 underlyingNeeded = excessYield / SCALING_FACTOR;
    if (underlyingNeeded == 0) return;                               // sub-SF surplus → no-op
    if (EXTERNAL_VAULT.maxDeposit(address(this)) >= underlyingNeeded) {
        _downgrade(underlyingNeeded * SCALING_FACTOR);
        UNDERLYING_ASSET.forceApprove(address(EXTERNAL_VAULT), underlyingNeeded);
        EXTERNAL_VAULT.deposit(underlyingNeeded, address(this));
    }
}
```

Blast radius: zero behaviour change at any other callsite. The three operator setters (`setStableYieldRate`, `ensureYieldFlowDuration`, `setGuaranteedFlowDuration`) and the post-payout call in `onWithdraw` all run with FM raw = 0 by Inv. 7 / A.2 (`onWithdraw` does its reserve-slice `safeTransfer` to the receiver before the rebalance), so `balanceOf(FM) == underlyingNeeded` there and the new code is observationally identical. The only call site whose behaviour changes is the one where the bug fires — `onDeposit`'s top-of-hook rebalance. Inv. 7 hardens from "no raw underlying at rest **between calls**" to additionally "the rebalance trim does not consume in-flight raw underlying **within a call**." D.4 is unaffected (same gate, same downgrade amount). Sub-`SCALING_FACTOR` surplus now early-returns rather than calling `EXTERNAL_VAULT.deposit(0, …)` — minor gas saving and avoids 4626s that revert on a zero deposit.

Decisions taken:

- **Exact redeposit, not balance sweep.** Reads `balanceOf(FM)` were the bug's mechanism; the exact form is correct at every caller because the downgrade and the redeposit are now a tight matched pair.
- **Early return for `underlyingNeeded == 0`.** The prior code reached `EXTERNAL_VAULT.deposit(0, …)` on sub-SF surplus — a tax for no work and a soft-revert risk on stricter 4626s.
- **Inv. 7 wording kept verbatim.** "Or the base rebalance silently consumes it" remains as a defensive warning for future in-flight-raw code paths; the active vulnerability is closed but the discipline still matters.

Tests:

- `test_donation_superTokenToFM_accruesToHolders` (unchanged, `StableYieldSyncVault.t.sol`) — NAV rises for existing holders after donation; positive value-flow characterisation.
- `test_deposit_notBrickedAfterSuperTokenDonation` (new, `StableYieldSyncVault.t.sol`) — donation → follow-up `deposit(BOB, …)` succeeds + FM holds 0 raw + Bob's units == `_toUnit(assets)`.
- `test_deposit_notBrickedAfterRateDropWithClosedExternal` (new, `StableYieldSyncVault.t.sol`) — natural-trigger variant: rate drop while external capped → external reopens → deposit succeeds.

Both new tests fail pre-fix with `ERC20InsufficientBalance(FM, 0, depositAmount)` from the external's `transferFrom` against the swept FM — exactly characterising the bug.

Doc edits landed: `docs/sync-vault/design.md` (Revision 2026-06-02 block at top; `SyncFundManager._rebalanceYieldAssets` contract section's `deficit < 0` bullet rewritten; §Security donation bullet updated to call out the closed DoS surface). `docs/sync-vault/invariants.md` (A.2 / Inv. 7 updated to note the within-call hardening + new pinning tests; §H.4 moved from open tension to RESOLVED). `CLAUDE.md` sync vault paragraph updated.

Pairs with the first-deposit inflation mitigation (`_decimalsOffset() = 12`) — the empty-vault inflation surface remains the only structural donation-adjacent concern, and it's already mitigated.

## [FIX] Inherited `FIXME`s from the shared engine

These live in `FundManagerBase` and apply to both families; they carry into the sync vault unchanged.

1. **GDA buffer not in the reserve target.** `evaluateYieldAssetsDeficit()` (`FundManagerBase.sol:264`, `FIXME: add buffer to the required balance`) sizes the reserve at the bare `_targetFlowRate · guaranteedFlowDuration` and ignores Superfluid's GDA security deposit. The literal reserve inequality (invariants D.1) can therefore read false immediately after a successful `_recalibrateFlow()` even though the missing amount is locked as protocol buffer, not lost. Independent of the terminal-impairment pause (resolved above) — this only affects the *cosmetic accuracy* of the D.1 inequality reading, not liveness. Decide whether to add the buffer to the required-balance side.

2. **No minimum era duration on `setStableYieldRate`.** `FundManagerBase.sol:198` (`FIXME: enforce minimum era duration`) — the operator can flip the rate every block. Same open question as async: fixed era boundaries vs. fully discretionary real-time adjustment.

3. **18-dec underlying assumption.** `SCALING_FACTOR = 10 ** (18 − d)` and the hard-coded `1e12 = SCALING_FACTOR · RAW_PER_UNIT` assume `d < 18`; the existing `FIXME`s in `FundManagerBase` carry over. Supported range is `[6, 18]` but the 18-dec edge needs the same scrutiny noted in the async docs.

## [DECIDE] Operator liveness — no permissionless backstop

The sync vault dropped `harvest()` (Revision 2026-05-22): the only reserve-poking entrypoint between user activity is the operator-gated `ensureYieldFlowDuration()`. Per-op hooks keep the stream solvent on any user activity, but during a quiet period with no deposits/withdrawals the operator must call `ensureYieldFlowDuration()` to keep the stream forward-solvent and the share-price drift bounded.

Open question:

Is the loss of a permissionless liveness backstop acceptable for launch, or do we want a thin permissionless wrapper around `_rebalanceYieldAssets()` (the documented natural extension point) so keepers can poke without the operator role? This is a deliberate trust/surface tradeoff, currently resolved in favour of the smaller surface.
