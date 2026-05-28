# Open Questions

Open questions, things to figure out, and things to fix for the sync vault (`StableYieldSyncVault` + `SyncFundManager`), as of the floating-share model (clamp / `trackedPrincipal` dropped 2026-05-26). Cross-references `docs/sync-vault/design.md` (locked decisions) and `docs/sync-vault/invariants.md` (§H lists the same items in invariant terms).

Each entry is tagged:

- **[FIX]** — a concrete code change is needed (a bug or a missing-but-decided mitigation).
- **[DECIDE]** — a design/policy question to resolve before it can be encoded or tested.
- **[VERIFY]** — believed correct, but needs a property test / characterisation to confirm.

---

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
- **Policy:** `maxWithdraw(FM) == 0` ⇒ full pause. The vault forces `maxDeposit = maxMint = maxWithdraw = maxRedeem = 0` (`StableYieldSyncVault._isExternallyPaused()`, gated on the FM actually holding an external position so the empty-vault bootstrap isn't paused), and OZ reverts every entrypoint with `ERC4626ExceededMax*`. No deposits (we don't route users into a vault they can't exit); no withdrawals (the surviving reserve is reserved for the stream, not a first-come reserve grab); the stream keeps paying existing holders from the reserve until it is naturally liquidated.
- **No `_recalibrateFlow()` guards anywhere** — `onDeposit`/`onWithdraw` never run while paused, so there is nothing to brick. The operator's bleed-stopping lever `setStableYieldRate(0)` still works unguarded (recalibrating to a **zero** flow is a *close*, which needs no buffer). Other operator calls (`setStableYieldRate(>0)`, `ensureYieldFlowDuration`) are **allowed to revert** under terminal impairment — accepted; the operator is knowledgeable about the state.
- **No permanent-loss exit hatch.** `maxWithdraw(FM) == 0` does not distinguish a temporary freeze from a permanent loss; both pause. If permanent, the remaining reserve simply streams out to holders — accepted (unlikely tail), no impaired-NAV exit is designed.
- The GDA-buffer FIXME (`evaluateYieldAssetsDeficit` :264, "Inherited FIXMEs" item 1 below) is unrelated to this resolution and stays separately open.

Pinned by `test_terminalImpairment_pausesAllEntrypoints`, `test_terminalImpairment_resumesAfterUnfreeze`, `test_terminalImpairment_operatorCanZeroRate` (in `StableYieldSyncVault.t.sol`). See `docs/sync-vault/design.md §Revision 2026-05-27`.

## [DECIDE] Units track nominal principal, not shares — restate Invariant 6

Design Invariant 6 reads "a holder's GDA units are proportional to their share balance." Under the **floating** share this is not a global equality. Units are granted on **underlying deposited**:

```solidity
// SyncFundManager.onDeposit
YIELD_POOL.increaseMemberUnits(receiver, _toUnit(assets));   // assets / RAW_PER_UNIT
```

while shares mint on **NAV** (`assets · supply / NAV`). Once the share has appreciated, equal deposits buy fewer shares but the same units, so `units / shares` differs across holders — and even across one holder's successive deposits at different prices. On transfer the slice moves proportional to *shares* (`onShareTransfer`), so the relationship is self-consistent within a holder's transfers but there is no global `units == k · shares`.

This is most likely intended: the stream pays the promised `stableYieldRate` on **nominal contributed principal**, and the excess (`external − promised`) is delivered as share appreciation — the two-part return the design describes. But it means the stream a holder receives is keyed to what they *deposited*, not to what their shares are currently *worth*.

Open question:

Confirm the intended yield base. If "stream on nominal deposited principal" is intended (current code), restate Invariant 6 as *"units track contributed principal; transfers move a share-proportional slice"* and document the consequence (a holder who bought appreciated shares on the secondary market gets a smaller stream per share than an early depositor). If instead the stream should track current share value, the unit-grant math needs to change. Resolve before encoding any units↔shares property test.

## [VERIFY] Withdraw can be bricked by the external vault rejecting the post-payout redeposit

`onWithdraw` ends with a post-payout trim that redeposits any residual freed reserve excess back into the external vault:

```solidity
// SyncFundManager.onWithdraw — final line
_rebalanceYieldAssets();   // deficit < 0 branch: _downgrade + EXTERNAL_VAULT.deposit(...)
```

If the external vault is paused-for-deposits (or its `maxDeposit(FM) == 0`) while still allowing withdrawals, this `EXTERNAL_VAULT.deposit` call could revert and brick an otherwise-valid withdrawal. The accepted illiquidity case (decision 5) only covers the external *withdraw* leg; the redeposit leg is a separate, less-obvious revert surface.

Open question:

Should the post-payout trim's redeposit be best-effort (skip if the external vault won't accept it, leaving the excess in the reserve as transient slack — at the cost of violating "no slack at rest", D.4), or is bricking acceptable here? Characterise with a mock external vault whose `deposit` reverts but `withdraw` succeeds.

