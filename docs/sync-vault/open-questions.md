# Open Questions

Design and policy questions still open for the sync vault (`StableYieldSyncVault` +
`SyncFundManager`). Each is tagged:

- **[DECIDE]** — a policy question to resolve before it can be encoded or tested.
- **[FIX]** — a concrete code change that has been decided but not yet made.

---

## [DECIDE] Minimum deposit / dust shares

`_toUnit` floors underlying into pool units:

```solidity
units = uint128(underlyingAmount / RAW_PER_UNIT);   // RAW_PER_UNIT = 10 ** (underlyingDecimals − 6)
```

For an underlying with more than 6 decimals, a sub-`RAW_PER_UNIT` deposit mints shares but
0 units. The code already tolerates a zero-unit holder (`onWithdraw` and `onShareTransfer`
skip the unit step rather than reverting), so it never bricks — but such a holder owns
shares that accrue no stream.

For 6-decimal USDC (`RAW_PER_UNIT == 1`) this is moot. It only bites underlyings with more
than 6 decimals.

**Question.** Enforce a minimum deposit of `RAW_PER_UNIT`, or explicitly support sub-unit
share balances?

## [DECIDE] GDA buffer not counted in the reserve target

`evaluateYieldAssetsDeficit()` sizes the required reserve as
`targetFlowRate · guaranteedFlowDuration` (plus the fee leg) and ignores Superfluid's GDA
security deposit. So the forward-solvency inequality
(`yieldAssetsBalance() >= targetFlowRate · guaranteedFlowDuration`) can read as a small
deficit immediately after a successful `_recalibrateFlow()`, even though the missing amount
is locked as the GDA buffer, not lost. This only affects the cosmetic accuracy of the
reading, not liveness.

**Question.** Add the GDA buffer to the required-balance side of the deficit calculation?

## [DECIDE] No minimum era duration on `setStableYieldRate`

The operator can change `stableYieldRate` every block. There is no minimum era boundary.

### Approches : 
- Either add guard on the setter
- Or build an intermediary contract (that owns the FUND_OPERATOR_ROLE) and that build that custom logic that enfore the stable yield duration . 

**Question.** Enforce a minimum era duration (fixed era boundaries), or keep fully
discretionary real-time rate adjustment? (Same question as the async vault.)

## [DECIDE] Non-6-decimal underlying

`SCALING_FACTOR = 10 ** (18 − d)`, `RAW_PER_UNIT = 10 ** (d − 6)`, the hard-coded
`1e12 = SCALING_FACTOR · RAW_PER_UNIT`, and the share `_decimalsOffset() = 12` all target
the 6-decimal USDC deployment. The supported range is `[6, 18]`, but a non-6-decimal
underlying needs review:

- The `_decimalsOffset()` value (a bare `18 − d` would give `0` protection at an 18-decimal
  underlying — it must be floored).
- The 18-decimal edge of the scaling math.

**Question.** Decide the offset and scaling policy before deploying with a non-6-decimal
underlying.

## [DECIDE] Operator liveness — no permissionless backstop

The only reserve-poking entry point between user activity is the operator-gated
`ensureYieldFlowDuration()` (there is no permissionless `harvest()`). Per-op hooks keep the
stream solvent on any user activity, but during a quiet period the operator must call
`ensureYieldFlowDuration()` to keep the stream forward-solvent and the share-price drift
bounded.

**Question.** Is the loss of a permissionless liveness backstop acceptable for launch, or
should there be a thin permissionless wrapper around `_rebalanceYieldAssets()` so keepers
can poke without the operator role? Currently resolved in favour of the smaller surface.
