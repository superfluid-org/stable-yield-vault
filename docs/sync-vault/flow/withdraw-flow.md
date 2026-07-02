# Withdraw / Redeem Flow

How a withdraw (or redeem) moves through the system. Like deposit, it is a single
synchronous transaction. See [`../design.md`](../design.md) for the model and
[`../invariants.md`](../invariants.md) for the properties.

The redeemer is paid their pro-rata of the **reserve-inclusive NAV**
(`shares · NAV / supply`, floor). The payout is sourced from any resting raw underlying,
then a shares-proportional slice of the reserve, then the external vault.

## Contracts involved

| Contract | Role |
|---|---|
| **StableYieldSyncVault** | ERC-4626 face. Spends allowance, burns shares, delegates the payout to the FM. Holds no assets |
| **SyncFundManager** | Sole custodian. Decreases the holder's units, funds the payout, rebalances, recalibrates. No principal counter |
| **External ERC-4626** | Morpho Vault V2; funds the external remainder in underlying (pulled FM-first). Reverts if its instant liquidity (idle + liquidity adapter) cannot cover the leg — Morpho exposes no liquidity view |
| **GDA Pool** | Superfluid pool; the holder's stream stops or shrinks proportionally |

## Asset locations

| Location | What lives there |
|---|---|
| External vault (held by FM) | Valued via `EXTERNAL_VAULT.previewRedeem(balanceOf(FM))`; the redeemer's pro-rata slice exits with them |
| Reserve (FM, super-token) | A shares-proportional slice is downgraded to fund the reserve leg of the payout |
| Receiver wallet | The delivered underlying: donation slice + reserve slice + external remainder |

## Sequence

```mermaid
sequenceDiagram
    participant U as User
    participant V as StableYieldSyncVault
    participant FM as SyncFundManager
    participant E as External ERC-4626
    participant POOL as GDA Pool

    U->>V: withdraw(assets, receiver, owner)
    Note right of V: nonReentrant — max* from FUND_MANAGER.totalManagedAssets()
    opt caller != owner
        V->>V: spendAllowance(owner, caller, shares)
    end
    V->>V: read totalSharesOwned and supplyBeforeBurn (before burn)
    V->>V: _burn(owner, shares)
    V->>FM: onWithdraw(owner, shares, totalSharesOwned, supplyBeforeBurn, receiver, assets)
    FM->>POOL: decreaseMemberUnits (proportional to shares burned)
    FM->>FM: fromReserve = ceil(scaledReserve · shares / supplyBeforeBurn), clamp at assets
    FM->>FM: _downgrade(fromReserve · SCALING_FACTOR)
    FM->>E: withdraw(external remainder, FM, FM)  %% FM-first: only the FM clears receiveAssetsGate
    FM->>U: safeTransfer(receiver, redeemingAssets)  %% all three legs in one transfer
    FM->>FM: _rebalanceYieldAssets()  %% restore the reserve to target for the reduced unit count
    FM->>POOL: _recalibrateFlow()  %% lower flow rate releases GDA buffer; never reverts
```

## Step by step

1. **Vault entry.** `withdraw(assets, receiver, owner)` (or `redeem(shares, …)`).
   `nonReentrant`. OZ checks the request against `max*`:
   - `maxWithdraw(owner) = min(convertToAssets(balanceOf(owner)), totalManagedAssets())`
   - `maxRedeem(owner) = min(balanceOf(owner), convertToShares(totalManagedAssets()))`

   Both are `0` under the external pause (terminal impairment or blocked exit gates).
   `totalManagedAssets()` (the reserve-inclusive NAV) is the global upper bound on what a
   redeem can source; a larger request reverts up-front with `ERC4626ExceededMax*`.
   `assets` is priced at the current floating share value. Note the NAV cap is the
   external position's *value*, not Morpho's instant liquidity (no view exists) — a
   request within `max*` can still revert at the external leg on a liquidity shortfall
   (accepted deviation; `forceDeallocate` unsticks).

2. **`_withdraw`** (CEI ordering): spend the allowance if `caller != owner`; snapshot
   `totalSharesOwned = balanceOf(owner)` and `supplyBeforeBurn = totalSupply()` **before**
   the burn; `_burn(owner, shares)` (the `_update` hook skips `onShareTransfer` on the burn
   leg); call `FUND_MANAGER.onWithdraw(…)`.

