# Investor Deposit Flow (Asynchronous)

## Contracts involved

| Contract | Role |
|---|---|
| **StableYieldAsyncVault** | ERC-7540 vault. Accepts deposit requests, custodies pending deposit assets, mints shares at claim time |
| **FundManager** | Holds unutilized underlying directly, plus a separate yield-asset (super-token) reserve. Reports NAV, drives epoch settlement, operates the GDA pool |
| **GDA Pool** | Superfluid pool owned by the FundManager. Streams yield (in super-token) to unit holders |
| **Fund Operator** | EOA/bot holding `FUND_OPERATOR_ROLE`. Triggers epoch settlement and manages capital in/out of the FundManager |

Note: `DepositWaitingRoom` and `StableYieldReserve` are no longer separate contracts. The vault itself escrows pending deposit assets, and the FundManager owns the GDA pool.

## Asset states

| State | Location | Description |
|---|---|---|
| ASSETS | Investor wallet | Underlying tokens held by the investor |
| PENDING DEPOSIT ASSETS | StableYieldAsyncVault | Pending deposits awaiting settlement. Tracked by `totalPendingDepositAssets`. Not part of NAV |
| UNUTILIZED ASSETS | FundManager (underlying) | Settled underlying held by the FM, available to cover redeems or be taken out for investment. Equals `unutilizedAssetsBalance()` |
| YIELD-ASSET RESERVE | FundManager (super-token) | Super-token reserve funding the GDA flow. Equals `yieldAssetsBalance()`; `scaledYieldAssetsBalance()` = same value rescaled to underlying decimals |
| WORKING ASSETS | External investment | Assets taken out of the FundManager (via `take`) and deployed; reported back to `closeEpoch` as `workingAssets` |

## Sequence diagram

```mermaid
sequenceDiagram
    participant I as Investor
    participant AV as StableYieldAsyncVault
    participant FM as FundManager
    participant POOL as GDA Pool
    participant FO as Fund Operator
    participant INV as External Investment

    rect rgb(230, 245, 255)
    Note over I, AV: Phase 1 — Request
    I->>AV: (1.1) requestDeposit(assets, controller, owner)
    Note right of I: Transfer underlying to vault
    Note right of AV: Custody in vault balance<br/>totalPendingDepositAssets += assets<br/>Not part of NAV<br/>No GDA units granted yet (D2)
    end

    rect rgb(255, 245, 230)
    Note over FO, AV: Phase 2 — closeEpoch (snapshot & lock)
    FO->>FM: (2.1) closeEpoch(workingAssets)
    FM->>AV: onCloseEpoch(workingAssets + unutilizedAssetsBalance() + scaledYieldAssetsBalance())
    Note right of AV: Snapshot pending flows<br/>Lock epoch rate = totalFundAssets / effectiveSupply<br/>Advance currentEpoch (new requests rejected while snapshot open)
    end

    rect rgb(255, 245, 230)
    Note over FO, POOL: Phase 3 — settleEpoch (net flows)
    FO->>FM: (3.1) settleEpoch()
    Note right of FM: canSettleEpoch() precondition check;<br/>reverts SETTLEMENT_PRECONDITIONS_NOT_MET otherwise
    FM->>AV: onSettleEpoch()
    Note right of AV: Uses locked snapshot
    alt depositing >= redeeming
        AV->>FM: (3.2) transfer surplus = depositing - redeeming
    else depositing < redeeming
        AV->>FM: ERC-20 transferFrom for deficit (FM granted allowance at deploy)
    end
    Note right of FM: If snap.depositingAssets > 0:<br/>POOL.increaseMemberUnits(FM, _toUnit(depositingAssets))<br/>_rebalanceYieldAssets() (upgrade if needed)<br/>_recalibrateFlow()
    end

    rect rgb(230, 255, 230)
    Note over I, POOL: Phase 4 — Claim
    I->>AV: (4.1) deposit(assets, receiver, controller)<br/>or mint(shares, receiver, controller)
    Note right of AV: Lazy-settle pending → claimable at epoch rate<br/>Mint shares to receiver (no asset movement)
    AV->>FM: (4.2) onClaimDeposit(receiver, assets)
    FM->>POOL: Transfer units from FM → receiver
    Note right of POOL: Investor now receives the yield stream
    end

    rect rgb(245, 240, 255)
    Note over FO, INV: Operator capital management (independent of settlement)
    FO->>FM: take(amount)  %% pull underlying out to deploy
    FM->>FO: underlying
    FO->>INV: deploy
    INV-->>FO: returns / rewards
    FO->>FM: give(amount)  %% return underlying to FM
    end
```

## Flow

### Phase 1: Request

