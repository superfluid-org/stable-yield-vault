# Investor Withdraw / Redeem Flow (Synchronous)

> **Revised 2026-05-19 (async-symmetric pivot; netting locked 2026-05-19);
> revised 2026-05-26 (NAV clamp dropped — floating share).** The FundManager is
> the sole custodian and does the payout. Redemption returns the
> **reserve-inclusive NAV pro-rata** (`shares · NAV / supply`, NAV the unclamped
> plain sum). The reserve slice is NOT an NAV-pro-rata downgrade — it is the
> **recalibration-freed reserve excess**: decreasing the redeemer's units lowers
> the required reserve, and only that freed excess (capped at the payout) is
> downgraded, so remaining holders' stream horizon is preserved by construction.
> The external vault funds the remainder. There is **no `trackedPrincipal`
> decrement** — OZ proportional accounting keeps stayers whole. See
> `docs/sync-vault/design.md` (decisions 5/11, Revision 2026-05-26).

## Contracts involved

| Contract | Role |
|---|---|
| **StableYieldVault** | ERC-4626 face. Spends allowance, burns shares, delegates the payout to the FM. Holds **no** assets |
| **SyncFundManager** | Sole custodian. Best-effort pre-rebalance, proportional unit decrease, funds the payout (freed-reserve-excess leg + external remainder), recalibrates the (lower) flow, post-payout trim. No principal counter |
| **External ERC-4626** | Services the external remainder in underlying. Reverts only if illiquid (accepted, decision 5) |
| **GDA Pool** | Superfluid pool; the holder's stream stops/shrinks proportionally |

## Asset states

| State | Location | Description |
|---|---|---|
| PRINCIPAL | External ERC-4626 (held by **FM**) | Recoverable via `EXTERNAL_VAULT.maxWithdraw(FM)`; the redeemer's pro-rata slice exits with them (no principal counter) |
| YIELD-ASSET RESERVE | FundManager (super-token) | The recalibration-*freed* excess (after the unit decrease) is downgraded to fund the redeemer's reserve slice |
| EXTERNAL SURPLUS | External ERC-4626 (held by **FM**) | Compounding surplus, counted in NAV (accrues to holders); the pre-rebalance replenishes the reserve deficit from it (best-effort, start of the call) |
| ASSETS | Receiver wallet | Underlying delivered: freed-reserve-excess leg (from downgrade) + external remainder |

## Sequence diagram

```mermaid
sequenceDiagram
    participant U as User
    participant V as StableYieldVault
    participant FM as SyncFundManager
    participant E as External ERC-4626
    participant POOL as GDA Pool

    U->>V: withdraw(assets, receiver, owner)
    Note right of V: nonReentrant — max* from FUND_MANAGER.totalManagedAssets()
    opt caller != owner
        V->>V: spendAllowance(owner, caller, shares)
    end
    V->>V: read totalSharesOwned and supplyBeforeBurn (before burn)
    V->>V: burn(owner, shares)
    V->>FM: onWithdraw(owner, shares, totalSharesOwned, supplyBeforeBurn, receiver, assets)
    FM->>FM: rebalanceYieldAssets [no-op when solvent]
    FM->>POOL: decreaseMemberUnits (proportional)
    FM->>POOL: guarded recalibrateFlow
    Note right of POOL: distributeFlow refunds GDA deposit-buffer slice into reserve (becomes freed excess)
    FM->>FM: fromReserve = min(freedExcess, assets)
    FM->>FM: downgrade(fromReserve * SCALING_FACTOR)
    FM->>E: withdraw(assets - fromReserve, receiver, FM)
    FM->>U: safeTransfer(receiver, fromReserve) [reserve leg]
    FM->>FM: rebalanceYieldAssets [post-payout trim: residual freed excess back to external]
    Note over E: external remainder reverts only if the external vault is illiquid (accepted)
```

## Flow

