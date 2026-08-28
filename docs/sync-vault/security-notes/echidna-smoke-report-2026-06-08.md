# Echidna smoke report — Sync vault (2026-06-08)

> **Internal fuzzing report — not a third-party audit.** This document was produced in-house (AI-assisted review / fuzzing) as pre-audit preparation and is published for transparency. It is a point-in-time snapshot (2026-06-08); findings marked *Status* below have been reconciled against the current code, everything else may be stale (line numbers in particular). It has not been reviewed by an independent security firm. See [`SECURITY.md`](../../../SECURITY.md).

Harness: `test/echidna/EchidnaStableYieldSyncVault.sol` (`EchidnaStableYieldSyncVault`)
Config: `echidna.sync.yaml` · profile `FOUNDRY_PROFILE=echidna` · `make echidna-sync-smoke`
Campaign: assertion mode, `testLimit = 50,000`, `seqLen 100`, 4 workers, `maxTimeDelay 6h` / `maxBlockDelay 10`, coverage ~70,127 instructions, corpus seeded from `echidna-corpus/sync/` (3 prior reproducers + 10 coverage seqs).
Compiler `solc 0.8.34`, optimizer 200 runs. Slither pre-pass clean.

## Result

| | count |
|---|---|
| Properties **passing** | 13 / 14 |
| Properties **falsified** | 1 / 14 |

Falsified: `roundtrip_deposit_redeem`.

| Property | Verdict |
|---|---|
| `roundtrip_deposit_redeem` | **Low / Informational** (Issue 1). Genuine 1-wei round-trip rounding leak under a *severely-but-non-terminally* illiquid external. Production-reachable but economically irrational (gas ≫ 1 wei). **Unchanged from the 2026-06-05 run** — same byte-identical reproducer. |

**Headline vs. the previous (2026-06-05) run: the two `redeem` / `withdraw` falsifications are gone.** Both prior reproducers (`504371738350775040` withdraw, `7174676189070959709` redeem) were *loaded from the corpus and replayed this run without falsifying* (log: `Sequence replayed from corpus file …` with no `falsified!`). This directly confirms the harness-side fix that landed after 2026-06-05 — the solvency-gated E.1 assertion `_assertNonNegativeYieldReserve()` (harness lines 140/157/186/350) — correctly tolerates the missing-sentinel artifact (an exit reverting only when the FM super-token already sits at `availableBalance < 0`, a state Superfluid sentinels prevent in production) while still hard-asserting E.1 whenever the FM is solvent. Those two were never contract bugs; this run is the regression confirmation that the fix holds across 50k tx.

The single remaining falsification was reproduced deterministically (it replays from the loaded corpus reproducer on the first replay pass, before fuzzing even starts) and shrunk to the minimal 6-call sequence below.

---

## Issue 1 — deposit→redeem round-trip extracts 1 wei under a capped external — **Low / Informational**

