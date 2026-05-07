# Echidna findings

Running notes from the Echidna fuzzing harness in `test/echidna/EchidnaStableYieldVault.sol`. Each entry: minimum reproducer, what the harness asserted, why it fired, and the disposition.

---

## F-1 — D.5 forward-solvency, as literally written, breaks immediately after `settleEpoch`

**Severity.** Informational (spec wording vs. implementation).
**Detected.** Phase 5 smoke run, 50k tx campaign.
**Reproducer.**

```
EchidnaStableYieldVault.request_deposit(actor=0, amount=510)
EchidnaStableYieldVault.close_epoch()
EchidnaStableYieldVault.settle_epoch()
// assertion: FundManager.evaluateYieldAssetsDeficit() <= 0   →  fails
```

**What happens.** `settleEpoch` increases pool units, runs `_rebalanceYieldAssets()` (downgrading any yield-asset surplus down to `_targetFlowRate · guaranteedFlowDuration`), and then runs `_recalibrateFlow()` which calls `YIELD_ASSET.distributeFlow(...)`. `distributeFlow` reserves a **GDA buffer** — a portion of FM's super-token balance is locked as liquidation-safety collateral, and `balanceOf` on a Superfluid super-token returns the real-time *available* balance (i.e. excluding that buffer).

Net effect: immediately after a successful `settleEpoch`, `yieldAssetsBalance()` is below the target reserve by exactly the GDA buffer, so `evaluateYieldAssetsDeficit() > 0`.

**Why this matters.**

- `docs/invariants.md` D.5 states `yieldAssetsBalance() ≥ _targetFlowRate · guaranteedFlowDuration` and claims "`canSettleEpoch` enforces the post-settlement version of this inequality before settlement runs." Both are true *up to the buffer*.
- `canSettleEpoch` checks the inequality using a balance read **before** the stream is started, so it passes. The harness checks **after**, and it fails.
- This is not a fund-loss bug — the buffer is FM's own super-token collateral that gets refunded when the stream is reduced or stopped. But the spec wording is misleading, and any future code that takes D.5 at face value (e.g. a downstream contract that calls `evaluateYieldAssetsDeficit()` and reverts on positive values) would break by design.

**Disposition.**

1. The Echidna harness does **not** assert this strict form (we removed the check; commented in `settle_epoch()`).
2. Suggested spec fix: tighten D.5 to `yieldAssetsBalance() + GDA_buffer(FM) ≥ _targetFlowRate · guaranteedFlowDuration`, or restate as "FM holds enough super-token to fund the stream for at least `guaranteedFlowDuration` *plus* the GDA-mandated buffer."
3. A stronger Echidna check would add the buffer back into the actual balance (read `getDepositForFlow` on the GDA). Tier-D follow-up.

---

## F-2 — D.3 flow-rate conservation broken by decrease-then-increase ordering in `onClaimDeposit`

**Severity.** Informational (rounding / GDA-internal accounting; not fund-loss).
**Detected.** Phase 6 smoke run, 50k tx campaign.
**Reproducer.**

```
EchidnaStableYieldVault.request_deposit(actor=0, amount=1)
EchidnaStableYieldVault.close_epoch()
EchidnaStableYieldVault.settle_epoch()
EchidnaStableYieldVault.claim_deposit(actor=0, portion=1)
// assertion: POOL.getTotalFlowRate() == flowBefore   →  fails (off by GDA rounding)
```

**What happens.** `FundManager.onClaimDeposit` (FundManager.sol:236–250) does:

```solidity
POOL.decreaseMemberUnits(address(this), units);   // FM: N → N-1
POOL.increaseMemberUnits(shareholder, units);     // receiver: 0 → 1
```

