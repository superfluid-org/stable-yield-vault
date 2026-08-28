# Open Questions

Design and policy questions for the async vault (`StableYieldAsyncVault` +
`AsyncFundManager`). Each is tagged:

- **[DECIDE]** — a policy question still open.
- **[RESOLVED]** — settled (by a code change or an explicit decision); kept for the record.

---

## [RESOLVED] Minimum Deposit / Zero-Unit Shares

> **Resolved by the 6-decimal pin.** The vault constructor requires a 6-decimal underlying
> (`INVALID_CONFIGURATION` otherwise), so `RAW_PER_UNIT == 1`, every non-zero claim maps to
> at least one unit, and the partial-claim dust case below cannot occur.

The code does not currently enforce a minimum deposit or minimum claim amount relative to the FundManager's pool-unit granularity.

`FundManagerBase._toUnit` floors underlying amounts into GDA pool units:

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
2. If the claimed `depositAssets < RAW_PER_UNIT`, `AsyncFundManager.onClaimDeposit` transfers `0` GDA units to the receiver.
3. The receiver now owns shares but may receive no yield stream.
4. If the receiver later calls `requestRedeem`, `AsyncFundManager.onRequestRedeem` can revert with `BAD_REDEEM_ARGS()` because `POOL.getUnits(receiver) == 0`.

The same dust problem can also appear through partial deposit claims: even if the original settled deposit maps to non-zero units, claiming it in small pieces can cause each individual `onClaimDeposit` call to transfer `0` units, leaving units stranded on the FundManager.

Open policy question:

Should the vault enforce a minimum deposit / claim size of at least `RAW_PER_UNIT`, or should the system explicitly support share balances smaller than one GDA unit and define how those shares redeem and accrue yield?

## [DECIDE] Zero-NAV Epoch With Existing Supply

`StableYieldAsyncVault.onCloseEpoch` does not explicitly reject `_totalAssets == 0`.

The epoch rate is computed OZ-style with virtual shares:

```solidity
uint256 epochRate = (_totalAssets + 1).mulDiv(ASSETS_PER_SHARE_SCALE, effectiveSupply + VIRTUAL_SHARES); // VIRTUAL_SHARES = 1e12
```

With `effectiveSupply == 0` this is the bootstrap rate `ASSETS_PER_SHARE_SCALE / VIRTUAL_SHARES`. The `+ 1` keeps the numerator non-zero, but once `effectiveSupply + VIRTUAL_SHARES > ASSETS_PER_SHARE_SCALE` (i.e. more than ~1 USDC worth of shares outstanding) a total-loss epoch (`_totalAssets == 0`) still floors the rate to `0`.

That represents a total-loss epoch where existing shares are priced at zero assets. The current settlement code does not define clean semantics for this state when there are pending deposits. During `onSettleEpoch`, the vault tries to account for unclaimed deposit shares:

```solidity
_unclaimedDepositShares += _snapshot.depositingAssets.mulDiv(ASSETS_PER_SHARE_SCALE, _snapshot.rate);
```

If `_snapshot.rate == 0` and `_snapshot.depositingAssets > 0`, this division reverts, so the epoch cannot settle. This is an earlier failure than a later depositor claim; settlement itself gets stuck.

Open policy question:

Should `onCloseEpoch` explicitly reject `_totalAssets == 0` when `effectiveSupply > 0`, or should the protocol define total-loss settlement semantics that allow zero-rate epochs to settle without breaking pending deposits/redeems?

## [DECIDE] Stable Yield Rate Era Cadence

The code does not currently enforce a minimum duration between stable-yield-rate updates.

`FundManagerBase.setStableYieldRate` can be called by the fund operator at any time:

```solidity
function setStableYieldRate(uint256 newRate) external onlyRole(FUND_OPERATOR_ROLE)
```

The function immediately updates `stableYieldRate`, recomputes `_flowRatePerUnit`, rebalances yield assets, and recalibrates the GDA flow. There is no `lastRateUpdate`, no era start timestamp, and no minimum delay check.

This leaves the current "era" language underspecified. The docs describe `stableYieldRate` as the rate committed for the current era, but the implementation allows the operator to change it every block if rebalancing succeeds.

Open policy question:

Should `stableYieldRate` be constrained to fixed era boundaries / a minimum era duration, or is fully discretionary operator-controlled real-time rate adjustment intended?
