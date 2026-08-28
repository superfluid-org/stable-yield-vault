# Echidna smoke report — Async vault (2026-06-05)

> **Internal fuzzing report — not a third-party audit.** This document was produced in-house (AI-assisted review / fuzzing) as pre-audit preparation and is published for transparency. It is a point-in-time snapshot (2026-06-05); findings marked *Status* below have been reconciled against the current code, everything else may be stale (line numbers in particular). It has not been reviewed by an independent security firm. See [`SECURITY.md`](../../../SECURITY.md).

Harness: `test/echidna/EchidnaStableYieldAsyncVault.sol` (`EchidnaStableYieldAsyncVault`)
Config: `echidna.async.yaml` · profile `FOUNDRY_PROFILE=echidna` · `make echidna-async-smoke`
Campaign: assertion mode, 50,151 tx, seqLen 100, 3 senders, coverage 76,261 instructions.

## Result

| | count |
|---|---|
| Properties **passing** | 30 / 35 |
| Properties **falsified** | 5 / 35 |

Falsified: `settle_epoch`, `set_stable_yield_rate`, `set_guaranteed_flow_duration`, `ensure_yield_flow_duration`, `request_redeem`.

**None of these is a fund-loss bug.** Four are the same documented forward-solvency spec/recovery gap (Finding **F-3**); one is a GDA `int96` flow-rate rounding edge (same class as Finding **F-2**). Both are pre-existing and documented in [`echidna-findings.md`](./echidna-findings.md); neither is related to the 2026-06-05 echidna-harness refactor/rename (the harness logic — handlers, `_check`, `_assertForwardSolvency` — was not changed, only the shared bootstrap was extracted into `test/echidna/base/EchidnaVaultHarnessBase.sol`).

---

## Issue 1 — D.5 forward-solvency violated after a maintenance op (4 properties) — **Finding F-3**

**Falsified properties:** `settle_epoch`, `set_stable_yield_rate`, `set_guaranteed_flow_duration`, `ensure_yield_flow_duration`.

These four handlers all call the harness helper `_assertForwardSolvency()`:

```solidity
function _assertForwardSolvency() internal view {
    int256 deficit = _fundManager.evaluateYieldAssetsDeficit();
    if (deficit <= 0) return;
    (, uint256 buffer,) = _usdcx.realtimeBalanceOf(address(_fundManager), block.timestamp);
    assert(uint256(deficit) <= buffer);   // <-- fires
}
```

i.e. the assertion is the **buffer-inclusive** form of invariant D.5: after any maintenance op the FM must hold enough yield-asset reserve (plus the GDA-locked buffer) to fund the stream for `guaranteedFlowDuration`.

**Shrunk reproducers** (all share the shape "settle, then drive the reserve critical, then run a maintenance op"):

```
# ensure_yield_flow_duration  (reproducers/5333882635177484645)
request_deposit(1, 3.06e15) ; close_epoch ; settle_epoch ; claim_mint(1, …) ; ensure_yield_flow_duration

# set_guaranteed_flow_duration  (reproducers/5359491849420389886)
request_deposit(0, 18330) ; close_epoch ; settle_epoch ; claim_mint(0, …) ; set_guaranteed_flow_duration(0→1d)

# set_stable_yield_rate  (reproducers/7871375331781213863)
request_deposit(0, 6.4e22) ; close_epoch ; settle_epoch ; set_guaranteed_flow_duration(25588549) ;
claim_mint(0, …) ; warp_seconds(9929398) ; set_stable_yield_rate(1)

# settle_epoch  (reproducers/6098845703610694540)
request_deposit(0,159) ; close_epoch ; settle_epoch ; request_deposit(0,1) ; set_stable_yield_rate(1769) ;
claim_mint(0,318) ; warp_seconds(1623956) ; close_epoch ; settle_epoch
```