```
(1) User → Vault: withdraw(assets, receiver, owner)   [or redeem(shares, …)]
    - nonReentrant
    - OZ ERC-4626 checks:
        withdraw: assets <= maxWithdraw(owner)
                  = min(convertToAssets(balanceOf(owner)),
                        FUND_MANAGER.totalManagedAssets())
        redeem:   shares <= maxRedeem(owner)
                  = min(balanceOf(owner),
                        convertToShares(FUND_MANAGER.totalManagedAssets()))
      totalManagedAssets() = EXTERNAL_VAULT.maxWithdraw(FM) + scaledReserve
                                                            + rawUnderlying
      — the reserve-inclusive plain sum (no clamp) is the global upper bound on
      what a redeem can source: the recalibration-freed reserve excess scales
      with the redeemer's unit share, and the external remainder is covered by
      the external position; under impairment the lower recoverable NAV shrinks
      this. A larger request reverts up-front with
      ERC4626ExceededMaxWithdraw / ERC4626ExceededMaxRedeem.
    - withdraw: shares = previewWithdraw(assets) = _convertToShares(assets, Ceil)
      redeem:   assets = previewRedeem(shares)   = _convertToAssets(shares, Floor)
      `assets` is the redeemer's pro-rata slice of the RESERVE-INCLUSIVE NAV
      (= EXTERNAL_VAULT.maxWithdraw(FM) + scaledReserve + rawUnderlying), priced
      at the current (floating) share value.

(2) Vault._withdraw(caller, receiver, owner, assets, shares)   — CEI ordering:
    a. if caller != owner: _spendAllowance(owner, caller, shares)
    b. totalSharesOwned = balanceOf(owner)            (read BEFORE the burn)
       supplyBeforeBurn  = totalSupply()              (read BEFORE the burn)
    c. _burn(owner, shares)                            — `_update` skips the
       onShareTransfer hook for the burn leg (to == address(0))
    d. FUND_MANAGER.onWithdraw(owner, shares, totalSharesOwned,
                               supplyBeforeBurn, receiver, assets)        (3)
       (vault internal state is fully updated before the FM's external
        interaction; `nonReentrant` backstops the external calls)
    e. emit Withdraw(caller, receiver, owner, assets, shares)

(3) FundManager.onWithdraw(holder, shares, totalSharesOwned,
                           supplyBeforeBurn, receiver, redeemingAssets)
    (onlyRole VAULT_ROLE) — the async settleEpoch-netting analog:
    - reverts BAD_WITHDRAW_ARGS if totalSharesOwned == 0 or
      shares > totalSharesOwned
    - PRE-REBALANCE (best-effort, deficit-gated):
        _rebalanceYieldAssets()
        — no external calls when evaluateYieldAssetsDeficit() == 0 (the common
          pre-withdraw case). Opportunistically cures a *pre-existing* deficit
          (external underperformed since the last rebalance) from the external
          surplus (then deeper into the external position under impairment);
          capped at EXTERNAL_VAULT.maxWithdraw(FM) so it can never brick the exit.
    - UNIT DECREASE:
        holderUnits = POOL.getUnits(holder)
        if holderUnits > 0:
          delta = (shares == totalSharesOwned)
                ? holderUnits
                : holderUnits.mulDiv(shares, totalSharesOwned, Ceil)
          POOL.decreaseMemberUnits(holder, delta)
        (a dust position can hold shares but 0 units → nothing to decrement,
         skipped rather than reverted so the withdrawal is never bricked)
    - guarded _recalibrateFlow() **BEFORE the freed-excess step**
        if POOL.getTotalFlowRate() != 0 || evaluateYieldAssetsDeficit() <= 0
        — `distributeFlow(newFlowRate)` REFUNDS the GDA "deposit buffer" slice
          attributable to the removed units back into yieldAssetsBalance(), so
          it becomes part of the redeemer's freed excess. A stalled +
          still-under-funded vault is left stalled (the next operator-called
          `ensureYieldFlowDuration()` restarts it); the withdrawal still
          completes.
    - RESERVE LEG (the recalibration-freed excess):
        d = evaluateYieldAssetsDeficit()   (post-recalibrate)
        excessUnderlying = d < 0 ? uint256(-d) / SCALING_FACTOR : 0
        fromReserve = min(excessUnderlying, redeemingAssets)
        if fromReserve > 0: _downgrade(fromReserve · SCALING_FACTOR)
        — `fromReserve ≤ freedExcess`, so the post-withdraw reserve still
          satisfies the reduced unit count's horizon: STAYERS' STREAM IS
          PRESERVED BY CONSTRUCTION (no stall in the healthy case).
    - EXTERNAL REMAINDER:
        fromExternal = redeemingAssets − fromReserve
        if fromExternal > 0:
          EXTERNAL_VAULT.withdraw(fromExternal, receiver, FM)
            — reverts only if the external vault is illiquid (accepted, dec. 5)
        if fromReserve > 0:
          UNDERLYING_ASSET.safeTransfer(receiver, fromReserve)
        → receiver has exactly redeemingAssets; the FM holds 0 underlying.
    - POST-PAYOUT REBALANCE (trim residual freed excess back to external):
        _rebalanceYieldAssets()
        — if freedExcess > redeemingAssets, the residual freed excess remains
          as `deficit < 0` after the payout. The rebalance trim branch
          downgrades it and redeposits the underlying into the external vault,
          so the reserve returns to target. Inv. 7 holds (no raw underlying at
          rest in the FM).
    - NO PRINCIPAL-COUNTER STEP. `redeemingAssets = shares · NAV / supply`
      (OZ previewRedeem, floor), so the burn removed exactly the redeemer's
      pro-rata slice of NAV; the share price is unchanged for stayers (floor
      rounding favours them). The old proportional `trackedPrincipal` decrement
      is no longer needed.
```

