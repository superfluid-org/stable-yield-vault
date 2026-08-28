# System Invariants

Catalogue of invariants the StableYieldAsyncVault + FundManager system is intended to maintain. Each entry names the property, the code paths that enforce or rely on it, and the failure mode if violated.

For each invariant: **State** = the property in plain prose. **Where** = the contract-qualified functions that establish or rely on it. **Holds when** = the system states in which the property is meant to hold (e.g. quiescent vs. mid-settlement). **Breaks if** = the failure mode.

---

## A. Vault accounting

### A.1 — Vault underlying balance partition

**State.** At quiescent state (no settlement open):

```
underlyingAsset.balanceOf(vault) == totalPendingDepositAssets + totalClaimableRedeemAssets
```

The vault's underlying balance is partitioned into two non-overlapping buckets — assets escrowed for in-flight deposits, and assets earmarked for settled-but-unclaimed redeems.

**Where.** `StableYieldAsyncVault.requestDeposit` / `requestDepositWithPermit2` pull underlying into the vault and `StableYieldAsyncVault._recordDepositRequest` increments `totalPendingDepositAssets`. `StableYieldAsyncVault.onCloseEpoch` zeroes the pending counters into the snapshot; `StableYieldAsyncVault.onSettleEpoch` adds `redeemingAssets` to `totalClaimableRedeemAssets`. `StableYieldAsyncVault._claimRedeem` decrements `totalClaimableRedeemAssets` and transfers out. The deposit→claim flow does *not* move assets out of the vault — they were already pushed to the FM at settlement.

**Holds when.** Quiescent (between epochs); mid-settlement the partition shifts but ends balanced.

**Breaks if.** Anyone could transfer underlying *into* the vault out-of-band (the partition is one-directional — the vault can hold *more* than the sum, never less, except via these two paths).

### A.2 — Pending counters reset on close

`totalPendingDepositAssets == 0` and `totalPendingRedeemShares == 0` immediately after `onCloseEpoch` returns and until the next `requestDeposit` / `requestRedeem`. The values are moved into the snapshot, not lost.

**Where.** `StableYieldAsyncVault.onCloseEpoch` (`totalPendingDepositAssets = 0; totalPendingRedeemShares = 0` after the `_snapshot` write).

### A.3 — Single-snapshot serialization

At most one closed-but-unsettled epoch exists at a time:

```
_snapshot.epoch == 0  ⇔  no epoch is in the close→settle window
```

`onCloseEpoch` reverts with `PREVIOUS_EPOCH_NOT_SETTLED` if a snapshot is already open; `onSettleEpoch` reverts with `NO_EPOCH_TO_SETTLE` if none is. `requestDeposit` / `requestRedeem` revert with `EPOCH_SETTLEMENT_IN_PROGRESS` while a snapshot is open.

**Where.** `StableYieldAsyncVault.requestDeposit` / `requestDepositWithPermit2` / `requestRedeem` (`EPOCH_SETTLEMENT_IN_PROGRESS` guard), `StableYieldAsyncVault.onCloseEpoch` (`PREVIOUS_EPOCH_NOT_SETTLED`), `StableYieldAsyncVault.onSettleEpoch` (`NO_EPOCH_TO_SETTLE`; `delete _snapshot` at the end).

### A.4 — Effective supply correction

The epoch rate uses an *effective supply* that adds phantom shares for settled-but-unclaimed deposits and subtracts dead shares for settled-but-unclaimed redeems:

```
effectiveSupply = totalSupply() + _unclaimedDepositShares − _unclaimedRedeemShares
rate = (totalFundAssets + 1) · ASSETS_PER_SHARE_SCALE / (effectiveSupply + VIRTUAL_SHARES)      // VIRTUAL_SHARES = 1e12
```

This corrects for the lag between settlement (assets move) and claim (shares mint/burn), so a controller who delays claiming neither dilutes nor concentrates the next epoch's pricing. The `+1` / `+VIRTUAL_SHARES` terms are OZ-style virtual assets/shares (first-deposit inflation mitigation); on an empty vault the bootstrap rate is therefore `ASSETS_PER_SHARE_SCALE / VIRTUAL_SHARES` (`1e6`), not `1e18`.

