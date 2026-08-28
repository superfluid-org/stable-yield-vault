# Investor Redeem Flow (Asynchronous)

## Contracts involved

| Contract | Role |
|---|---|
| **StableYieldAsyncVault** | Accepts redeem requests, custodies locked shares & claimable-redeem assets, releases underlying to claimants |
| **FundManager** | Holds unutilized underlying directly and a yield-asset (super-token) reserve; supplies underlying to the vault on net-outflow settlements; adjusts GDA units |
| **GDA Pool** | Superfluid pool owned by the FundManager. Units are decremented on `requestRedeem` and the flow recalibrates downward |
| **Fund Operator** | EOA/bot holding `FUND_OPERATOR_ROLE`. Ensures FM liquidity and triggers epoch settlement |

Note: `RedeemClaimingRoom` is no longer a separate contract. The vault itself earmarks claimable-redeem assets in its own balance using `totalClaimableRedeemAssets`.

## Asset states

| State | Location | Description |
|---|---|---|
| SHARES | Investor wallet | Vault shares held by the investor. Transferable — a transfer drags the proportional GDA pool units along via `FundManager.onShareTransfer`. Only burned through `requestRedeem` → `redeem`/`withdraw`. |
| PENDING REDEEM SHARES | StableYieldAsyncVault | Shares transferred to the vault on `requestRedeem`, awaiting settlement |
| CLAIMABLE REDEEM ASSETS | StableYieldAsyncVault | Underlying earmarked inside vault balance; tracked by `totalClaimableRedeemAssets` |
| ASSETS | Investor wallet | Underlying tokens returned to the investor on claim |

## Sequence diagram

```mermaid
sequenceDiagram
    participant I as Investor
    participant AV as Vault
    participant FM as FundManager
    participant POOL as GDA Pool
    participant FO as Fund Operator
    participant INV as External Investment

    rect rgb(230, 245, 255)
    Note over I, POOL: Phase 1 - Request
    I->>AV: (1.1) requestRedeem(shares, controller, owner)
    activate AV
    AV->>FM: (1.2) onRequestRedeem(owner, shares, totalSharesOwned)
    FM->>POOL: decrement owner units (proportional), recalibrate flow
    Note over I, AV: (1.3) internal _transfer - owner share balance to vault balance (locked until claim; `onShareTransfer` is skipped because `to == vault`)
    AV-->>I: requestId = 0
    deactivate AV
    end

    rect rgb(255, 245, 230)
    Note over FO, AV: Phase 2 - closeEpoch (snapshot and lock)
    FO->>FM: (2.1) closeEpoch(workingAssets)
    FM->>AV: onCloseEpoch(workingAssets + unutilizedAssetsBalance + scaledYieldAssetsBalance)
    Note right of AV: snapshot depositingAssets, redeemingShares, rate. currentEpoch advances, requests rejected while open
    end

    rect rgb(255, 240, 240)
    Note over FO, INV: Between phases - Operator ensures FM liquidity
    Note right of FO: redeemingAssets = snap.redeemingShares * snap.rate. deficit = max(0, redeemingAssets - snap.depositingAssets). Use canSettleEpoch / evaluateFunding to size top-up
    opt FM cannot cover deficit + yield-asset reserve
        FO->>INV: liquidate working assets
        INV-->>FO: underlying
        FO->>FM: give(amount) - tops up FM's underlying balance
    end
    end

    rect rgb(255, 245, 230)
    Note over FO, AV: Phase 3 - settleEpoch (net flows)
    FO->>FM: (3.1) settleEpoch()
    Note right of FM: canSettleEpoch precondition check. Reverts SETTLEMENT_PRECONDITIONS_NOT_MET otherwise
    FM->>AV: onSettleEpoch()
    Note right of AV: totalClaimableRedeemAssets += redeemingAssets
    alt depositing greater or equal redeeming
        AV->>FM: transfer surplus (depositing - redeeming)
    else depositing less than redeeming
        AV->>FM: (3.2) ERC-20 transferFrom for deficit
        FM-->>AV: underlying (from FM unutilized balance, no super-token downgrade)
    end
    Note right of AV: store epoch rate, mark settled, delete snapshot
    Note right of FM: if snap.depositingAssets > 0 increase FM units, _rebalanceYieldAssets, _recalibrateFlow
    end

    rect rgb(230, 255, 230)
    Note over I, AV: Phase 4 - Claim
    I->>AV: (4.1) redeem(shares, receiver, controller) or withdraw(assets, receiver, controller)
    Note right of AV: lazy-settle pending to claimable at epoch rate, burn shares held since requestRedeem, decrement totalClaimableRedeemAssets
    AV->>I: (4.2) transfer underlying
    end
```