```
(1.1) Investor → Vault: requestDeposit(assets, controller, owner)
      Reverts (in order):
      - INVALID_PARAMETERS  if assets == 0
      - INVALID_CALLER      if owner != msg.sender and msg.sender is not an
                            approved operator of owner
      - EPOCH_SETTLEMENT_IN_PROGRESS  if a settlement is in progress
                                      (i.e. _snapshot.epoch != 0)
      Then:
      - Lazy-settles any prior pending deposit this controller has from a
        settled epoch (_settleDepositIfNeeded)
      - Transfers `assets` from owner → vault (vault custodies directly)
      - totalPendingDepositAssets += assets
      - _controllerStates[controller].pendingDepositAssets += assets
      - _controllerStates[controller].depositRequestEpoch = currentEpoch
      - Emits DepositRequest; returns requestId = 0
```

No GDA units are granted at this step. Per design decision D2, the yield stream
commences at claim time, not at request time.

### Phase 2: closeEpoch (snapshot & lock)

```
(2.1) Operator → FundManager: closeEpoch(workingAssets)
      - Only callable by an account with FUND_OPERATOR_ROLE
      - FM computes
            totalAssets = workingAssets
                        + unutilizedAssetsBalance()
                        + scaledYieldAssetsBalance()
        (the yield-asset reserve is included in NAV alongside the
         working underlying and the unutilized underlying)
      - FM calls Vault.onCloseEpoch(totalAssets)  (onlyFundManager)
      - Vault reverts with PREVIOUS_EPOCH_NOT_SETTLED if a snapshot is still open
      - Vault computes effectiveSupply
            = totalSupply + _unclaimedDepositShares - _unclaimedRedeemShares
        (phantom shares for settled-but-unclaimed deposits are added;
         dead shares still in totalSupply for settled-but-unclaimed redeems
         are subtracted)
      - Vault locks epoch rate
            = effectiveSupply == 0 ? 1e18 : totalAssets * 1e18 / effectiveSupply
      - Vault snapshots
            { epoch, depositingAssets, redeemingShares, rate }
      - Vault zeroes totalPendingDepositAssets and totalPendingRedeemShares
      - Vault increments currentEpoch (new requests land in the next epoch)
      - Vault stores _lastReportedTotalAssets = totalAssets (used by ERC-4626
        totalAssets() view; point-in-time-stale by design)
      - While a snapshot is open, requestDeposit / requestRedeem revert
        with EPOCH_SETTLEMENT_IN_PROGRESS
```

### Phase 3: settleEpoch (net flows & credit units)

```
(3.1) Operator → FundManager: settleEpoch()
      - Only callable by an account with FUND_OPERATOR_ROLE; nonReentrant
      - FM calls canSettleEpoch() and reverts with
        SETTLEMENT_PRECONDITIONS_NOT_MET(reason) if any of:
          (a) snap.epoch == 0 (closeEpoch not called)
          (b) FM cannot cover the post-settlement state, i.e.
              scaledYieldAssetsBalance() + unutilizedAssetsBalance()
              + snap.depositingAssets
                <  redeemingAssets + requiredScaledYieldAssetsBalance
              where requiredScaledYieldAssetsBalance is the super-token
              needed to sustain the new flow rate over guaranteedFlowDuration.
      - canSettleEpoch returns the snapshot, which FM keeps in memory
        (the vault deletes it inside onSettleEpoch).
      - FM calls Vault.onSettleEpoch()  (onlyFundManager)

      Inside Vault.onSettleEpoch():
        - redeemingAssets = snap.redeemingShares * snap.rate / 1e18
        - totalClaimableRedeemAssets += redeemingAssets   (vault-side earmark)
        - If depositing >= redeeming:
            surplus = depositing - redeeming
            vault.safeTransfer(fundManager, surplus)       (3.2)
          Else:
            deficit = redeeming - depositing
            underlyingAsset.safeTransferFrom(fundManager, vault, deficit)
              → ERC-20 pull from FM's underlying balance using the
                unlimited allowance the FM granted to the vault at deploy.
                No super-token downgrade happens in this path.
        - _unclaimedDepositShares += depositing * 1e18 / rate
        - _unclaimedRedeemShares  += redeemingShares
        - _epochRate[settlingEpoch] = rate
        - _epochSettled[settlingEpoch] = true
        - Emit EpochSettled; delete snapshot

      Back in FM.settleEpoch():
        - If snap.depositingAssets > 0:                     (3.3)
            POOL.increaseMemberUnits(
                FM, _toUnit(snap.depositingAssets))
              where _toUnit(amount) = amount / RAW_PER_UNIT.
              RAW_PER_UNIT = 10 ** (underlyingDecimals - 6), so one whole
              underlying token maps to 1e6 pool units.
            _rebalanceYieldAssets():
              if yield-asset reserve falls short of
                _flowRatePerUnit * totalUnits * guaranteedFlowDuration,
                FM upgrades unutilized underlying into super-token;
                if it has excess, FM downgrades back into underlying.
            _recalibrateFlow():
              flowRate = _flowRatePerUnit * POOL.totalUnits
              with _flowRatePerUnit = 1e12 * stableYieldRate
                                      / (YEAR * BP_DENOMINATOR)
        - If snap.depositingAssets == 0, none of the unit / flow / rebalance
          steps run; the FM emerges unchanged on the streaming side.
```