**Where.** `StableYieldAsyncVault.onCloseEpoch` (`effectiveSupply` and `epochRate` computation), `StableYieldAsyncVault.VIRTUAL_SHARES`.

### A.5 — Lag-correction counters track unclaimed positions

```
_unclaimedDepositShares = Σ over settled epochs of (depositingAssets / rate),  decremented on _claimDeposit
_unclaimedRedeemShares  = Σ over settled epochs of redeemingShares,            decremented on _claimRedeem
```

Both are monotonically tracked as deltas in `onSettleEpoch` and decremented in `_claimDeposit` / `_claimRedeem`.

**Where.** Increment: `StableYieldAsyncVault.onSettleEpoch`. Decrement: `StableYieldAsyncVault._claimDeposit` (`_unclaimedDepositShares`), `StableYieldAsyncVault._claimRedeem` (`_unclaimedRedeemShares`).

### A.6 — Single request-id per controller per side

```
requestId == REQUEST_ID == 0  always
```

The vault aggregates a controller's pending deposits/redeems into one slot per side. Multiple `requestDeposit` calls from the same controller within the same epoch accrete into `cs.pendingDepositAssets`; the request-id is constant.

**Where.** `StableYieldAsyncVault.REQUEST_ID` (constant), `StableYieldAsyncVault._recordDepositRequest` and `StableYieldAsyncVault.requestRedeem` (both return `REQUEST_ID`).

---

## B. Epoch lifecycle

### B.1 — closeEpoch must precede settleEpoch (no rollback)

Once `onCloseEpoch` runs, `onSettleEpoch` is the only path forward; new requests are frozen and the snapshot can only be cleared by settlement.

**Where.** `StableYieldAsyncVault.onCloseEpoch` (writes `_snapshot`), `StableYieldAsyncVault.onSettleEpoch` (the only path that deletes it); both are `onlyFundManager`.

**Breaks if.** A path mutates the snapshot without going through `onSettleEpoch`.

### B.2 — Settlement is atomic (all-or-nothing)

All requests in a closed epoch settle in one transaction. `AsyncFundManager.settleEpoch` is `nonReentrant` and either completes (snapshot deleted, `_epochSettled[settlingEpoch] = true`) or reverts entirely. There is no partial settlement.

**Where.** `AsyncFundManager.settleEpoch` (`nonReentrant`), `StableYieldAsyncVault.onSettleEpoch` (`_epochSettled[settlingEpoch] = true`, `delete _snapshot`).

### B.3 — Settlement preconditions enforced before vault hook runs

`AsyncFundManager.settleEpoch` calls `canSettleEpoch()` first and reverts with `SETTLEMENT_PRECONDITIONS_NOT_MET(reason)` if either:

1. `snap.epoch == 0` — no closed epoch (`reason = "CURRENT_EPOCH_NOT_CLOSED"`).
2. `scaledYieldAssetsBalance() + unutilizedAssetsBalance() + depositingAssets < redeemingAssets + requiredScaledYieldAssetsBalance` — FM does not have enough total value, across yield assets, unutilized underlying, and settling deposits, to cover redeeming assets *and* the post-settlement yield-asset reserve (`reason = "INSUFFICIENT_ASSETS_IN_FUND_MANAGER"`).

This is a solvency check, not a guarantee that all required liquidity is already in underlying form. If `redeemingAssets > depositingAssets` and the coverage exists as excess yield assets, the operator must rebalance/downgrade that excess before calling `settleEpoch`; otherwise the vault hook can still revert when it pulls the underlying deficit from the FM. In that case `ensureYieldFlowDuration()` is the intended pre-settlement rebalance path.

**Where.** `AsyncFundManager.settleEpoch` (precondition revert), `AsyncFundManager.canSettleEpoch` (the two checks; the required reserve includes the `FEE_BPS` fee-stream share).

### B.4 — closeEpoch behavior under zero NAV

`onCloseEpoch` does **not** explicitly reject `_totalAssets == 0`. Behavior splits on `effectiveSupply`:

