# Operator & admin guide

Runbook for the two privileged roles on a Stable Yield Vault's FundManager. Everything here is
callable only by the address holding the role; there are no timelocks at the contract level, so
put both roles behind a multisig / timelock in any deployment holding third-party funds.

| Role | Who | Powers |
|---|---|---|
| `FUND_OPERATOR_ROLE` | Day-to-day bot / ops key | `setStableYieldRate`, `ensureYieldFlowDuration`; async: `closeEpoch`, `settleEpoch`, `give`, `take` |
| `DEFAULT_ADMIN_ROLE` | Governance | `setGuaranteedFlowDuration`, `emergencyWithdraw`, role management; sync vault `terminate()` |

Roles are OpenZeppelin `AccessControl` on the FundManager (`grantRole` / `revokeRole` /
`renounceRole` as usual). The vault itself has no roles — it checks the FM's.

## 1. The one invariant you are keeping

```
yieldAssetsBalance()  ≥  (yieldFlowRate + feeFlowRate) · guaranteedFlowDuration
```

The USDCx reserve must always cover the whole stream (holders' promised rate + the 1 % fee leg)
for at least `guaranteedFlowDuration` seconds ahead. If the reserve runs dry Superfluid
liquidates the stream — every holder's yield stops at once and the FM loses its GDA buffer.

Read it with `evaluateYieldAssetsDeficit()`: positive = under-reserved (by that many 18-dec
atoms), negative = surplus. Both families top the reserve up automatically inside every user
operation; **between user operations only you do**, via `ensureYieldFlowDuration()`.

## 2. Parameters

### `setStableYieldRate(uint256 bps)` — operator

The promised annual rate, basis points (`300` = 3 %). Takes effect immediately: recomputes the
per-unit flow, rebalances the reserve, recalibrates the GDA flow. Constraints:

- `rate × guaranteedFlowDuration ≤ YEAR × 10_000` (`INVALID_YIELD_DURATION_COMBINATION`).
- Raising the rate raises the required reserve *now* — the call pulls the difference from the
  yield source (sync: from Morpho; async: from `unutilizedAssetsBalance()`, reverting
  `INSUFFICIENT_UNUTILIZED_ASSETS` if there isn't enough — `give` first).
- `setStableYieldRate(0)` always succeeds (a zero flow needs no reserve). It is the emergency
  lever under impairment.
- There is no minimum era duration on-chain (open question in both families). Keep a policy:
  announce rate changes, change at fixed boundaries.

### `setGuaranteedFlowDuration(uint256 seconds)` — admin

The forward-solvency horizon. Floor `MIN_GUARANTEED_FLOW_DURATION = 1 days`
(`DURATION_BELOW_FLOOR`); same product guard as above. Longer = more principal parked as USDCx
(not earning in the yield source) but more tolerance for operator downtime. Deployed values: 2
days (Base sync), 7 days (Polygon async).

### `ensureYieldFlowDuration()` — operator

Idempotent "make it right" call: rebalances the reserve to the target (pull deficit / trim
surplus) and restarts the GDA flow if it was liquidated. **Call it on a schedule** — at least
once per `guaranteedFlowDuration / 2`, and after any incident. It is cheap when nothing is
needed (no external calls when already solvent).

## 3. Sync vault cadence

The sync FM is self-sourcing: every `deposit` / `withdraw` rebalances from the Morpho position,
so during active use you have nothing to do. Your loop:

1. **Cron `ensureYieldFlowDuration()`** every few hours (well inside `guaranteedFlowDuration`).
2. **Watch** `evaluateYieldAssetsDeficit()`, `externalPositionValue()`, the share price
   (`convertToAssets(1e18)`), and Morpho's gates for the FM (`canDepositExternal()`,
   `canWithdrawExternal()`).
3. **Rate policy.** Keep `stableYieldRate` below Morpho's realised APY. If Morpho earns less than
   promised, the difference is taken from principal and the share price declines — lower the
   rate.

Situations:

| Symptom | Meaning | Action |
|---|---|---|
| `maxDeposit == 0`, not terminated | Morpho deposit gates block the FM (`canDepositExternal() == false`) | Wait / talk to the curator; withdrawals still work |
| `maxWithdraw == 0` for everyone | **External pause**: position value is 0 (total loss) or Morpho exit gates block the FM | Deposits and withdrawals are frozen; the stream keeps paying from the reserve until it drains. Lower the rate (`setStableYieldRate(0)` if needed) to preserve the reserve; resolve the gate |
| A withdrawal reverts inside Morpho although within `maxWithdraw` | Morpho instant liquidity < requested (no view for it) | `forceDeallocate` on the Morpho side / wait for liquidity; retry |
| Rebalance pull reverts with an Aave "dust" error | Pull below `MIN_EXTERNAL_PULL` (10 atoms) is skipped by design; a larger pull failing means the Morpho/Aave leg is stuck | Same as above |
| Share price drifting below entry | Promised rate > realised Morpho yield | Lower the rate |

`terminate()` (admin, on the vault) permanently closes deposits and leaves withdrawals open —
the orderly wind-down switch. It cannot be undone.

## 4. Async vault cadence — the epoch lifecycle

The async FM has no yield source of its own: **you** deploy capital off-chain with `take` and
return it with `give`, and you report its value at each epoch close.

```
requests accumulate ──► closeEpoch(workingAssets) ──► canSettleEpoch()? ──► settleEpoch() ──► users claim
      (epoch N)              snapshot + rate           preconditions         netting + units
```

1. **Capital management.** `take(amount)` moves free underlying (`unutilizedAssetsBalance()`)
   from the FM to the operator; `give(amount)` returns it. Neither is gated by the lifecycle or
   by solvency — sequencing them correctly is your responsibility. Do not `take` between
   `closeEpoch` and `settleEpoch`.
2. **`closeEpoch(workingAssets)`** — `workingAssets` is the current value of everything you
   took (principal + off-chain yield). The vault snapshots pending deposits/redeems and locks
   the epoch rate from `NAV = workingAssets + unutilizedAssetsBalance() + scaledYieldAssetsBalance()`.
   From now until settlement new requests revert `EPOCH_SETTLEMENT_IN_PROGRESS`, so settle
   promptly. **This number sets the price for every request in the epoch** — it is the trust
   point of the design; report honestly and keep an off-chain audit trail.
3. **`canSettleEpoch()`** → `(bool ok, string reason, Snapshot snap)`. Typical reasons: the FM
   lacks free underlying to pay net redemptions (→ `give`), or the post-settlement reserve would
   not cover `guaranteedFlowDuration` (→ `give` more, or lower the rate). `evaluateFunding()`
   returns how much underlying the FM is short (positive) or long (negative) for settlement.
4. **`settleEpoch()`** — nets deposits against redeems, moves the surplus/deficit between vault
   and FM, grants the epoch's pool units to the FM (they transfer to depositors when they claim),
   rebalances the reserve and recalibrates the flow. Reverts
   `SETTLEMENT_PRECONDITIONS_NOT_MET(reason)` if step 3 fails.
5. **Between epochs** — `ensureYieldFlowDuration()` on a cron, exactly as for the sync vault.

Pitfalls:

- A zero-NAV close with shares outstanding locks a rate of 0 and settlement of pending deposits
  then reverts (division by zero) — see `async-vault/open-questions.md`. Never report
  `workingAssets` such that NAV is 0 while supply > 0.
- Units are granted at claim, so a depositor who never claims never streams — the FM holds their
  units and the reserve target includes them. Encourage claiming (the macro can do it gaslessly).
- Redeemers lose their stream at **request** time (units are decreased immediately), not at
  claim.

## 5. `emergencyWithdraw(token, amount)` — admin

Transfers `amount` of *any* ERC-20 the FM holds to the immutable `TREASURY`. No accounting
hook: NAV is a live balance read, so pulling the USDCx reserve or (sync) the Morpho shares drops
`totalAssets` for every holder and, in the sync vault, can trip the external pause. It exists to
rescue stray tokens and for last-resort incident response. Treat any use as a public,
governance-level event.

## 6. Monitoring checklist

- `evaluateYieldAssetsDeficit() ≤ 0` (alert if positive for more than a few minutes).
- GDA flow is live: `YIELD_ASSET.getFlowRate`/pool total flow > 0 whenever `getTotalUnits() > 0`
  (a liquidated stream is the failure mode; `ensureYieldFlowDuration()` restarts it).
- Sync: `canDepositExternal()`, `canWithdrawExternal()`, `externalPositionValue()` vs. last
  reading, share price vs. entry.
- Async: `getSnapshot().epoch != 0` for longer than your settlement SLA; `canSettleEpoch()`.
- Events to index: `StableYieldRateChanged`, `GuaranteedFlowDurationChanged`,
  `YieldAssetsRebalanced`, `PoolFlowUpdated`, `EmergencyWithdraw`, `Terminated`, `EpochClosed`,
  `EpochSettled`, `Gave`, `Took`.