The freshly-minted units belong to FM until individual depositors claim. FM
"self-receives" its own unit share of the flow during this interim.

### Phase 4: Claim

```
(4.1) Investor → Vault: deposit(assets, receiver, controller)
      or        mint(shares, receiver, controller)
      or the 2-arg ERC-4626 overloads (msg.sender becomes the controller)
      - msg.sender must be controller or an approved operator
      - Lazy-settles pending → claimable at the settled epoch's rate
      - Reverts with NOTHING_TO_CLAIM if nothing is claimable
      - Proportional deduction from claimableDepositAssets / claimableDepositShares
      - Vault mints shares to receiver (no asset movement — assets were
        pushed to FM during settlement, or kept to cover redeems)

(4.2) Vault → FundManager: onClaimDeposit(receiver, assets)
      - FM transfers `_toUnit(assets)` units from its own pool slot to
        `receiver` via decreaseMemberUnits + increaseMemberUnits
        (no flow-rate change, no totalUnits change)
      - Investor now receives the yield stream in the underlying's super-token
```

### Operator capital management (independent of settlement)

```
FO → FM: take(amount)
      - safeTransfer of underlying directly from FM to operator.
        No super-token downgrade. No solvency check enforced inside `take`
        (settlement-time checks happen in canSettleEpoch). Operators must
        therefore not drain FM below what is needed to cover the next
        epoch's redeem deficit and the yield-asset reserve.
      - Used to deploy assets into external / offchain investments
        (these become WORKING assets; their value is reported back via
         `workingAssets` on the next closeEpoch)

FO → FM: give(amount)
      - safeTransferFrom of underlying from operator to FM.
        No upgrade to super-token at this step (any rebalance into the
        yield-asset reserve happens later via _rebalanceYieldAssets,
        e.g. inside settleEpoch, setStableYieldRate, or
        ensureYieldFlowDuration).
      - Used to return realized gains / liquidated principal to the FM.
```

`take` / `give` are not gated by the settlement lifecycle — the operator can
move capital in/out at any time. Because they perform no invariant check,
the operator must coordinate them with `canSettleEpoch` / `evaluateFunding`
view calls before each settlement.

## ERC-7540 compliance

- `requestDeposit` transfers assets from the owner to the vault.
- `deposit` / `mint` (2-arg and 3-arg) consume claimable balances without
  transferring assets — assets were already transferred at request time.
- `pendingDepositRequest` returns the pending assets (zero once the request's
  epoch has been settled; the balance moves to `claimableDepositRequest`).
- `claimableDepositRequest` returns claimable assets, including pending that
  has become claimable by virtue of the epoch having been settled.
- `previewDeposit` / `previewMint` revert — required for async vaults.
- Shares are ERC-20 but non-transferable: `transfer` / `transferFrom` revert
  with `SHARES_NON_TRANSFERABLE`.

## Key invariants

1. **Vault underlying balance partition.** At quiescent state,
   `underlyingAsset.balanceOf(vault) == totalPendingDepositAssets + totalClaimableRedeemAssets`.
   Pending deposit assets and claimable redeem assets coexist in the vault's
   balance; the two counters keep them separable.

2. **Pending deposit assets are not counted in NAV.** `closeEpoch` prices the
   epoch using `workingAssets + unutilizedAssetsBalance() + scaledYieldAssetsBalance()`
   and `effectiveSupply`, all of which exclude pending deposits.

3. **effectiveSupply correction.** `effectiveSupply = totalSupply +
   unclaimedDepositShares − unclaimedRedeemShares`. This corrects for the lag
   between settlement (assets move) and claim (shares mint/burn).

4. **Rate is locked at closeEpoch.** All requests in a given epoch settle at
   the same `assetsPerShare` (forward pricing).

5. **Shares mint at claim time, not settlement time** (ERC-7540).

6. **Stream starts at claim time** (D2). Units are transferred from FM to the
   controller only when they call `deposit` / `mint`.

7. **Settlement serialized.** Between `closeEpoch` and `settleEpoch`, new
   `requestDeposit` / `requestRedeem` calls revert with
   `EPOCH_SETTLEMENT_IN_PROGRESS`. A previous epoch must be settled before a
   new one can close (`PREVIOUS_EPOCH_NOT_SETTLED`).

8. **Settlement preconditions.** `settleEpoch` reverts up-front via
   `canSettleEpoch` if the FM cannot cover both the net redeem deficit and
   the post-settlement yield-asset reserve (`requiredScaledYieldAssetsBalance =
   expectedNewFlowRate * guaranteedFlowDuration / SCALING_FACTOR`, where
   `expectedNewFlowRate = _flowRatePerUnit * newTotalUnits` and
   `newTotalUnits = POOL.totalUnits + _toUnit(snap.depositingAssets)`).
   No partial settlement is possible.
