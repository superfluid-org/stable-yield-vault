# Echidna smoke report — Sync vault (2026-06-05)

Harness: `test/echidna/EchidnaStableYieldSyncVault.sol` (`EchidnaStableYieldSyncVault`)
Config: `echidna.sync.yaml` · profile `FOUNDRY_PROFILE=echidna` · `make echidna-sync-smoke`
Campaign: assertion mode, 50,198 tx, seqLen 100, 3 senders, coverage 70,944 instructions.

## Result

| | count |
|---|---|
| Properties **passing** | 11 / 14 |
| Properties **falsified** | 3 / 14 |

Falsified: `redeem`, `withdraw`, `roundtrip_deposit_redeem`.

**Outcome after investigation:**

| Property | Verdict |
|---|---|
| `redeem`, `withdraw` | **Harness artifact — invalid as a production bug** (Issue 1); **fixed in harness** via a solvency-gated E.1 assert (`_assertNonNegativeYieldReserve`). Required the FM super-token to sit at `availableBalance < 0`, a state Superfluid sentinels prevent; the harness models no liquidator. |
| `roundtrip_deposit_redeem` | **Low / Informational** (Issue 2). Genuine 1-wei round-trip rounding leak under a capped external; independent of the Issue 1 solvency artifact. |

**Single common trigger:** every shrunk reproducer calls `external_set_liquidity_cap(tiny)` — `1`, `17`, or `2853` — before the failing exit. The mock external then reports `maxWithdraw(FM) = min(realPosition, cap) = cap` (a **compliant** ERC-4626 — `maxWithdraw` caps and `withdraw` reverts beyond it; see `test/mocks/MockERC4626.sol`). This is the **severe-but-non-terminal illiquidity** band: `ext.maxWithdraw(FM) > 0`, so the vault's terminal-impairment pause (`_isExternallyPaused()`, which triggers only at `maxWithdraw(FM) == 0`) does **not** engage, yet the external is effectively frozen.

The findings were reproduced deterministically by replaying the shrunk reproducers through the harness (all confirmed Panic `0x01`); see "Reproduction" at the end. **Pre-existing — not introduced by the 2026-06-05 echidna harness refactor/rename:** the sync vault/FM under test and the harness handlers/`_check` are unchanged; only the shared Superfluid bootstrap moved into `test/echidna/base/EchidnaVaultHarnessBase.sol`.

---

## Issue 1 — `redeem` / `withdraw` brick — **Investigated → harness artifact (invalid as a production bug)**

**Falsified properties:** `redeem`, `withdraw`.
**Initial read:** E.1 break (Medium). **After investigation: not production-reachable — a harness modelling gap.**

