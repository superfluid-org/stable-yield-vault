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
| **External ERC-4626** | Funds the external remainder in underlying. Reverts only if it is non-compliant (over-reports `maxWithdraw`) |
| **GDA Pool** | Superfluid pool; the holder's stream stops or shrinks proportionally |

## Asset locations

| Location | What lives there |
|---|---|
| External vault (held by FM) | Recoverable via `EXTERNAL_VAULT.maxWithdraw(FM)`; the redeemer's pro-rata slice exits with them |
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
    FM->>E: withdraw(external remainder, receiver, FM)
    FM->>U: safeTransfer(receiver, donation slice + reserve slice)
    FM->>FM: _rebalanceYieldAssets()  %% restore the reserve to target for the reduced unit count
    FM->>POOL: _recalibrateFlow()  %% lower flow rate releases GDA buffer; never reverts
```

## Step by step

1. **Vault entry.** `withdraw(assets, receiver, owner)` (or `redeem(shares, …)`).
   `nonReentrant`. OZ checks the request against `max*`:
   - `maxWithdraw(owner) = min(convertToAssets(balanceOf(owner)), totalManagedAssets())`
   - `maxRedeem(owner) = min(balanceOf(owner), convertToShares(totalManagedAssets()))`

   Both are `0` under terminal impairment. `totalManagedAssets()` (the reserve-inclusive
   NAV) is the global upper bound on what a redeem can source; a larger request reverts
   up-front with `ERC4626ExceededMax*`. `assets` is priced at the current floating share
   value.

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
       drawn via `EXTERNAL_VAULT.withdraw(fromExternal, receiver, FM)`. For a compliant
       external this is `≤ EXTERNAL_VAULT.maxWithdraw(FM)`, so a request within `max*` never
       bricks (E.1); it reverts only if the external over-reports `maxWithdraw`.

     The receiver ends with exactly `redeemingAssets`; the FM holds 0 underlying.
   - **Rebalance.** `_rebalanceYieldAssets()` restores the reserve to target for the
     reduced unit count (pull on a deficit, trim on a surplus — best-effort).
   - **Recalibrate.** `_recalibrateFlow()`. The flow rate decreases, which releases GDA
     buffer and never reverts from a drained reserve.

   There is no principal-counter step: `redeemingAssets = shares · NAV / supply` (floor),
   so the burn removes exactly the redeemer's pro-rata slice and the share price is
   unchanged for the holders who stay (floor rounding favours them).

## Why the reserve slice is shares-proportional

Sourcing the reserve leg as the holder's share fraction of the reserve keeps the external
leg bounded by the external's own `maxWithdraw`, so a request within `maxRedeem` is always
serviceable for a compliant external:

```
f             = shares / supplyBeforeBurn          (the redeemer's NAV fraction)
redeemingAssets ≈ f · NAV                          (OZ floor)
fromReserve   ≈ f · scaledReserve                  (Ceil)
fromExternal  = redeemingAssets − fromReserve − fromDonation
              ≤ f · ext.maxWithdraw                ≤ ext.maxWithdraw(FM)
```

The single post-payout `_rebalanceYieldAssets()` then restores the reduced unit count's
reserve target (best-effort).

## Loss vs. terminal impairment

- **Loss** (`EXTERNAL_VAULT.maxWithdraw(FM) > 0`, but the external position has lost some
  principal): NAV falls, so `previewRedeem` prices the share below the entry price and the
  exiting holder takes the pro-rata impaired payout — honest, immediate pass-through. The
  reserve leg is unaffected (it is super-token, not external shares); only the external
  remainder carries the loss. The burn removes exactly `shares · NAV / supply`, so there is
  no value transfer between leavers and stayers.
- **Terminal impairment** (`EXTERNAL_VAULT.maxWithdraw(FM) == 0` while shares are
  outstanding): the vault is fully paused, so a request cannot land here. The stream keeps
  paying existing holders from the reserve until it is naturally liquidated. See
  [D.2](../invariants.md#d2--terminal-external-impairment--full-pause-echidna).

## ERC-4626 notes

- `withdraw` / `redeem` are synchronous; `previewWithdraw` / `previewRedeem` do not revert.
- `maxWithdraw` / `maxRedeem` reflect serviceability via `totalManagedAssets()`, and are
  `0` under terminal impairment.
- The allowance is spent on the owner when `caller != owner`.

## Key properties

- **Pays exactly the priced amount** — [B.2](../invariants.md#b2--withdrawal-pays-exactly-the-priced-amount-echidna).
- **`max*` never bricks under loss** — [E.1](../invariants.md#e1--max-are-honest-never-bricking-bounds-echidna).
- **No idle underlying in the FM** — [A.1](../invariants.md#a1--no-raw-underlying-at-rest-in-the-fundmanager-echidna).
- **Dust position does not brick withdraw** — [C.3](../invariants.md#c3--dust-position-shares-but-zero-units-does-not-brick-withdraw-echidna).
