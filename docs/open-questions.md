# Open Questions

## Minimum Deposit / Zero-Unit Shares

The code does not currently enforce a minimum deposit or minimum claim amount relative to the FundManager's pool-unit granularity.

`FundManager._toUnit` floors underlying amounts into GDA pool units:

```solidity
units = uint128(underlyingAmount / RAW_PER_UNIT);
```

where:

```solidity
RAW_PER_UNIT = 10 ** (underlyingDecimals - 6)
```

For 6-decimal underlyings, `RAW_PER_UNIT == 1`, so every non-zero raw-atom amount maps to at least one unit. For underlyings with more than 6 decimals, amounts below `RAW_PER_UNIT` map to `0` units.

This creates a possible accounting mismatch:

1. A user can request and claim a deposit amount that mints non-zero vault shares.
2. If the claimed `depositAssets < RAW_PER_UNIT`, `FundManager.onClaimDeposit` transfers `0` GDA units to the receiver.
3. The receiver now owns shares but may receive no yield stream.
4. If the receiver later calls `requestRedeem`, `FundManager.onRequestRedeem` can revert with `BAD_REDEEM_ARGS()` because `POOL.getUnits(receiver) == 0`.

The same dust problem can also appear through partial deposit claims: even if the original settled deposit maps to non-zero units, claiming it in small pieces can cause each individual `onClaimDeposit` call to transfer `0` units, leaving units stranded on the FundManager.

Open policy question:

Should the vault enforce a minimum deposit / claim size of at least `RAW_PER_UNIT`, or should the system explicitly support share balances smaller than one GDA unit and define how those shares redeem and accrue yield?

## Zero-NAV Epoch With Existing Supply

`StableYieldAsyncVault.onCloseEpoch` does not explicitly reject `_totalAssets == 0`.

If `effectiveSupply == 0`, this is treated as the bootstrap case and the epoch rate is set to `ASSETS_PER_SHARE_SCALE` (`1e18`).

If `effectiveSupply > 0` and `_totalAssets == 0`, the epoch rate is set to `0`:

```solidity
uint256 epochRate =
    effectiveSupply == 0 ? ASSETS_PER_SHARE_SCALE : _totalAssets.mulDiv(ASSETS_PER_SHARE_SCALE, effectiveSupply);
```

That represents a total-loss epoch where existing shares are priced at zero assets. The current settlement code does not define clean semantics for this state when there are pending deposits. During `onSettleEpoch`, the vault tries to account for unclaimed deposit shares:

```solidity
_unclaimedDepositShares += _snapshot.depositingAssets.mulDiv(ASSETS_PER_SHARE_SCALE, _snapshot.rate);
```

If `_snapshot.rate == 0` and `_snapshot.depositingAssets > 0`, this division reverts, so the epoch cannot settle. This is an earlier failure than a later depositor claim; settlement itself gets stuck.

Open policy question:

Should `onCloseEpoch` explicitly reject `_totalAssets == 0` when `effectiveSupply > 0`, or should the protocol define total-loss settlement semantics that allow zero-rate epochs to settle without breaking pending deposits/redeems?

## Stable Yield Rate Era Cadence

The code does not currently enforce a minimum duration between stable-yield-rate updates.

`FundManager.setStableYieldRate` can be called by the fund operator at any time:

```solidity
function setStableYieldRate(uint256 newRate) external onlyRole(FUND_OPERATOR_ROLE)
```

The function immediately updates `stableYieldRate`, recomputes `_flowRatePerUnit`, rebalances yield assets, and recalibrates the GDA flow. There is no `lastRateUpdate`, no era start timestamp, and no minimum delay check.

This leaves the current "era" language underspecified. The docs describe `stableYieldRate` as the rate committed for the current era, but the implementation allows the operator to change it every block if rebalancing succeeds.

Open policy question:

Should `stableYieldRate` be constrained to fixed era boundaries / a minimum era duration, or is fully discretionary operator-controlled real-time rate adjustment intended?