**Root cause (from `echidna-findings.md` F-3, Medium):**
`evaluateYieldAssetsDeficit()` measures the reserve via the super-token's ERC-20 `balanceOf`, which is `availableBalance < 0 ? 0 : availableBalance` — it **clamps at zero**. After the stream has been paying out for a while (the `warp_*` calls) the FM's `availableBalance` goes negative, so `balanceOf` reads 0 and the *reported* deficit is `required − 0 = required`, understating the *true* shortfall `required + |availableBalance|`. `_rebalanceYieldAssets()` then upgrades only `reportedDeficit / SCALING_FACTOR + 1`, does **not** iterate, and returns; the subsequent `_recalibrateFlow()` locks a fresh GDA buffer that pushes `availableBalance` down again. Net: `balanceOf + buffer < required` — D.5 broken right after the maintenance op.

The `set_stable_yield_rate` path is a related trigger: raising the rate raises the buffer proportionally; the rebalance satisfies the *new* required against the clamped balance, then `_recalibrateFlow` locks the larger buffer and drops back below target.

**Why it is not fund loss:** the GDA buffer is the FM's own super-token collateral, refunded when the stream is reduced/stopped. The break is a *spec-vs-implementation* gap: D.5 as literally written ("reserve ≥ targetFlow · duration") does not hold post-maintenance, and the interface NatSpec claiming `setStableYieldRate`/`setGuaranteedFlowDuration` revert on a D.5 violation (`INVARIANT_VIOLATED`, gap I.1) is not backed by a preflight check.

**Suggested fixes (per F-3):**
1. Compute the deficit against the **unclamped signed** `availableBalance` from `realtimeBalanceOfNow`, not the clamped `balanceOf`, so a single rebalance lifts the static balance enough that `availableBalance ≥ required`.
2. Over-upgrade by the next buffer delta (`newBuffer − oldBuffer`, computable as `flowRate · liquidationPeriod`) before `_recalibrateFlow`.
3. Add the missing preflight revert on the rate/duration setters (closes I.1).
4. Until fixed, restate D.5 as a buffer-bounded best-effort invariant.

---

## Issue 2 — `request_redeem` strict member-flow-rate decrease (1 property) — GDA `int96` rounding (F-2 class)

**Falsified property:** `request_redeem`.

**Shrunk reproducer** (`reproducers/4594016268558169170`) — note: **no `warp`, no maintenance op**, so this is *not* F-3:

```
request_deposit(2, 1777) ; close_epoch ; settle_epoch ; claim_deposit(2, …) ; request_redeem(2, 1)
```

The handler asserts, after a successful `requestRedeem` when the actor already held units:

```solidity
if (actorUnitsBefore > 0) {
    assert(pool.getUnits(actor) < actorUnitsBefore);            // units strictly drop
    assert(pool.getMemberFlowRate(actor) < actorFlowRateBefore); // <-- fires
}
```

**Root cause (inferred, high confidence):** the redeemer holds a tiny position (deposit of 1777 base units → a handful of GDA units), and `requestRedeem(1 share)` decreases their units by a `Ceil`-rounded slice. A GDA member's flow rate is `flowRatePerUnit · memberUnits` truncated to `int96`. When the position and the per-unit rate are small, removing one unit's worth does not move the *truncated* `int96` member flow rate — it reads equal before and after, so the strict `<` fails (it is really `==`). The **units** strictly drop (the first assert holds); only the *derived flow rate* fails to change at this granularity.

This is the same rounding class as documented Finding **F-2** ("D.3 flow-rate conservation broken by GDA `int96` truncation"): `getTotalUnits()`/`getUnits()` are conserved/monotone exactly, but `getMemberFlowRate()`/`getTotalFlowRate()` carry sub-`int96` drift. No economic impact; the harness assertion is simply stricter than the GDA's rounding guarantees on the derived flow rate.

**Disposition options:**
- Relax the harness assert to `<=` on the member flow rate (keep the strict `<` on units), or gate the flow-rate assert on the position being large enough to map to a non-truncating rate; **or**
- treat it as a documented informational finding alongside F-2 and leave the assert as a sentinel.

---

## Bottom line

The async harness is behaving as designed: 30/35 invariants hold across 50k tx, and the 5 falsifications are the **known, documented, non-fund-loss** findings F-3 (forward-solvency spec/recovery gap, ×4) and an F-2-class GDA rounding edge (×1). No new issue was introduced by the harness refactor/rename. The actionable contract work is F-3 fix #1–#3 (rebalance against the unclamped balance + setter preflight); everything else is spec-wording / harness-strictness.