- If `effectiveSupply == 0` → `epochRate = ASSETS_PER_SHARE_SCALE / VIRTUAL_SHARES` (`1e6`, the virtual-shares bootstrap value).
- If `effectiveSupply > 0` and `_totalAssets == 0` → `epochRate = ASSETS_PER_SHARE_SCALE / (effectiveSupply + VIRTUAL_SHARES)`, which floors to `0` as soon as `effectiveSupply + VIRTUAL_SHARES > ASSETS_PER_SHARE_SCALE` (i.e. roughly one whole 18-dec share outstanding). A zero rate then makes `_settleDepositIfNeeded` revert via division-by-zero (`pendingAssets.mulDiv(ASSETS_PER_SHARE_SCALE, 0)`), permanently freezing any controller's deposit pending in that epoch. Redeemers in the same epoch would resolve to 0 claimable assets.

This is not currently a documented invariant; flagged for audit attention as a soft denial-of-service path on a total-loss epoch.

**Where.** `StableYieldAsyncVault.onCloseEpoch` (no zero-check on `epochRate`); `StableYieldAsyncVault._settleDepositIfNeeded` (div-by-zero on subsequent lazy settle).

### B.5 — Rate is locked at closeEpoch (forward pricing)

All requests in a given epoch settle at the same `assetsPerShare`, frozen in `_snapshot.rate` at `onCloseEpoch` and committed to `_epochRate[settlingEpoch]` at `onSettleEpoch`. Between close and settle the rate cannot change.

**Where.** `StableYieldAsyncVault.onCloseEpoch` (`epochRate` → `_snapshot.rate`), `StableYieldAsyncVault.onSettleEpoch` (`_epochRate[settlingEpoch] = _snapshot.rate`).

---

## C. Shares (ERC-20 layer)

### C.1 — Share transfers re-balance GDA pool units

Shares are transferable. The vault's `_update` override calls `FundManagerBase.onShareTransfer(from, to, value)` on any shareholder-to-shareholder transfer (mint, burn, and the vault-custody legs of `requestRedeem`/claim are excluded). The FM moves a proportional slice of the sender's GDA pool units to the receiver (`delta = senderUnits * shares / vault.balanceOf(sender)`, rounded up) so the yield stream follows the shares. A transfer from an address with zero pool units is a **no-op** for the units (the `onShareTransfer` hook early-returns) so the shares still move — this keeps a dust position whose units were `Ceil`-zeroed by a near-full redeem transferable (changed 2026-06-04, sync-vault audit Finding 2; the hook lives in the shared `FundManagerBase`).

**Where.** `StableYieldAsyncVault._update` (vault hook), `FundManagerBase.onShareTransfer` (FM unit transfer; `senderUnits == 0` early-return).

### C.2 — Shares mint at claim, not at settlement

`_mint` is only called inside `_claimDeposit`. Settlement updates accounting; the share-token state changes only when the controller claims.

**Where.** `StableYieldAsyncVault._claimDeposit` (`_mint`).

### C.3 — Shares burn at claim, not at request or settlement

`_burn(address(this), shares)` is only called inside `_claimRedeem`. Between `requestRedeem` and `redeem`/`withdraw`, the shares are held by the vault and remain in `totalSupply` (covered by `_unclaimedRedeemShares` in pricing math).

**Where.** `StableYieldAsyncVault.requestRedeem` (`_transfer(owner, address(this), shares)`), `StableYieldAsyncVault._claimRedeem` (`_burn`).

### C.4 — Vault custody of redeeming shares

Between `requestRedeem` (which transfers shares to `address(this)`) and `_claimRedeem` (which burns them), the vault's own share balance accounts for all in-flight redeems. The `_update` hook skips the `onShareTransfer` call when `to == address(this)`, so the vault-custody leg does not move GDA pool units (FM units are instead decreased by `onRequestRedeem`).

**Where.** `StableYieldAsyncVault.requestRedeem`, `StableYieldAsyncVault._update` (skips `to == address(this)` / `from == address(this)`), `AsyncFundManager.onRequestRedeem`.

### C.5 — At-least-one-share burn on `withdraw`

`withdraw(assets, …)` rounds shares **up** (`Math.Rounding.Ceil`) so any non-zero asset withdrawal burns at least one share, favoring the vault. `redeem(shares, …)` rounds assets **down** by default. `mint(shares, …)` rounds assets up; `deposit(assets, …)` rounds shares down.

