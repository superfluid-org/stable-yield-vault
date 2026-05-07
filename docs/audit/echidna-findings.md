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