## Flow

### Phase 1: Request

```
(1.1) Investor → Vault: requestRedeem(shares, controller, owner)
      Reverts (in order):
      - INVALID_PARAMETERS  if shares == 0
      - INVALID_CALLER      if owner != msg.sender and msg.sender is not an
                            approved operator of owner
      - EPOCH_SETTLEMENT_IN_PROGRESS  if a settlement is in progress
      Then:
      - Lazy-settles any prior pending redeem from a settled epoch
        (_settleRedeemIfNeeded)
      - Snapshots totalSharesOwned = balanceOf(owner) BEFORE the share lock
      - INVALID_PARAMETERS if shares > totalSharesOwned

(1.2) Vault → FundManager: onRequestRedeem(owner, shares, totalSharesOwned)
      - Restricted to VAULT_ROLE
      - BAD_REDEEM_ARGS if totalSharesOwned == 0 or shares > totalSharesOwned
        or if the owner currently holds zero pool units
      - FM computes delta:
            if shares == totalSharesOwned: delta = userUnits (full exit)
            else: delta = ceil(userUnits * shares / totalSharesOwned)
      - FM: POOL.updateMemberUnits(owner, userUnits - delta)
      - FM: _recalibrateFlow() — totalUnits decreases → flowRate decreases

(1.3) Vault transfers shares owner → vault via the internal ERC-20 path
      (external `transfer` is disabled by design D6)
      - totalPendingRedeemShares += shares
      - _controllerStates[controller].pendingRedeemShares += shares
      - _controllerStates[controller].redeemRequestEpoch = currentEpoch
      - Emits RedeemRequest; returns requestId = 0
```

Units are decremented at request time (per D2 / D3). The investor stops
accruing yield immediately upon `requestRedeem`.

### Phase 2: closeEpoch (snapshot & lock)

See `deposit-flow.md` — closeEpoch is symmetric for deposits and redeems.
The FM-level entry point is `closeEpoch(workingAssets)`, which calls the
vault hook `onCloseEpoch(totalAssets)` with

```
totalAssets = workingAssets + unutilizedAssetsBalance() + scaledYieldAssetsBalance()
```

After this call, the exact `redeemingAssets` is known:

```
redeemingAssets = snapshot.redeemingShares * snapshot.rate / ASSETS_PER_SHARE_SCALE
deficit         = max(0, redeemingAssets − snapshot.depositingAssets)
```

No estimation needed. No race conditions with new requests (they revert
until settleEpoch).

### Between phases: Operator ensures FM liquidity

```
The operator can use the FundManager view functions to size the top-up:
  - canSettleEpoch() returns (canSettle, reason, snap). If
    reason == "INSUFFICIENT_ASSETS_IN_FUND_MANAGER", the FM cannot cover the
    deficit and yield-asset reserve combined.
  - evaluateFunding() returns the signed amount the operator should give
    (positive) or can take (negative).
  - evaluateYieldAssetsDeficit() returns the super-token shortfall against
    `_targetFlowRate * guaranteedFlowDuration`.

If a top-up is needed:
  - Operator liquidates working assets (offchain or via an adapter)
  - Calls FM.give(amount) to deposit underlying into the FM
    (no upgrade to super-token at give-time; rebalancing into the yield-asset
     reserve happens later inside settleEpoch via _rebalanceYieldAssets,
     or on demand via ensureYieldFlowDuration).
```

The redeem deficit is exact at this point. Separately, `canSettleEpoch`
also checks the post-settlement yield-asset reserve; the GDA buffer caveat
from [`../invariants.md`](../invariants.md) D.5 still applies to that reserve.

### Phase 3: settleEpoch (net flows)