**Where.** `StableYieldAsyncVault._withdraw` (`Math.Rounding.Ceil`), `StableYieldAsyncVault._mintShares` (`Math.Rounding.Ceil`), `StableYieldAsyncVault._redeem` / `_deposit` (floor).

---

## D. GDA pool & yield stream

### D.1 — Yield stream commences at claim, not at request (D2)

GDA units are transferred from the FM's slot to the controller's slot only inside `onClaimDeposit`. A depositor accrues no stream between `requestDeposit` and `deposit`/`mint`. Between settlement and claim, the FM "self-receives" its own unit share.

**Where.** `AsyncFundManager.onClaimDeposit` (called from `StableYieldAsyncVault._claimDeposit`); `AsyncFundManager.settleEpoch` (FM self-grants the epoch's units).

### D.2 — Yield stream stops at requestRedeem, not at claim

Units are decremented from the redeemer at `onRequestRedeem`, immediately after the request. The redeeming investor stops accruing yield as soon as the request lands — they do not continue streaming through the settlement window.

**Where.** `AsyncFundManager.onRequestRedeem` (called from `StableYieldAsyncVault.requestRedeem`). The decrement is proportional: `delta = ceil(userUnits · sharesRedeemed / totalSharesOwned)` for partial redeems, and exactly `userUnits` for full exits.

### D.3 — totalUnits and flow rate are conserved on claim-deposit

`onClaimDeposit` increases the receiver's units by `_toUnit(depositAssets)` and then decreases the FM's units by the same amount, where `_toUnit(underlyingAmount) = underlyingAmount / RAW_PER_UNIT`. Pool units are denominated in micro-tokens (`1e6` units per whole underlying token), so `RAW_PER_UNIT = 10 ** (underlyingDecimals − 6)`. Total pool units and `_targetFlowRate()` are unchanged. The increase-before-decrease order avoids a transient zero-total-units state when the FM is the only member.

**Where.** `AsyncFundManager.onClaimDeposit` (increase-then-decrease), `FundManagerBase._toUnit`, `FundManagerBase.RAW_PER_UNIT`.

### D.4 — Flow rate equals `_flowRatePerUnit · totalUnits`

```
_targetFlowRate = _flowRatePerUnit · POOL.getTotalUnits()
_flowRatePerUnit = 1e12 · stableYieldRate / (YEAR · BP_DENOMINATOR)
```

The `1e12` factor is decimals-independent for supported underlyings because `SCALING_FACTOR · RAW_PER_UNIT = 10 ** (18 − d) · 10 ** (d − 6) = 1e12`.

After every change to total units (`onSettleEpoch`, `onRequestRedeem`) or to the rate (`setStableYieldRate`), `_recalibrateFlow()` is called to bring the actual stream rate to target.

**Where.** `FundManagerBase` constructor and `FundManagerBase.setStableYieldRate` (`_flowRatePerUnit`), `FundManagerBase._targetFlowRate`, `FundManagerBase._recalibrateFlow`; callers: `AsyncFundManager.settleEpoch` (when `depositingAssets > 0`), `AsyncFundManager.onRequestRedeem`, `FundManagerBase.setStableYieldRate`, `FundManagerBase.ensureYieldFlowDuration` (restart only).

### D.5 — Forward-solvency horizon (yield-asset reserve)

The FM holds a super-token reserve sized to fund the target stream for at least `guaranteedFlowDuration`:

```
yieldAssetsBalance() ≥ _targetFlowRate · guaranteedFlowDuration
```

`evaluateYieldAssetsDeficit()` computes `requiredBalance − actualBalance`; `_rebalanceYieldAssets()` upgrades underlying or downgrades super-token to drive deficit toward zero. `canSettleEpoch` enforces the *post-settlement* version of this inequality before settlement runs.

**Where.** `FundManagerBase.evaluateYieldAssetsDeficit` (required balance includes the `FEE_BPS` fee-stream share), `AsyncFundManager.canSettleEpoch`, `AsyncFundManager._rebalanceYieldAssets`.

**Caveats.**
- `setStableYieldRate` and `setGuaranteedFlowDuration` do not perform a separate preflight forward-solvency check. They depend on `_rebalanceYieldAssets()` succeeding to maintain D.5; if the required upgrade cannot be funded, `_rebalanceYieldAssets()` reverts with `INSUFFICIENT_UNUTILIZED_ASSETS`.
- The current reserve formula neglects Superfluid's GDA buffer/security deposit. After `_recalibrateFlow()` starts or updates the stream, part of the FM's super-token balance may be reserved by Superfluid and excluded from `yieldAssetsBalance()` / `balanceOf`. As a result, the literal `yieldAssetsBalance() ≥ _targetFlowRate · guaranteedFlowDuration` check can be false immediately after successful settlement even though the missing amount is locked as protocol buffer rather than lost. A stricter invariant would include the GDA buffer in the actual balance side or require an additional buffer above the bare duration target.

### D.6 — Stream-solvency floor on duration

`guaranteedFlowDuration ≥ MIN_GUARANTEED_FLOW_DURATION` (= 1 day). Enforced in the constructor and in `setGuaranteedFlowDuration`.

**Where.** `FundManagerBase.MIN_GUARANTEED_FLOW_DURATION`, `FundManagerBase` constructor and `FundManagerBase.setGuaranteedFlowDuration` (`DURATION_BELOW_FLOOR`).

### D.7 — Pool config: units non-transferable, distribution-from-any-address disabled

The GDA pool is created with `transferabilityForUnitsOwner: false` and `distributionFromAnyAddress: false`. Only the FM (pool admin) can change unit balances; only the FM can distribute from the pool.

**Where.** `FundManagerBase` constructor (`PoolConfig`, `createPool` for `YIELD_POOL` and `FEE_POOL`).

---

## E. Treasury & scaling

### E.1 — Yield asset wraps the underlying

```
ISuperToken(yieldAsset).getUnderlyingToken() == underlyingAsset
```

Constructor reverts with `ASSET_MISMATCH` otherwise.

**Where.** `FundManagerBase` constructor (`getUnderlyingToken() != _asset` → `ASSET_MISMATCH`).

### E.2 — SCALING_FACTOR matches super-token / underlying decimal gap

```
SCALING_FACTOR = 10 ** (18 − underlyingDecimals)
RAW_PER_UNIT   = 10 ** (underlyingDecimals − 6)
```

Underlying amounts are multiplied by `SCALING_FACTOR` to enter super-token space (18-dec), and divided to leave it. Pool units use `RAW_PER_UNIT` so one whole underlying token maps to `1e6` pool units for every supported decimal count. The base constructor computes both factors generically for `underlyingDecimals ∈ [6, 18]` and reverts with `UNSUPPORTED_DECIMALS` outside that range, but the vault constructor pins the underlying to exactly 6 decimals (`INVALID_CONFIGURATION` otherwise) because `VIRTUAL_SHARES` and the 18-dec share presentation are hardcoded for it.

**Where.** `FundManagerBase` constructor (`SCALING_FACTOR`, `RAW_PER_UNIT`, `_flowRatePerUnit`), `FundManagerBase.setStableYieldRate`, `FundManagerBase._toUnit`, `FundManagerBase._upgrade` / `scaledYieldAssetsBalance`; `StableYieldAsyncVault` constructor (`decimals() != 6` → `INVALID_CONFIGURATION`).

### E.3 — Total NAV reported to the vault at close

```
totalAssets reported = workingAssets + unutilizedAssetsBalance() + scaledYieldAssetsBalance()
```

Working assets are operator-reported (off-chain, via `closeEpoch(workingAssets)`); the other two are read on-chain. The yield-asset reserve **is** counted in NAV (rescaled to underlying decimals), so depositors share in any unspent reserve and redeemers may force a downgrade to recover their share.

**Where.** `AsyncFundManager.closeEpoch`.

### E.4 — FM grants the vault unlimited underlying allowance

The FM `approve`s the vault for `type(uint256).max` of underlying at deploy. The vault uses this allowance in `onSettleEpoch` to pull the deficit on net-outflow epochs without going through `move`.

**Where.** `FundManagerBase` constructor (`forceApprove(msg.sender, type(uint256).max)`), `StableYieldAsyncVault.onSettleEpoch` (deficit branch `safeTransferFrom(FUND_MANAGER, …)`).

### E.5 — `give` / `take` are not gated by the settlement lifecycle, perform no solvency check

The operator can move underlying in/out of the FM at any time, including during the close→settle window. Neither function checks the forward-solvency horizon, the redeem deficit, or the yield-asset reserve. The operator is therefore responsible for coordinating capital movement with `canSettleEpoch` / `evaluateFunding` views — calling `take` between `closeEpoch` and `settleEpoch` may cause `settleEpoch` to revert at the precondition check (`INSUFFICIENT_ASSETS_IN_FUND_MANAGER`).

This is now an explicit invariant of the system (per `flow/settlement-flow.md` key invariant #8 and the "Operator capital management" section of `flow/deposit-flow.md`) — the FM does not protect itself from operator error; the operator carries the responsibility.

**Where.** `AsyncFundManager.give`, `AsyncFundManager.take`.

---

## G. ERC-7540 / ERC-4626 compliance

### G.1 — Preview functions revert

`previewDeposit`, `previewMint`, `previewRedeem`, `previewWithdraw` all revert with `NOT_SUPPORTED_BY_ASYNC_VAULT`. Required for fully-async vaults.

**Where.** `StableYieldAsyncVault.previewDeposit` / `previewMint` / `previewRedeem` / `previewWithdraw`.

### G.2 — `pendingX` returns 0 once the request's epoch is settled

```
pendingDepositRequest(_, controller) = isEpochSettled(cs.depositRequestEpoch) ? 0 : cs.pendingDepositAssets
pendingRedeemRequest (_, controller) = isEpochSettled(cs.redeemRequestEpoch)  ? 0 : cs.pendingRedeemShares
```

When the underlying epoch settles, the balance migrates to `claimableX` semantically — `pendingX` returns 0 even though `cs.pendingDepositAssets` may still be non-zero on storage (it gets zeroed lazily on next interaction).

**Where.** `StableYieldAsyncVault.pendingDepositRequest`, `StableYieldAsyncVault.pendingRedeemRequest`.

### G.3 — `claimableX` includes settled-but-unmigrated pending amounts

`claimableDepositRequest` and `claimableRedeemRequest` add the settled pending amount on top of any already-migrated claimable balance, so the view is correct even when storage hasn't been laz-settled yet.

**Where.** `StableYieldAsyncVault.claimableDepositRequest` / `claimableRedeemRequest` (and the `max*` views) via `_effectiveClaimableDepositAssets` / `_effectiveClaimableDepositShares` / `_effectiveClaimableRedeemShares` / `_effectiveClaimableRedeemAssets`.

### G.4 — `convertTo*` uses last-settled rate, never the in-flight snapshot

`convertToShares` / `convertToAssets` use `_lastSettledRate()` (the rate of the most recently settled epoch, falling back further if the immediate previous epoch closed but is not settled, and to `ASSETS_PER_SHARE_SCALE / VIRTUAL_SHARES` before any settlement).

**Where.** `StableYieldAsyncVault.convertToShares` / `convertToAssets`, `StableYieldAsyncVault._lastSettledRate`.

### G.5 — `totalAssets()` is stale between settlements

`totalAssets()` returns `_lastReportedTotalAssets`, set only at `onCloseEpoch`. It does not reflect intra-epoch yield accrual or operator capital movement. ERC-4626 callers should not rely on it for real-time NAV.

**Where.** `StableYieldAsyncVault.totalAssets`, `StableYieldAsyncVault.onCloseEpoch` (`_lastReportedTotalAssets = _totalAssets`).

### G.6 — supportsInterface

`supportsInterface` returns true for the four interface IDs documented in the `IStableYieldAsyncVault.supportsInterface` NatSpec: ERC-7540 operator, ERC-7575, async deposit, async redeem.

**Where.** `StableYieldAsyncVault.supportsInterface`.

---

## H. Numerical / structural

### H.1 — `int96` flow rate fits in Superfluid's range

`_flowRatePerUnit · totalUnits` is computed as `int96` for `distributeFlow`. **No explicit bounds check** — relies on operator-set `stableYieldRate` and pool size staying within Superfluid's accepted flow-rate range.

**Where.** `FundManagerBase` constructor and `FundManagerBase.setStableYieldRate` (`int96` cast of `_flowRatePerUnit`), `FundManagerBase._targetFlowRate` (`int96(int128(totalUnits))` product), `FundManagerBase._recalibrateFlow` (`distributeFlow`).

### H.2 — `uint128` unit math fits in Superfluid pool's range

Pool unit deltas are cast to `uint128`. `_toUnit(depositingAssets) = depositingAssets / RAW_PER_UNIT` and proportional redeem deltas are unchecked for u128 overflow/truncation.

**Where.** `FundManagerBase._toUnit` (`uint128` cast), `AsyncFundManager.settleEpoch`, `AsyncFundManager.onRequestRedeem` (proportional `delta`), `AsyncFundManager.canSettleEpoch` / `evaluateFunding` (`newTotalUnits`), `FundManagerBase.onShareTransfer` (`delta`).

### H.3 — Rate rounding: shares-on-deposit favor vault, assets-on-withdraw favor vault

| Path | Operation | Rounding |
|---|---|---|
| `_deposit` (assets → shares) | `assets * claimableShares / claimableAssets` | floor (default) |
| `_mintShares` (shares → assets) | `shares * claimableAssets / claimableShares` | **ceil** |
| `_redeem` (shares → assets) | `shares * claimableAssets / claimableShares` | floor |
| `_withdraw` (assets → shares) | `assets * claimableShares / claimableAssets` | **ceil** |

Both controller-facing entry points that take an `assets` argument round shares up; both share-argument paths round assets down. The vault never gives up dust in the controller's favor.

**Where.** `StableYieldAsyncVault._deposit`, `_mintShares`, `_redeem`, `_withdraw`.

### H.4 — `_rebalanceYieldAssets` rounds-up the upgrade amount

```
underlyingAmountToUpgrade = (uint256(deficit) / SCALING_FACTOR) + 1
```

The `+1` covers decimals clipping when underlying has fewer decimals than the super-token. Reverts with `INSUFFICIENT_UNUTILIZED_ASSETS` if the FM doesn't hold enough underlying to fund the upgrade.

**Where.** `AsyncFundManager._rebalanceYieldAssets` (override of the abstract `FundManagerBase._rebalanceYieldAssets`).

### H.5 — `evaluateFunding` `+1` on yield-asset deficit branch

When converting a yield-asset deficit (super-token, 18-dec) into an underlying top-up amount, the function adds `1` after dividing by `SCALING_FACTOR` for the same decimals-clipping reason as H.4.

**Where.** `AsyncFundManager.evaluateFunding`.

---

## I. Known gaps / `FIXME`s (for audit attention)

These are not invariants; they are properties the code claims (or implicitly relies upon) but does not robustly enforce. Listed here so they're not lost.

1. **Zero-NAV freezes deposits in the closing epoch.** See B.4. Code does not reject `_totalAssets == 0`; once `effectiveSupply + VIRTUAL_SHARES > ASSETS_PER_SHARE_SCALE` the resulting `epochRate` floors to `0` and causes div-by-zero on every subsequent depositor claim. Not currently in any documented invariant — recommend either an explicit revert in `onCloseEpoch` or an operator-side guard.
2. **No minimum era duration for yield-rate changes.** `FundManagerBase.setStableYieldRate` has no time gating (the former `FIXME: enforce minimum era duration` comment has been removed from the code, but nothing was added in its place). An operator can flip the rate every block; the only guard is the `rate × guaranteedFlowDuration ≤ YEAR × BP_DENOMINATOR` combination check (`INVALID_YIELD_DURATION_COMBINATION`).
3. **`evaluateYieldAssetsDeficit` lacks a buffer.** `FundManagerBase.evaluateYieldAssetsDeficit` (the former `FIXME` comment is gone from the code, the gap remains) has no slack above the bare `(_targetFlowRate + feeFlowRate) · guaranteedFlowDuration`, which can leave the FM repeatedly tripping the duration floor if streams drift.