3. **`onWithdraw(holder, shares, totalSharesOwned, supplyBeforeBurn, receiver, redeemingAssets)`**
   (`VAULT_ROLE`). Reverts `BAD_WITHDRAW_ARGS` if `totalSharesOwned == 0` or
   `shares > totalSharesOwned`.
   - **Decrease units** proportional to shares burned:
     `delta = ceil(holderUnits · shares / totalSharesOwned)` (a full exit zeros them). A
     dust position with 0 units is skipped, not reverted.
   - **Source the payout** for `redeemingAssets`, in priority order:
     - **Resting raw underlying** (`fromDonation`, measured before any downgrade): only
       ever a donation (A.1). It is counted in NAV, so the redeemer is entitled to their
       slice; spending it first keeps the external leg bounded and stops the donation being
       stranded. Capped at the external slice.
     - **Reserve slice** (shares-proportional):
       `fromReserve = ceil(scaledYieldAssetsBalance() · shares / supplyBeforeBurn)`, clamped
       at `redeemingAssets`. `Ceil` is the safe rounding direction (paired with OZ's floor
       `redeemingAssets`). Downgraded from the super-token reserve.
     - **External remainder:** `fromExternal = redeemingAssets − fromReserve − fromDonation`,
       drawn via `EXTERNAL_VAULT.withdraw(fromExternal, FM, FM)` — **FM-first**, so only
       the FM (never the end receiver) must clear Morpho's `receiveAssetsGate`. For a
       compliant external this is `≤` the position's value (E.1); it reverts if Morpho's
       instant liquidity cannot cover it (the accepted `max*` deviation).

     All three legs then leave the FM as a single
     `safeTransfer(receiver, redeemingAssets)` — the receiver ends with exactly
     `redeemingAssets`; the FM holds 0 underlying.
   - **Rebalance.** `_rebalanceYieldAssets()` restores the reserve to target for the
     reduced unit count (pull on a deficit, trim on a surplus — best-effort).
   - **Recalibrate.** `_recalibrateFlow()`. The flow rate decreases, which releases GDA
     buffer and never reverts from a drained reserve.

   There is no principal-counter step: `redeemingAssets = shares · NAV / supply` (floor),
   so the burn removes exactly the redeemer's pro-rata slice and the share price is
   unchanged for the holders who stay (floor rounding favours them).

## Why the reserve slice is shares-proportional

Sourcing the reserve leg as the holder's share fraction of the reserve keeps the external
leg bounded by the external position's value, so a request within `maxRedeem` is always
*value*-serviceable for a compliant external (instant liquidity permitting):

```
f             = shares / supplyBeforeBurn          (the redeemer's NAV fraction)
redeemingAssets ≈ f · NAV                          (OZ floor)
fromReserve   ≈ f · scaledReserve                  (Ceil)
fromExternal  = redeemingAssets − fromReserve − fromDonation
              ≤ f · positionValue                  ≤ previewRedeem(balanceOf(FM))
```

The single post-payout `_rebalanceYieldAssets()` then restores the reduced unit count's
reserve target (best-effort).

## Loss vs. terminal impairment vs. illiquidity

- **Loss** (`externalPositionValue() > 0`, but the external position has lost some
  principal): NAV falls, so `previewRedeem` prices the share below the entry price and the
  exiting holder takes the pro-rata impaired payout — honest, immediate pass-through. The
  reserve leg is unaffected (it is super-token, not external shares); only the external
  remainder carries the loss. The burn removes exactly `shares · NAV / supply`, so there is
  no value transfer between leavers and stayers.
- **Terminal impairment / blocked exit gates** (`externalPositionValue() == 0` or
  `!canWithdrawExternal()` while shares are outstanding): the vault is fully paused, so a
  request cannot land here. The stream keeps paying existing holders from the reserve
  until it is naturally liquidated. See
  [D.2](../invariants.md#d2--external-pause-terminal-impairment-or-blocked-exit-gates-echidna).
- **Illiquidity** (position fully valued but Morpho's idle + liquidity adapter cannot
  cover the leg): NOT paused and NOT visible in `max*` (no liquidity view) — the request
  reverts at the external leg. Anyone can unstick it via Morpho's permissionless
  `forceDeallocate` (≤ 2% penalty on the FM's shares).

## ERC-4626 notes

- `withdraw` / `redeem` are synchronous; `previewWithdraw` / `previewRedeem` do not revert.
- `maxWithdraw` / `maxRedeem` reflect *value*-serviceability via `totalManagedAssets()`,
  are `0` under the external pause, and can overestimate vs. Morpho's instant liquidity
  (accepted deviation).
- The allowance is spent on the owner when `caller != owner`.

## Key properties

- **Pays exactly the priced amount** — [B.2](../invariants.md#b2--withdrawal-pays-exactly-the-priced-amount-echidna).
- **`max*` never bricks under loss (modulo external instant liquidity)** — [E.1](../invariants.md#e1--max-never-brick-except-on-external-instant-liquidity-accepted-deviation-echidna).
- **No idle underlying in the FM** — [A.1](../invariants.md#a1--no-raw-underlying-at-rest-in-the-fundmanager-echidna).
- **Dust position does not brick withdraw** — [C.3](../invariants.md#c3--dust-position-shares-but-zero-units-does-not-brick-withdraw-echidna).