## Why the freed-excess leg (not an NAV-pro-rata downgrade)

Tying the reserve draw to the recalibration-*freed* excess (rather than to a
computed reserve fraction of NAV) is what makes the stayers' horizon hold **by
construction**: after the unit decrease the required reserve is
`totalFlowRate(U−Δ) · guaranteedFlowDuration`; only the amount the reserve now
exceeds *that* is downgraded for the redeemer, so the post-withdraw reserve is
still ≥ the (now lower) requirement. The freed excess ≈ the redeemer's pro-rata
reserve slice when the reserve sat at target; if it was over-funded, the extra
sourcing from reserve vs. external is value-neutral for stayers (total payout is
`redeemingAssets` either way) while still respecting the horizon.

## Impairment (loss pass-through)

When the external position is impaired (its recoverable value
`EXTERNAL_VAULT.maxWithdraw(FM)` falls below the deposited principal):

- NAV (`totalManagedAssets()`, the unclamped sum) falls, so `previewRedeem`
  prices the share **below the entry price** and the exiting holder takes the
  pro-rata impaired payout — honest, immediate pass-through. There is no
  accumulated buffer to delay it (the external surplus that would have cushioned
  it was already booked into the share price as appreciation while external was
  out-earning the rate).
- The burn removes exactly `redeemingAssets = shares · NAV / supply` (floor),
  so the share price is unchanged for remaining holders — **no value transfers
  between leavers and stayers**, guaranteed by OZ proportional accounting rather
  than a principal-counter decrement. Floor rounding favours the vault /
  remaining holders.
- The **reserve leg is unaffected by external impairment** (it is freed/downgraded
  super-token, not external-vault shares); only the external remainder carries
  the external loss. This matches async, where the FM downgrades reserve to
  cover redeeming assets at settlement.

## ERC-4626 compliance

- `withdraw` / `redeem` are synchronous; `previewWithdraw` / `previewRedeem`
  do not revert (OZ defaults).
- `maxWithdraw` / `maxRedeem` reflect serviceability via
  `totalManagedAssets()` (the reserve-inclusive unclamped NAV — 4626-honest
  under external impairment via the lower recoverable NAV; never bricks a
  request ≤ max*).
- Allowance is spent on the owner when `caller != owner` (standard ERC-4626).

## Key invariants

1. **Share accounting (OZ-standard, no principal counter).** The redeemer is
   paid `redeemingAssets = shares · NAV / supply` (floor); there is no
   `trackedPrincipal` decrement.
2. **No inter-holder value transfer on exit.** Because the payout is exactly the
   burned shares' pro-rata of NAV, the share price (`NAV / supply`) is unchanged
   for stayers — floor rounding favours them. (This is the property the old
   proportional `trackedPrincipal` decrement enforced manually; OZ accounting
   now gives it for free.)
3. **Stayers' horizon preserved by construction.** Only the recalibration-freed
   reserve excess is downgraded (`fromReserve ≤ freedExcess`), so whenever
   `evaluateYieldAssetsDeficit() ≤ 0` held before the withdraw it still holds
   after for the reduced unit count.
4. **Reserve-inclusive payout.** The redeemer receives their pro-rata of the
   reserve-inclusive NAV: freed-reserve-excess leg + external remainder. The
   external-illiquidity revert applies to the remainder only.
5. **No vault custody.** The vault never holds or fronts assets; the FM moves
   everything and holds 0 underlying at rest (custody hazard invariant — Inv. 7
   in `design.md`).