Both handlers bound the request to `max{Redeem,Withdraw}(actor)` and assert it then **never reverts** (invariant E.1, "`request ≤ max* ⇒ never bricks"`):

```solidity
try _vault.redeem(s, actor, actor) returns (uint256 assets) { ... }
catch { assert(false); /* E.1 violated */ }
```

**Confirmed revert (replay of reproducer `7174…` for redeem, `504…` for withdraw):** the inner exit reverts with **`GDA_INSUFFICIENT_BALANCE()`**, caught → `assert(false)` → Panic `0x01`. The trace shows the FM super-token `availableBalance` is deeply **negative** (≈ `-1.7e18`) at the failing point.

**Why it reverts — and why that matters.** The failing exits (`redeem(1,1)`, a small withdraw) **decrease** the holder's units → **decrease** the GDA flow → **release** buffer. A flow decrease cannot fail for lack of balance. The revert is the *other* Superfluid condition: **an account with `availableBalance < 0` is barred from updating any agreement** (the protocol forces it to be liquidated first). So the brick is a symptom of the FM super-token being in the **insolvent (`availableBalance < 0`)** region — not of the redeem itself being unaffordable.

**That region is not production-reachable for a live stream.** In production the FM cannot sustain `availableBalance < 0` with an active distribution:

- A diligent operator keeps ≥ `guaranteedFlowDuration` of runway via `ensureYieldFlowDuration`.
- If that lapses, **Superfluid sentinels liquidate the GDA distribution at the zero-crossing** — flow → 0, buffer consumed, balance settles to ~0. The reserve stops *at* 0, never deeply negative.

The harness models **no liquidator** and advances time with `warp_*` while the stream stays live, so it walks into the negative-`availableBalance` band that sentinels prevent. The `keepAlive` modifier + sub-1-day warp cap bound the *operator-diligence* gap; nothing models the *sentinel*.

**Empirical confirmation (boundary probe).** Draining the reserve under a tiny cap with a diligent operator, probing an in-bounds `redeem` at each step:

```
availableBalance = +2881e18 … +184e18   -> in-bounds redeem OK
availableBalance = -23e18               -> in-bounds redeem OK   (small tolerance: the redeem's own
                                                                  flow decrease releases buffer)
availableBalance = -230e18              -> in-bounds redeem BRICKS (GDA_INSUFFICIENT_BALANCE)
```

The in-bounds exit works throughout the entire solvent region and only bricks once the FM is **meaningfully insolvent** — a state production liquidates out of. **Conclusion: the captured redeem/withdraw E.1 break is a harness artifact (missing sentinel-liquidation actor), not a contract bug.** It is *not* a faithful instance of async Finding F-3 (F-3 is about the rebalance under-upgrading from a *clamped* balance on a *maintenance* op; this is about exiting from an *already-insolvent* account that production never reaches).

**Adjacent, genuinely-untested concern (track separately, not demonstrated here).** A *different* path the harness never exercises (because it never liquidates): reserve fully drains → sentinel liquidates the stream (flow = 0) → external is *still* illiquid → a holder redeems → the closing `_recalibrateFlow()` must now **restart** the flow (0 → positive), needing a fresh buffer the ~0 reserve can't fund → could revert at `availableBalance ≥ 0`. This is a flow **increase** (restart), not the decrease the harness hit, so it is a real possibility — but narrow and arguably not the vault's fault: with the external frozen, `totalManagedAssets ≈ maxWithdraw(FM) = cap`, so `maxRedeem` is already ~dust and the principal is trapped *in the external* regardless of the vault. Worst case is "a dust redeem reverts instead of paying dust." If we want certainty, it needs its **own** test that models the sentinel liquidation and then attempts the restart-redeem; it should not inherit this Issue's (now-invalid) evidence.

**Disposition.**
- **Issue 1 is invalid as a contract bug — no contract change.** The echidna evidence does not justify one.
- **FIXED in the harness (option b, landed).** `EchidnaStableYieldSyncVault._assertNonNegativeYieldReserve()` now gates the `redeem`/`withdraw`/`roundtrip` E.1 `assert(false)` on FM solvency: it reads `_usdcx.realtimeBalanceOfNow(FM).availableBalance` in the `catch` (failed op rolled back ⇒ the FM's going-in solvency) and only asserts E.1 when `availableBalance >= 0`. A revert from an already-insolvent FM (the missing-sentinel artifact) is tolerated; a revert while solvent is still a hard E.1 violation. Verified by replaying the two shrunk reproducers (`7174…` redeem, `504…` withdraw) through the harness — they no longer Panic — and confirming a solvent in-bounds exit still succeeds (the diagnostic test was not retained). (Option a — a full sentinel-liquidation actor — was considered heavier and would also have to resolve the restart path below; deferred.)
- **Separate, still-open follow-up (not blocking):** the post-liquidation flow-restart path above. Decide via its own test (model the sentinel, then attempt the restart-redeem) whether a solvency-aware exit recalibrate (skip / `setStableYieldRate(0)`-style close when the reserve can't fund the restart) or a widened pause threshold (engage below the stream requirement, not only at `maxWithdraw(FM) == 0`) is warranted.

---

## Issue 2 — deposit→redeem round-trip extracts 1 wei under a capped external — **Low / Informational**

**Falsified property:** `roundtrip_deposit_redeem`.

The handler deposits `amt`, immediately redeems the minted shares, and asserts the round-trip is not profitable:

```solidity
assert(assetsOut <= amt); // no value extracted on a round-trip
```

**Confirmed (replay of reproducer `4698…`):** with `amt = 118` the round-trip returns `assetsOut = 119` → `assert(119 <= 118)` → Panic `0x01`. (Trace: redeem `← [Return] 119` immediately preceding the panic.) The inner redeem does **not** revert here — this is a value/accounting asymmetry, **not** a brick.

**Root cause.** With the external capped, principal deposited into the external position lands **above the cap** and is invisible to NAV (`totalManagedAssets()` counts `ext.maxWithdraw(FM) = cap`, not the real position). The deposit therefore mints shares priced against the collapsed NAV while the redeem pays from the reserve-inclusive NAV; the `Ceil`/`Floor` rounding directions across the OZ virtual-shares conversion and the R-shares reserve slice leave a 1-unit gap in the redeemer's favour. The extracted wei is sourced from the reserve / other holders (dilution-scale).

**Severity.** 1 wei per round-trip, only in the pathological capped-external regime, and the attacker pays gas to extract it — economically irrational, so **informational**. Unlike Issue 1 this does **not** depend on the FM being insolvent (`availableBalance < 0`) — it is a pure NAV/rounding asymmetry and is production-reachable (an illiquid external alone suffices), so it stands as a (trivial) real finding rather than a harness artifact. It shares only the *trigger* with Issue 1 (collapsed NAV from a capped external) and the same underlying gap: the contract has no special handling when the deployed principal exceeds the externally-recoverable amount.

**Suggested directions:** the Issue 1 fixes (pause / solvency-awareness before NAV collapses this far) also remove this regime. If kept, tighten the round-trip rounding so `convertToAssets(convertToShares(x)) ≤ x` holds even when `maxWithdraw(FM) ≪ realPosition`.

---

## Reproduction

All three were replayed deterministically by deploying the harness in a Foundry test and issuing the shrunk reproducer call sequence (`echidna-corpus/sync/reproducers/`), e.g. reproducer `4698…`:

```solidity
EchidnaStableYieldSyncVault h = new EchidnaStableYieldSyncVault();
h.mint(0, 254264395948365610481382);
h.operator_set_duration(0);           // -> 1 day floor
h.operator_set_rate(5);               // 5 bps  (tiny rate -> tiny reserve target)
h.external_set_liquidity_cap(2853);   // severe, non-terminal illiquidity
h.warp_seconds(1509);
h.roundtrip_deposit_redeem(0, 118);   // returns 119 -> assert(assetsOut <= amt) fails
```

`redeem` (`7174…`, cap = 1) and `withdraw` (`504…`, cap = 17) follow the same shape and brick on `GDA_INSUFFICIENT_BALANCE()`. The Issue 1 verdict was reached with a second throwaway probe: drain the reserve under a tiny cap with a diligent operator, and probe an in-bounds `redeem` (in a rolled-back sub-call) at each step while logging `availableBalance` — the redeem only bricks once `availableBalance` is well below 0 (the table in Issue 1). Both diagnostic tests were not committed; the sequences here recreate them.

---

## Bottom line

11/14 invariants hold across 50k tx. All 3 falsifications share one trigger — a **compliant external whose withdrawal liquidity is throttled near zero but not to zero** (`external_set_liquidity_cap(tiny)`) — but they resolve very differently:

- **redeem / withdraw → harness artifact (invalid); fixed in harness.** The brick requires the FM super-token at `availableBalance < 0`, which Superfluid sentinels prevent (they liquidate the stream at the zero-crossing). The harness models no liquidator, so it explores a state production never sustains. Empirically (boundary probe) the in-bounds exit works throughout the entire solvent region and only bricks once `availableBalance` is well below 0. **No contract change is justified.** Fixed in the harness via a solvency-gated E.1 assert (`_assertNonNegativeYieldReserve`). A *separate, untested* path — post-liquidation flow-restart under a still-illiquid external — remains a possible (narrow) follow-up, to be decided by its own test, not by this run.
- **roundtrip → Low/Info (real).** Collapsed NAV (deposited principal invisible above the cap) lets a deposit→redeem round-trip extract 1 wei. Production-reachable but economically irrational.

None of the three is introduced by the harness refactor/rename.