```
(3.1) Operator → FundManager: settleEpoch()
      - Only callable by an account with FUND_OPERATOR_ROLE; nonReentrant
      - canSettleEpoch() is invoked first; reverts with
        SETTLEMENT_PRECONDITIONS_NOT_MET(reason) if the snapshot is not
        closed or if FM holdings cannot cover (redeemingAssets +
        post-settlement yield-asset reserve).
      - FM keeps the snapshot in memory (canSettleEpoch returns it) and
        calls Vault.onSettleEpoch()  (onlyFundManager)

      Inside Vault.onSettleEpoch():
        - redeemingAssets = snap.redeemingShares * snap.rate / ASSETS_PER_SHARE_SCALE
        - totalClaimableRedeemAssets += redeemingAssets    (vault-side earmark)
        - If depositing >= redeeming:
            surplus → FM (vault.safeTransfer)
          Else:                                             (3.2)
            deficit = redeemingAssets - depositing
            underlyingAsset.safeTransferFrom(FM, vault, deficit)
              → ERC-20 pull from FM's underlying balance using the unlimited
                allowance the FM granted to the vault at deploy.
                No super-token is downgraded in this path.
        - _unclaimedRedeemShares += redeemingShares
          (shares are still in totalSupply but no longer back NAV)
        - _epochRate[settlingEpoch] = rate
        - _epochSettled[settlingEpoch] = true
        - Delete snapshot

      Back in FM.settleEpoch():
        - If snap.depositingAssets > 0: increase FM units, _rebalanceYieldAssets,
          _recalibrateFlow (these grow / refresh the yield-asset reserve and
          the flow rate). On a pure-redeem epoch, none of this runs.
```

No unit manipulation happens on the redeem side during onSettleEpoch — the
units were already removed at request time.

### Phase 4: Claim

```
(4.1) Investor → Vault: redeem(shares, receiver, controller)
      or         withdraw(assets, receiver, controller)
      or the 2-arg ERC-4626 overloads (msg.sender becomes the controller)
      - msg.sender must be controller or an approved operator
      - Lazy-settles pending → claimable at the settled rate
      - Reverts with NOTHING_TO_CLAIM if nothing claimable

      Proportional deduction:
        redeem(shares, …)   → assets = shares * claimableAssets / claimableShares
        withdraw(assets, …) → shares = ceil(assets * claimableShares / claimableAssets)
                              (rounded up so at least 1 share is burned)

      - claimableRedeemShares[controller] -= shares
      - claimableRedeemAssets[controller] -= assets
      - _unclaimedRedeemShares -= shares
      - totalClaimableRedeemAssets -= assets
      - Burn `shares` from the vault (held since requestRedeem)

(4.2) Vault → receiver: underlyingAsset.safeTransfer(receiver, assets)
      - Paid out of the vault's earmarked balance
```

## ERC-7540 compliance

- `requestRedeem` transfers shares from the owner to the vault.
- `redeem` / `withdraw` (2-arg and 3-arg) consume claimable balances,
  burn the held shares, and release underlying from the vault's earmark.
- `pendingRedeemRequest` returns pending shares (zero once the request's
  epoch has been settled).
- `claimableRedeemRequest` returns claimable shares, including pending that
  has become claimable by virtue of the epoch having been settled.
- `previewRedeem` / `previewWithdraw` revert — required for async vaults.

## Key invariants

1. **Vault balance partition.** At quiescent state,
   `underlyingAsset.balanceOf(vault) == totalPendingDepositAssets + totalClaimableRedeemAssets`.
   Claimants can only be paid from the `totalClaimableRedeemAssets` side of
   that partition. The operator has no pathway to touch these assets.

2. **settleEpoch reverts up-front if FM cannot cover the deficit.**
   `canSettleEpoch()` checks that
   `scaledYieldAssetsBalance() + unutilizedAssetsBalance() + depositingAssets
    >= redeemingAssets + requiredScaledYieldAssetsBalance`
   before the vault hook runs. Failure reverts with
   `SETTLEMENT_PRECONDITIONS_NOT_MET("INSUFFICIENT_ASSETS_IN_FUND_MANAGER")`.
   All requests in an epoch settle atomically — no partial settlement.

3. **Unit removal at request time.** Investors stop streaming yield on
   `requestRedeem`, not on claim. This prevents a redeeming investor from
   continuing to accrue yield during the settlement window.

4. **Once closeEpoch is called, settleEpoch must follow.** No rollback.
   Requests in the closed epoch are frozen until `settleEpoch` completes.

5. **Shares are burned at claim time** (ERC-7540), not at settlement.
   `_unclaimedRedeemShares` tracks shares still in `totalSupply` whose
   backing assets have already left NAV — `onCloseEpoch` subtracts them from
   `effectiveSupply` to keep pricing consistent.

6. **Forward pricing.** All redeem requests in a given epoch receive the
   same `assetsPerShare`, locked at `closeEpoch`.

7. **Share transfers move GDA units.** Shares are transferable; the vault's
   `_update` hook calls `FundManager.onShareTransfer(from, to, value)` on
   shareholder-to-shareholder transfers, which transfers a proportional slice
   of the sender's GDA pool units to the receiver so the yield stream tracks
   share ownership. Exit (redemption) still goes through `requestRedeem`
   → `redeem`/`withdraw`.