**Falsified property:** `roundtrip_deposit_redeem`.
**Reproducer:** `4698428890981573501` (byte-identical to the 2026-06-05 report's Issue 2).

The handler deposits `amt`, immediately redeems the just-minted shares in the same tx (no warp, no external move between the legs), and asserts the round-trip is never profitable:

```solidity
assert(assetsOut <= amt); // no value extracted on a round-trip
```

**Shrunk call sequence (4 workers, deterministic):**

```solidity
EchidnaStableYieldSyncVault.mint(0, 254264395948365610481382); // Alice mints a large position
EchidnaStableYieldSyncVault.operator_set_duration(0);          // -> 1 day MIN floor
EchidnaStableYieldSyncVault.operator_set_rate(5);              // 5 bps (tiny rate -> tiny reserve target)
EchidnaStableYieldSyncVault.external_set_liquidity_cap(2853);  // severe, NON-terminal illiquidity
EchidnaStableYieldSyncVault.warp_seconds(1509);
EchidnaStableYieldSyncVault.roundtrip_deposit_redeem(0, 118);  // deposit 118, redeem -> returns 119
```

With `amt = 118` the round-trip returns `assetsOut = 119` → `assert(119 <= 118)` → Panic `0x01`. The inner redeem does **not** revert — this is a value/accounting asymmetry, **not** a brick.

**Root cause.** Every shrunk reproducer first calls `external_set_liquidity_cap(tiny)` — here `2853`. The mock external (a *compliant* ERC-4626: `maxWithdraw` caps and `withdraw` reverts beyond it — `test/mocks/MockERC4626.sol`) then reports `maxWithdraw(FM) = min(realPosition, cap) = cap`. This is the **severe-but-non-terminal illiquidity** band: `ext.maxWithdraw(FM) > 0`, so the vault's terminal-impairment pause (`_isExternallyPaused()`, which engages only at `maxWithdraw(FM) == 0`) does **not** fire, yet the external is effectively frozen.

In that band, principal deposited into the external position lands **above the cap** and is invisible to NAV — `FUND_MANAGER.totalManagedAssets()` counts `ext.maxWithdraw(FM) = cap`, not the real position. The deposit therefore mints shares priced against the *collapsed* NAV, while the redeem pays out from the reserve-inclusive NAV; the `Ceil`/`Floor` rounding directions across the OZ virtual-shares conversion (the hardcoded `_decimalsOffset() = 12`) and the shares-proportional reserve slice leave a 1-unit gap in the redeemer's favour. The extracted wei is sourced from the reserve / other holders (dilution-scale).

**Severity — Low / Informational.**
- Magnitude: **1 wei** per round-trip (6-dec USDC).
- Regime: only when the external is throttled to near-zero withdrawal liquidity *without* hitting the terminal-pause threshold — a pathological, transient state for a compliant interest-accrual external.
- Economics: the attacker pays gas to net 1 wei — strictly loss-making. Not an extraction vector.
- It does **not** depend on FM insolvency (`availableBalance < 0`), so unlike the (now-fixed) `redeem`/`withdraw` artifact it is production-reachable in principle — an illiquid external alone suffices — and stands as a (trivial) real finding rather than a harness artifact.

**Suggested directions (unchanged from prior run; not blocking).**
- Widening the pause threshold to engage when the deployed principal materially exceeds the externally-recoverable amount (not only at `maxWithdraw(FM) == 0`) would remove this regime entirely along with the adjacent post-liquidation flow-restart concern noted in the 2026-06-05 report.
- If the regime is kept, tighten the round-trip rounding so `convertToAssets(convertToShares(x)) ≤ x` holds even when `maxWithdraw(FM) ≪ realPosition`.
- Either way it is sub-economic and does not gate deployment to a compliant, non-manipulable external (the design's deployment requirement: monotonic, interest-accrual-priced external — Aave/Morpho/Compound-style).

---

## Invariants that held (13/14, across the full 50k-tx schedule)

All checked in `_check()` after every handler, plus the per-handler asserts:

- **Supply ledger** — `totalSupply() == ghostSupply` (supply moves only via mint/burn in deposit/withdraw/redeem).
- **INV-2 reserve-inclusive NAV** — `totalAssets() == ext.maxWithdraw(FM) + scaledYieldAssetsBalance() + USDC.balanceOf(FM)` (plain sum of recoverable balances; floating share, no clamp).
- **INV-B.1 no share over-issuance** — `convertToAssets(totalSupply()) <= totalManagedAssets()` (holds with floor-rounding even under impairment).
- **A.1 custody hazard** — no idle underlying ever rests in the vault or the FM (`USDC.balanceOf(vault) == 0`, `USDC.balanceOf(FM) == 0`); the vault never holds the super-token (`USDCx.balanceOf(vault) == 0`).
- **D.2 terminal impairment ⇒ full pause** — when `totalSupply() > 0 && ext.maxWithdraw(FM) == 0`, all four `max{Deposit,Mint,Withdraw,Redeem}` are forced to 0 (empty-vault bootstrap excluded).
- **B.2 pays exactly** — `withdraw`/`redeem` transfer exactly the OZ-quoted `assets` to the receiver.
- **C.1 units at deposit** — a non-dust deposit (`amt >= RAW_PER_UNIT`) strictly increases the receiver's GDA units.
- **INV-6 transfer conserves units** — a shareholder→shareholder `transfer` leaves `POOL.getTotalUnits()` unchanged.
- **E.1 no-brick (solvency-gated)** — an in-bounds `withdraw`/`redeem`/round-trip-redeem never reverts while the FM super-token is solvent (`availableBalance >= 0`). **This is the property whose two prior falsifications are now resolved.**
- **INV-4 ensure-flow capital-neutral** — `ensureYieldFlowDuration()` preserves the NAV identity.

---

## Notes on the run

- **Fuzzing converged early; the wall-clock tail was shrinking.** Worker 0 spent the bulk of the campaign shrinking the single `roundtrip` reproducer (each shrink step replays a full Superfluid framework deploy, hence slow). The pass/fail verdict is final and cannot change: a falsified test stays falsified, and the other 13 had exhausted their schedule. The campaign is gas-heavy by nature (full Superfluid bootstrap per sequence).
- **Operator-diligence modelling is load-bearing.** The `keepAlive` modifier (replenish before every op via `ensureYieldFlowDuration()`) plus the sub-1-day time-advance cap (`MAX_WARP = 6h` AND `maxTimeDelay = 6h`) encode design decision D.1. Without them a week-long warp would drain the stream to insolvency and produce false E.1 failures — see the config comment in `echidna.sync.yaml`.
- **No new findings.** The run surfaced exactly one falsification, and it is the same Low/Info rounding finding already documented and triaged on 2026-06-05.

## Bottom line

**13/14 invariants hold across the 50k-tx schedule.** The only falsification is the previously-known, sub-economic 1-wei round-trip rounding leak under a severely-but-non-terminally illiquid external (`roundtrip_deposit_redeem`, Low/Info) — production-reachable but loss-making to exploit, and not a deployment blocker for a compliant external. The two `redeem`/`withdraw` E.1 falsifications from the 2026-06-05 run are **resolved**: their corpus reproducers replay cleanly under the solvency-gated assertion, confirming the harness fix. No new issues, no contract change indicated by this run.