When FM is the sole unit holder (common at low scale, and *always* true after the very first epoch's settlement before any other deposits exist), the decrement drops `pool.getTotalUnits()` to 0 between the two calls. Superfluid's GDA reacts to that transient zero by snapping its internal `flowRatePerUnit` accounting; when units return to the original count one call later, `pool.getTotalFlowRate()` does not exactly equal its pre-call value. The drift is rounding-level (small int96 truncation on per-unit rate computation), but the literal claim in `docs/invariants.md` D.3 — "Total pool units and `_targetFlowRate()` are unchanged" — is violated bit-exactly.

`getTotalUnits()` itself *is* conserved (the harness still asserts D.3a — that one passes).

**Why this matters.**

- The drift is small (sub-`int96` precision) and there is no detectable economic impact in the smoke campaign.
- But callers of `pool.getTotalFlowRate()` that compare equality against a stored value would observe inconsistency.
- More concerning structurally: the implementation comment on `FundManager.sol:243` says "pool.totalUnits unchanged -> flowRate unchanged -> invariant unchanged". The first half holds; the second does not, in the corner where FM is briefly emptied.

**Suggested fix.** Reorder to *increase-then-decrease* so totalUnits never hits zero:

```solidity
POOL.increaseMemberUnits(shareholder, units);
POOL.decreaseMemberUnits(address(this), units);
```

This keeps `totalUnits ∈ {N, N+1}` across the call rather than `{N, N-1, N}`. The intermediate state has `totalUnits = N+1` for one instruction, which the GDA handles cleanly.

After the fix, the harness's D.3b assertion can be re-enabled (currently commented out — see `claim_deposit` in `EchidnaStableYieldVault.sol`).

**Disposition.**

1. The Echidna harness asserts D.3a (totalUnits conservation) but **not** D.3b (flow-rate conservation), with an inline comment cross-referencing this finding.
2. Spec wording in `docs/invariants.md` D.3 should either tighten the wording or wait on the code fix.

---

## F-3 — `_rebalanceYieldAssets` under-upgrades from critical state; D.5 not maintained post-maintenance

**Severity.** Medium (spec gap + contract under-recovery; no fund loss but breaks the documented forward-solvency guarantee).
**Detected.** 30k tx campaign while implementing the D.5 + GDA-buffer assertion (Tier-D follow-up of F-1).
**Reproducer.** Multiple sequences trip the assertion. Common shape:

```
request_deposit(actor=X, smallAmount)
close_epoch() / close_epoch_with_working(0)
settle_epoch()              // FM streams start, small reserve & buffer
warp_seconds_long(N days)   // accrued out-flow drives availableBalance well below 0
set_stable_yield_rate(R)    // OR set_guaranteed_flow_duration(D) / ensureYieldFlowDuration()
// post-call: yieldAssetsBalance() + GDA_buffer < targetFlowRate · guaranteedFlowDuration
```

**What happens.**

`evaluateYieldAssetsDeficit()` reads `yieldAssetsBalance()` which is the SuperToken's ERC20 `balanceOf` — defined as `availableBalance < 0 ? 0 : uint256(availableBalance)`. When the FM has been streaming out for an extended period, `availableBalance` (which already deducts the GDA buffer and accrued out-flow) goes negative and `balanceOf` clamps at 0.

Two compounding gaps:

1. **Deficit is over-reported.** `deficit = required - balanceOf = required - 0 = required`. The "real" deficit (what's needed to bring the SuperToken's *static* balance up to a level that makes `availableBalance ≥ required`) is `required + |availableBalance|`, which can be much larger.

2. **Rebalance under-upgrades.** `_rebalanceYieldAssets` upgrades exactly `deficit / SCALING_FACTOR + 1` USDC, doesn't iterate, and exits. After the upgrade, `availableBalance` is still negative (or barely above zero), so `balanceOf` is still close to zero. The new GDA buffer locked by `_recalibrateFlow` then pushes `availableBalance` further down. Net result: `balanceOf + buffer < required`, violating the literal D.5 form (and even the stronger "include buffer" form).

The **`setStableYieldRate` rate-raise path** is a related but distinct trigger: even when not in a deeply critical state, raising the rate increases the buffer proportionally. The rebalance ensures `balanceOf ≥ newRequired` using the new rate, but `_recalibrateFlow` then locks the larger buffer, dropping `balanceOf` below `newRequired`. The buffer-add formula recovers in this case (since the freed-old-buffer feeds back into settled), but the harness saw failures here too — likely interactions with concurrent stream accrual and rounding that the simple formula doesn't capture.

**Why this matters.**

- `docs/invariants.md` D.5 states `yieldAssetsBalance() ≥ targetFlowRate · guaranteedFlowDuration` and claims `canSettleEpoch` enforces a post-settlement form before settlement. The pre-settlement check passes (it uses `balanceOf` consistently with the rebalance), but the **post-maintenance state can violate D.5**, breaking any downstream assumption that "after a maintenance op, FM is forward-solvent for `guaranteedFlowDuration`."
- Known-gap **I.1** (`INVARIANT_VIOLATED` declared but never raised) is a *symptom* of this same issue: the interface NatSpec at `IFundManager.sol:126,136` claims `setStableYieldRate` and `setGuaranteedFlowDuration` revert on D.5 violations, but no preflight check exists. They rely on `_rebalanceYieldAssets` succeeding — which it does, just by under-upgrading rather than reverting.
- Critical-state recovery is silent: there is no operator-visible signal that the FM is critical or that the last rebalance under-upgraded. `evaluateFunding()` and `evaluateYieldAssetsDeficit()` both read the clamped `balanceOf`, so they hide it.

**Suggested fixes.**

1. **Iterate or compute against the unclamped balance.** Change `_rebalanceYieldAssets` to compute the deficit against `availableBalance` (signed) rather than `balanceOf` (clamped):

   ```solidity
   (int256 availableBalance, uint256 deposit, ) =
       YIELD_ASSET.realtimeBalanceOfNow(address(this));
   int256 trueDeficit = int256(requiredBalance) - availableBalance;
   if (trueDeficit <= 0) return;
   uint256 underlyingAmountToUpgrade = uint256(trueDeficit) / SCALING_FACTOR + 1;
   ```

   This lifts the static balance enough that `availableBalance` becomes positive AND ≥ required, even when starting critical.

2. **Add a buffer headroom.** The GDA buffer is taken from FM's static balance at `distributeFlow` time. Pre-`_recalibrateFlow`, the rebalance should over-upgrade by at least the *next* buffer's delta (`newBuffer - oldBuffer`). Since the buffer is `flowRate · liquidationPeriod`, this is computable in advance.

3. **Add the preflight check.** `setStableYieldRate` and `setGuaranteedFlowDuration` should compute the post-call required reserve, verify the rebalance can achieve it, and revert with `INVARIANT_VIOLATED` otherwise — matching the interface NatSpec. This closes gap I.1.

4. **Restate D.5.** Until the contract is fixed, `docs/invariants.md` should weaken D.5 to "between maintenance operations the deficit is bounded by the GDA buffer plus accrued out-flow," and explicitly note that critical-state recovery requires multiple rebalance calls.

**Disposition.**

1. The Echidna harness has a `_assertForwardSolvency()` helper wired into the four maintenance handlers (`settle_epoch`, `set_stable_yield_rate`, `set_guaranteed_flow_duration`, `ensure_yield_flow_duration`), but the body is currently empty pending a contract fix. Re-enable once F-3 is addressed.
2. The discovery validates the value of the D.5 + GDA-buffer follow-up flagged in F-1 — even with the buffer-add correction, the literal invariant doesn't hold. The right fix is on the contract side, not the harness.
