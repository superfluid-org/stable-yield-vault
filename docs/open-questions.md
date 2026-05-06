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