## [VERIFY] `maxRedeem` / `maxWithdraw` are genuinely never-bricking

The vault caps `maxWithdraw`/`maxRedeem` by `totalManagedAssets()` (the reserve-inclusive NAV) on the claim that NAV is the global upper bound on what a redeem can source, because the recalibration-freed reserve excess scales with the redeemer's unit share. The actual `onWithdraw` sources `redeemingAssets` from `fromReserve` (freed excess) + `fromExternal` (`EXTERNAL_VAULT.withdraw`).

The freed-excess slice depends on the *recalibrate* freeing exactly enough buffer for the redeemer's removed units. The claim that `request ≤ max* ⇒ never reverts` couples three moving parts (NAV, freed-excess sizing, external liquidity) and is worth proving rather than assuming.

Open question:

Property test: for any holder and any `shares ≤ maxRedeem(holder)`, `redeem` succeeds and pays `previewRedeem(shares)`; likewise `withdraw ≤ maxWithdraw`. Include the impaired-external case where `totalManagedAssets()` is the binding cap.

## [DECIDE] Minimum deposit / dust shares (carried over from async)

The shared `_toUnit` floors underlying into pool units:

```solidity
units = uint128(underlyingAmount / RAW_PER_UNIT);   // RAW_PER_UNIT = 10 ** (underlyingDecimals − 6)
```

For >6-decimal underlyings, a sub-`RAW_PER_UNIT` deposit mints shares but 0 units. `onWithdraw` already tolerates the zero-unit holder (`SyncFundManager.sol:126-138`, skips the unit decrease rather than reverting), so the async `BAD_REDEEM_ARGS` brick does **not** reproduce here. But the holder still owns shares that accrue no stream, and partial deposits claimed in dust pieces can strand units.

Open question:

Same policy question as async: enforce a minimum deposit of `RAW_PER_UNIT`, or explicitly support sub-unit share balances? For 6-dec USDC (`RAW_PER_UNIT == 1`) this is moot; it only bites >6-dec underlyings, which also hit the 18-dec `SCALING_FACTOR` `FIXME` below.

## [DECIDE] Donation characterisation under the floating share

With the clamp gone, a super-token or raw-underlying transfer directly to the FM raises `totalManagedAssets()` and thus the share price — for **existing** holders. This is an irrational gift (the donor strictly loses), not a profitable attack, *except* in the empty-vault first-deposit case (the [FIX] above).

Open question:

Confirm via tests that a mid-life donation only ever benefits existing holders (no value extraction by the donor or by a same-block sandwich), and document it as accepted behaviour rather than a vulnerability. Pairs with the first-deposit mitigation decision.

## [FIX] Inherited `FIXME`s from the shared engine

These live in `FundManagerBase` and apply to both families; they carry into the sync vault unchanged.

1. **GDA buffer not in the reserve target.** `evaluateYieldAssetsDeficit()` (`FundManagerBase.sol:264`, `FIXME: add buffer to the required balance`) sizes the reserve at the bare `_targetFlowRate · guaranteedFlowDuration` and ignores Superfluid's GDA security deposit. The literal reserve inequality (invariants D.1) can therefore read false immediately after a successful `_recalibrateFlow()` even though the missing amount is locked as protocol buffer, not lost. Independent of the terminal-impairment pause (resolved above) — this only affects the *cosmetic accuracy* of the D.1 inequality reading, not liveness. Decide whether to add the buffer to the required-balance side.

2. **No minimum era duration on `setStableYieldRate`.** `FundManagerBase.sol:198` (`FIXME: enforce minimum era duration`) — the operator can flip the rate every block. Same open question as async: fixed era boundaries vs. fully discretionary real-time adjustment.

3. **18-dec underlying assumption.** `SCALING_FACTOR = 10 ** (18 − d)` and the hard-coded `1e12 = SCALING_FACTOR · RAW_PER_UNIT` assume `d < 18`; the existing `FIXME`s in `FundManagerBase` carry over. Supported range is `[6, 18]` but the 18-dec edge needs the same scrutiny noted in the async docs.

## [DECIDE] Operator liveness — no permissionless backstop

The sync vault dropped `harvest()` (Revision 2026-05-22): the only reserve-poking entrypoint between user activity is the operator-gated `ensureYieldFlowDuration()`. Per-op hooks keep the stream solvent on any user activity, but during a quiet period with no deposits/withdrawals the operator must call `ensureYieldFlowDuration()` to keep the stream forward-solvent and the share-price drift bounded.

Open question:

Is the loss of a permissionless liveness backstop acceptable for launch, or do we want a thin permissionless wrapper around `_rebalanceYieldAssets()` (the documented natural extension point) so keepers can poke without the operator role? This is a deliberate trust/surface tradeoff, currently resolved in favour of the smaller surface.
