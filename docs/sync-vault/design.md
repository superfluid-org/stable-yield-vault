# Stable Yield Sync Vault — Design

Status: **locked** (brainstormed 2026-05-18; **revised 2026-05-19 — async-symmetric pivot**; **revised 2026-05-21 — self-funded stream pivot**; **revised 2026-05-22 — unified rebalance primitive, `harvest()` dropped**; **revised 2026-05-26 — NAV clamp / `trackedPrincipal` dropped, floating share**; **revised 2026-05-27 — terminal-impairment full pause; guarded-recalibrate dropped**; implementation in progress)

A synchronous ERC-4626 sibling of `StableYieldAsyncVault`. Users deposit/withdraw
instantly; principal is routed into an external ERC-4626 (Morpho, Beefy, …); a
**stable** yield is streamed to depositors via the same Superfluid GDA engine the
async vault uses. The external vault replaces the async vault's manual off-chain
"working assets" leg.

---

## ⚠️ Revision 2026-05-27 — terminal external impairment ⇒ full pause (guarded recalibrate dropped)

The earlier sketch (Revision 2026-05-22, row θ) said the per-op/setter
`_recalibrateFlow()` calls would gain an `evaluateYieldAssetsDeficit() <= 0`
guard so they short-circuit at terminal external impairment. That guard was
**never implemented** and is now **dropped**. Terminal external impairment is
instead handled one level up, at the vault's `max*` layer.

**Policy.** Terminal external impairment is defined as
`EXTERNAL_VAULT.maxWithdraw(FM) == 0` *while the FM holds an external position*.
In that state the vault is **fully paused**: `maxDeposit = maxMint = maxWithdraw
= maxRedeem = 0` (`StableYieldSyncVault._isExternallyPaused()`), so OZ reverts
every entrypoint with `ERC4626ExceededMax*`. The empty-position bootstrap
(`maxWithdraw(FM) == 0` only because nothing is deployed yet) is excluded so the
first deposit still works.

| Aspect | Decision (2026-05-27) | Rationale |
|---|---|---|
| Deposits under terminal impairment | **Blocked** (`maxDeposit/maxMint = 0`). | Never route a user into a vault they cannot withdraw from; depositing into a dead external position only traps fresh principal. The external's own `maxDeposit` can be `>0` on a one-way ("withdraws frozen, deposits open") vault, so the gate is explicit, not inherited. |
| Withdrawals under terminal impairment | **Blocked** (`maxWithdraw/maxRedeem = 0`). | The surviving super-token reserve is reserved for the **yield stream** (holders receive it as shareholders), not a first-come reserve grab; and `maxWithdraw(FM) == 0` may be a temporary freeze, so we don't let holders burn shares to drain the reserve. |
| Stream during the pause | **Keeps paying** from the reserve; winds down by natural Superfluid liquidation when the reserve is exhausted. | No special handling; the reserve cannot be topped up while the external is frozen, so the flow stops on its own. |
| `_recalibrateFlow()` guards | **None.** The user hooks (`onDeposit`/`onWithdraw`) can't run while paused, so the drained-reserve recalibrate-revert is unreachable. Operator setters (`setStableYieldRate(>0)`, `ensureYieldFlowDuration`) are **allowed to revert** under terminal impairment — accepted, the operator is knowledgeable. `setStableYieldRate(0)` always works (recalibrating to a zero flow is a *close*, no GDA buffer needed) — the operator's bleed-stopping lever. |
| Permanent loss | **No exit hatch.** `maxWithdraw(FM) == 0` does not distinguish a permanent loss from a temporary freeze; both pause. If permanent, the remaining reserve simply streams out to holders (accepted, unlikely tail). |

Scope note: this analysis explicitly **excludes** the no-Superfluid-liquidator,
prolonged-insolvency scenario (assumed a sentinel keeps the account from sitting
deeply insolvent, and the operator keeps the reserve funded via
`ensureYieldFlowDuration()` in normal operation, so the reserve only drains
under genuine terminal impairment). Row θ of Revision 2026-05-22 is **superseded
on every point that touches the guarded recalibrate**.

---

## ⚠️ Revision 2026-05-26 — NAV clamp dropped (floating share)

The `min(trackedPrincipal, …)` NAV clamp and the `trackedPrincipal` counter are
**removed entirely**. The earlier model pinned the share to ≈1:1 and held the
external surplus aside as a protocol-owned, never-distributed solvency **buffer**
(excluded from share price) — a deliberate "users get *exactly* the promised
rate; the protocol retains the excess as a loss cushion" product. We are instead
going for a **floating share that tracks the external vault's real performance**:
a holder's total return is the external yield, delivered as the streamed promised
rate **plus** share-price appreciation for the excess (`external − promised`).
The two are **not** double-counted — the stream is funded by pulling from the
external position, so it lowers `maxWithdraw(FM)` by exactly the streamed amount
and the appreciation is the residual.

| # | Pre-2026-05-26 (clamp) | Revised 2026-05-26 (floating) |
|---|---|---|
| I | `totalAssets = min(trackedPrincipal, ext.maxWithdraw(FM) + scaledReserve + rawUnderlying)`. Surplus above `trackedPrincipal` excluded from share price (protocol-owned buffer); share ≈1:1. | **`totalAssets = ext.maxWithdraw(FM) + scaledReserve + rawUnderlying`** — plain sum of recoverable balances, no clamp. The external surplus is **included** and accrues to holders as share appreciation. Share floats. |
| II | `trackedPrincipal` counter: `+= assets` on deposit, `−= trackedPrincipal·sharesBurned/supplyBeforeBurn` (floor) on withdraw. Underpinned the clamp + the V/P-invariant on impaired exits. | **Removed.** OZ ERC-4626 proportional accounting handles both legs: deposit is NAV-neutral (`shares = assets·supply/NAV`), withdraw is NAV-pro-rata (`shares·NAV/supply`), so the no-inter-holder-value-transfer property the decrement enforced now holds automatically. |
| III | Loss-absorption: the accumulated buffer absorbs external underperformance first; the share is impaired only once the buffer is exhausted. "Stable" = total return capped at the promised rate. | **No accumulated cushion.** NAV is real recoverable value, so external underperformance reflects **immediately** in the share price; the holder's total return converges to the real external yield. "Stable" now describes only the **streamed component** (a smooth floor), not the total return. |
| IV | Donation resistance came from the clamp: super-token / raw-underlying donations above `trackedPrincipal` were absorbed, leaving share price unchanged. | **Clamp no longer resists donations.** Under a floating share a donation just raises NAV → raises price for existing holders → an irrational gift, not an attack. The only genuine residual is the classic **first-deposit inflation attack**, mitigated by OZ virtual shares (`_decimalsOffset()` hardcoded to `12`, implemented 2026-05-27). See §Security. |

Decisions **1, 2, 5, 10** are revised again; **the protocol-owned "buffer"
concept (decision 2 / Invariant 3) is retired** — there is no excluded slice.
Invariants **1, 2** are rewritten (principal accounting removed; exits are
OZ-pro-rata) and **3** is retired. The historical revision sections below
(2026-05-19/21/22) are kept as the design journey but are **superseded on every
point that touches the clamp, `trackedPrincipal`, or the buffer**.

---

## ⚠️ Revision 2026-05-22 — unified rebalance primitive, `harvest()` dropped

The 2026-05-21 revision left two near-duplicate reserve-management entrypoints
in the sync FM (`harvest()` permissionless + `ensureYieldFlowDuration()`
operator-only) and a separate deficit-only helper (`_replenishReserveFromExternal()`)
called from the per-op hooks. After lifting `_rebalanceYieldAssets()` to a
family-specific override, all three converge into a single primitive:

| # | 2026-05-21 behaviour | Revised 2026-05-22 behaviour |
|---|---|---|
| ε | `_rebalanceYieldAssets()` lived on `FundManagerBase` (async-flavoured: upgrade from `unutilizedAssetsBalance()` or revert with `INSUFFICIENT_UNUTILIZED_ASSETS`). Sync inherited the async semantics, which broke `setStableYieldRate` / `ensureYieldFlowDuration` under impairment (sync FM holds 0 unutilized at rest — Inv. 7). | **`_rebalanceYieldAssets()` is now `abstract` on `FundManagerBase`** (declaration only). `AsyncFundManager` keeps the original body verbatim. **`SyncFundManager` overrides** with a self-sourcing impl: pull `min(deficit, EXTERNAL_VAULT.maxWithdraw(this))` from external when `deficit > 0`; downgrade + redeposit excess into external when `deficit < 0`. The `INSUFFICIENT_UNUTILIZED_ASSETS` error symbol moved from `IFundManagerBase` to `IAsyncFundManager` (it is now async-only). |
| ζ | `harvest()` (permissionless, `nonReentrant`) and `ensureYieldFlowDuration()` (FUND_OPERATOR_ROLE) both wrap the same internal logic. `_replenishReserveFromExternal()` is the deficit-only half called from `onDeposit`, `onWithdraw`, and `harvest()`. The `Harvested(deficit, pulledFromExternal)` event is the harvest-specific observability. | **`harvest()` is removed.** `ensureYieldFlowDuration()` (inherited from base, `FUND_OPERATOR_ROLE`) is the sole reserve-poking entrypoint between user activity. `_replenishReserveFromExternal()` is removed; per-op hooks and the operator setter all call `_rebalanceYieldAssets()` directly. The `Harvested` event is dropped. Tradeoff: the sync vault loses the permissionless liveness backstop — keepers cannot poke without holding the operator role. Per-op hooks still keep the stream solvent on any user activity; the operator must call `ensureYieldFlowDuration()` to cover periods of inactivity. |
| η | `onWithdraw`: freed reserve excess pays the redeemer's reserve slice via `min(freedExcess, redeemingAssets)`. Residual `freedExcess − redeemingAssets` (when positive) stays in the reserve as above-target slack — per-op trim was deliberately avoided. | **Residual freed excess is trimmed back to external.** A second `_rebalanceYieldAssets()` call at the end of `onWithdraw` (before the `trackedPrincipal` decrement) downgrades any residual super-token and redeposits the underlying into the external vault. The reserve returns to target after every op; Inv. 7 holds (no raw underlying at rest). |
| θ | Base `setStableYieldRate` and `ensureYieldFlowDuration` invoked `_recalibrateFlow()` after the rebalance — `setStableYieldRate` unconditionally, `ensureYieldFlowDuration` only on a stalled-flow + units-out check. Both would revert at terminal external impairment in the sync family (residual positive deficit after best-effort rebalance + Superfluid GDA buffer requirement on `distributeFlow`). | ~~Both base callers gain a `evaluateYieldAssetsDeficit() <= 0` guard.~~ **SUPERSEDED 2026-05-27 — never implemented.** The guarded-recalibrate approach was dropped in favour of a **vault-level full pause** under terminal external impairment (see Revision 2026-05-27). No `_recalibrateFlow()` callsite is guarded; the user hooks can't run while paused, and the operator setters are allowed to revert under terminal impairment. |

Decisions **2, 6, 8** are refined again; decision **4** clarified (per-op trim is
now the rule, not the exception). Invariants **3** and **5** rewritten;
invariant **7** unchanged. The `Harvested` event and the `harvest-flow.md` flow
document are deleted (the operator-permissioned `ensureYieldFlowDuration()` is
documented inline in the contracts section below).

---

## ⚠️ Revision 2026-05-21 — self-funded stream (supersedes the operator-backstop model)

The 2026-05-19 revision still inherited a "stream sustained only from harvested
external surplus" rule from the original model: when the external vault
under-earned the promised rate the stream stalled, recovery routed through an
operator `fundReserve` injection (async-parity trust model). That hybrid is
dropped:

| # | 2026-05-19 behaviour | Revised 2026-05-21 behaviour |
|---|---|---|
| α | `_replenishReserveFromBuffer()` capped at `EXTERNAL_VAULT.maxWithdraw(FM) − trackedPrincipal` (surplus only). When the surplus is exhausted, the deficit cannot be cleared, the stream stalls, and recovery is operator-driven via `fundReserve` (or `setStableYieldRate`). | **`_replenishReserveFromBuffer()` pulls `min(deficit, EXTERNAL_VAULT.maxWithdraw(FM))` — uncapped.** Under impairment the replenisher eats into the principal-backing slice; the NAV clamp (`min(trackedPrincipal, ext + reserve)`) inverts, share NAV ticks down honestly. The stream only stalls in the terminal limit (`maxWithdraw(FM) == 0`). |
| β | `fundReserve(amount)` (`FUND_OPERATOR_ROLE`) is the async-parity recovery channel: operator injects underlying, next `harvest()`/`ensureYieldFlowDuration()` upgrades it into the reserve. | **Removed.** Async needed it because `give`/`take` move principal off-chain to opaque venues the contract cannot pull back; sync has programmatic `EXTERNAL_VAULT` access and is its own backstop. The operator's only sustainability lever is `setStableYieldRate`. Share-price-below-par is the canonical impairment signal (4626-native). |
| γ | `onDeposit` has a "deposit + buffer can't clear a pre-existing global deficit → stall" degraded-fallback branch (decision 8). | **Removed.** The uncapped replenisher always sources the deficit from the external position; the stall branch is unreachable in the non-terminal regime. Pre-funding the residual incoming-deposit slice still applies — it just no longer needs to coexist with a stall fallback. |

Decisions **4, 5, 8, 11** are refined again; decision **2** ("buffer
non-extracted") is *revised* — the buffer is fully extractable under impairment.
Invariants **3** and **5** are rewritten accordingly.

---

## ⚠️ Revision 2026-05-19 — async-symmetric refactor (supersedes the original locked model)

The original sync model (the table/invariants frozen on 2026-05-18) made the
**vault** the principal custodian, kept the share a hard 1:1 principal receipt,
and funded the stream *only* from harvested external surplus (never from
principal). Three asymmetries with the async family drove this revision; all
three are now resolved by converging the sync economic model onto the async one:

| # | Original sync behaviour | Revised behaviour (this document) |
|---|---|---|
| A | Vault holds the external-vault shares; vault does the external deposit/withdraw; vault owns `trackedPrincipal`, `totalAssets`, harvest surplus extraction. | **The FundManager is the sole capital custodian and NAV authority.** It holds the external-vault shares *and* the super-token reserve, owns `trackedPrincipal`, and computes NAV. The vault is a thin ERC-4626 share/accounting face that proxies `totalAssets`/`max*` to FM views — exactly the async split. |
| B | `harvest()` split across vault (surplus extraction) and FM (`harvestRebalance`). | **`harvest()` is a single permissionless `FundManager` entrypoint** with no vault involvement (enabled by A) — the direct analog of the async FM-entry `settleEpoch`. |
| C | Stream funded only from harvested external surplus; never draws principal. A fresh deposit grants units but the stream only *starts* once the reserve is independently funded (the first deposit could not stream at all until a later funded harvest / operator top-up). | **The stream is pre-funded from each deposit**, async-style: on deposit the FM first replenishes the reserve from the external buffer, then upgrades a slice of the incoming underlying to cover any residual `guaranteedFlowDuration` deficit, deposits the remainder into the external vault, and recalibrates — so the stream starts at deposit time, including the very first deposit. `totalAssets` now **includes the reserve**, so the deposit is NAV-neutral at entry and the share stays ≈1:1 while external yield ≥ the promised rate (honest pass-through otherwise). |
| D | n/a | **Forward solvency is maintained on every op, not only via the keeper `harvest()`.** A best-effort, deficit-gated `_replenishReserveFromBuffer()` runs at the start of every deposit and withdraw (no external calls when already solvent — the common case; capped at `EXTERNAL_VAULT.maxWithdraw(FM)` so it can never brick a user op). On redeem the reserve slice is funded by the **recalibration-freed reserve excess** (decreasing the redeemer's units lowers the required reserve), not by an NAV-pro-rata downgrade. |

Open decisions resolved 2026-05-19: reserve-inclusive NAV uses the **raw**
super-token balance (matches async; the donation surface is accepted, see
§Security); redeem is **async-faithful** via the recalibration-freed-excess
mechanism (decision 5). Decisions **1, 2, 4, 5** are revised; **6, 8, 10** are
refined; a new custody decision **11** is added; **3, 7, 9** are unchanged.

---

## Core principle

> **Principal is custodied by the FundManager (deployed into an external
> ERC-4626) and tracked by ERC-4626 shares. A stable yield is delivered
> out-of-band as a Superfluid stream at an operator-committed rate, pre-funded
> from each deposit into the FM's super-token reserve and continuously
> replenished from the external position. The share floats with the external
> vault's real performance: a holder's total return is the external yield,
> split into the streamed promised rate plus share-price appreciation for the
> excess (`external − promised`).**

NAV is the FM's recoverable value from all sources — external position +
super-token reserve + (transient) raw underlying — with **no clamp**. A deposit
only changes the *form* of the FM's assets (external-vault shares ↔
super-token), so it is NAV-neutral at entry. Thereafter the share price moves
with the external vault: while it earns above the promised rate the share
appreciates by the difference; while it earns below, the share declines (honest,
immediate pass-through). This is the async vault's FM-custody + super-token
reserve shape **minus the epoch lifecycle and minus the NAV clamp** — the sync
share is a standard floating ERC-4626 share, not a forward-priced ≈1:1 receipt.

Consequences:

- The share is a **floating** ERC-4626 share, priced
  `totalManagedAssets() / totalSupply` (OZ standard, with a virtual-shares
  offset). It is *not* pegged. It ticks slightly as the stream drains the
  reserve between rebalances and tracks the external vault's real NAV otherwise.
- A holder's **total return decomposes** as: the streamed component (the
  promised `stableYieldRate`, smooth, in super-token) **plus** share
  appreciation (`external yield − promised rate`, booked into the share price).
  The sum is the external vault's real yield — **single-counted**, because the
  stream is funded by pulling from the external position (every streamed unit
  lowers `maxWithdraw(FM)` by that unit; the appreciation is the residual).
- There is **no protocol-owned buffer** held aside from the share price. The
  external surplus between rebalances physically compounds in the external vault
  and is fully counted in NAV — it belongs to shareholders. The treasury earns
  only the pre-existing 1% fee stream.
- **Loss pass-through is immediate.** NAV is real recoverable value, so external
  losses (or a rate over-promise that drains the external position faster than
  it earns) reflect directly in the share price. There is no accumulated cushion
  to delay it — that is the trade for giving holders the upside. Principal is
  preserved long-run **iff** external yield ≥ the promised rate; otherwise the
  loss passes through honestly via NAV.
- Principal *transiently* funds the stream (the pre-fund slice) and continues to
  fund it under impairment (the uncapped replenisher); the stream stays at the
  promised rate while `EXTERNAL_VAULT.maxWithdraw(FM) > 0` and only stalls at
  terminal impairment (`== 0`). There is no `fundReserve`; the operator's only
  sustainability lever is `setStableYieldRate`.

## Locked decisions

| # | Decision | Choice | Status |
|---|---|---|---|
| 1 | Share / loss model | **Floating** ERC-4626 share priced `totalManagedAssets()/totalSupply` (no clamp, no peg); total return = streamed promised rate + appreciation for `external − promised`; immediate honest loss pass-through via real-recoverable NAV | **revised 2026-05-26** |
| 2 | Surplus handling | External surplus compounds inside the external vault and is **counted in NAV** (accrues to shareholders as appreciation) — **no protocol-owned excluded buffer**. The per-op rebalance and `ensureYieldFlowDuration()` pull only the reserve *deficit* (surplus stays deployed/compounding); under impairment the same deficit-only pull continues uncapped into the external position. Excess super-token is trimmed back to external on every rebalance — `onWithdraw` trims its post-payout residual freed excess (no above-target slack at rest) | **revised 2026-05-26** |
| 3 | Rate model | Operator-set promised `stableYieldRate` (reuse async model) | unchanged |
| 4 | Stream funding | **Pre-funded from each deposit** into the super-token reserve (async-style), then continuously replenished from the external position — surplus first, then deeper into the external position under impairment (uncapped). Stream only stalls at terminal impairment (`maxWithdraw(FM) == 0`); no on-chain operator subsidy | **revised** |
| 5 | Withdraw liquidity | Async-faithful: decreasing the redeemer's units lowers the required reserve; the **recalibration-freed excess** (capped at `min(freedExcess, redeemingAssets)`) funds the reserve slice (preserves stayers' horizon by construction), the remainder is drawn from the external vault (reverts only if the external vault is illiquid). Reserve is redeemable | **revised** |
| 6 | Reserve-poking entrypoint | **Operator-only via inherited `ensureYieldFlowDuration()`** (`FUND_OPERATOR_ROLE`). No permissionless `harvest()`. Per-op hooks keep the stream forward-solvent on any user activity; the operator must call between periods of inactivity. Tradeoff: loses permissionless liveness backstop in exchange for a smaller surface | **revised** |
| 7 | Code reuse | Extract shared `FundManagerBase` | unchanged |
| 8 | Solvency trust model | Operator + views (no rate cap / settle gate). Stream starts at deposit via pre-funding and is continuously self-funded from the external position thereafter. **No operator injection / no `fundReserve`** — sync diverges from async here because programmatic `EXTERNAL_VAULT` access removes the off-chain top-up gap. The operator's only sustainability lever is `setStableYieldRate`; impairment is signalled by share-price-below-par (canonical 4626) | **revised** |
| 9 | Async re-audit | Accepted as part of the base extraction | unchanged |
| 10 | First-deposit inflation / donations | With the clamp dropped, donation-resistance no longer comes from NAV; under a floating share a donation is an irrational gift to existing holders, not an attack. Residual first-deposit inflation mitigated by OZ virtual shares — `_decimalsOffset()` hardcoded to `12` (no dead-shares seed; min-shares guard deferred) (see §Security) | **implemented 2026-05-27** |
| 11 | Capital custody | The FundManager is the sole custodian (external-vault shares + super-token reserve + transient unutilized underlying) and the sole NAV authority; the vault holds no assets | **new** |

## Contracts

### `FundManagerBase` (abstract — extracted from `AsyncFundManager`)

The shared Superfluid streaming engine. See
`docs/async-vault/shared-engine-refactor.md`. Members: constants, immutables,
`stableYieldRate`/`_flowRatePerUnit`/`guaranteedFlowDuration`, constructor,
`setStableYieldRate`, `setGuaranteedFlowDuration`, `ensureYieldFlowDuration`,
`evaluateYieldAssetsDeficit`, `yieldAssetsBalance`, `scaledYieldAssetsBalance`,
`_upgrade`, `_downgrade`, `_recalibrateFlow`, `_targetFlowRate`, `_toUnit`,
`onShareTransfer`.

**`_rebalanceYieldAssets()` is abstract** (declaration only — `function
_rebalanceYieldAssets() internal virtual;`). Each family provides its own
implementation: async upgrades from operator-staged `unutilizedAssetsBalance()`
(reverts with `INSUFFICIENT_UNUTILIZED_ASSETS` on under-load); sync sources from
the external position (best-effort, no revert at terminal impairment). See the
per-family contracts below.

**`unutilizedAssetsBalance()`** is async-only (lifted to `IAsyncFundManager` —
the sync FM holds 0 raw underlying at rest by Invariant 7, so the name no
longer fits the sync semantic).

**`_recalibrateFlow()` is NOT guarded** (see Revision 2026-05-27). The
"guarded recalibrate" rule earlier sketched here (Revision 2026-05-22, row θ)
was never implemented and has been **dropped**: terminal external impairment is
handled at the vault's `max*` layer (a full pause) rather than inside the
streaming engine. Consequently `setStableYieldRate` / `ensureYieldFlowDuration`
(and the sync `onDeposit` / `onWithdraw`) call `_recalibrateFlow()`
unconditionally. Under terminal impairment the user hooks never run (the vault
is paused), and the operator setters are permitted to revert
`GDA_INSUFFICIENT_BALANCE` — accepted; the operator's bleed-stopping lever
`setStableYieldRate(0)` still succeeds because recalibrating to a zero flow is a
*close* (no GDA buffer required).

### `SyncFundManager` (extends `FundManagerBase`) — the capital custodian

Holds the immutable `EXTERNAL_VAULT` reference, the external-vault shares, and
the super-token reserve. There is **no `trackedPrincipal` counter** — NAV is
read directly off recoverable balances. `_externalVault` is passed in by the
vault constructor, which already validated
`EXTERNAL_VAULT.asset() == UNDERLYING_ASSET` (no re-validation in the FM). No
`harvest()` entrypoint — solvency between user activity is maintained via the
inherited `ensureYieldFlowDuration()` (`FUND_OPERATOR_ROLE`).

- `_rebalanceYieldAssets()` (override of the abstract base) — the unified
  rebalance primitive, called by:
  - `onDeposit` (pre-bump): clears any pre-existing deficit before the new
    units' target widens the gap. Trim branch structurally unreachable here.
  - `onWithdraw` (top): clears any pre-existing deficit before the unit
    decrease frees reserve excess. Trim branch effectively unreachable here.
  - `onWithdraw` (post-payout): trims any residual freed excess back into the
    external vault (Q1=B, 2026-05-22). Inv. 7 holds.
  - `ensureYieldFlowDuration()` (operator): runs both halves; the inherited
    base wrapper then guarded-recalibrates if the stream was stalled.
  - `setStableYieldRate(newRate)` (operator) and
    `setGuaranteedFlowDuration(newDuration)` (admin): both inherited base
    setters call rebalance after updating the rate/duration; deficit/excess
    direction depends on whether the new target is higher or lower than
    the previous one.

  Behaviour:
  - `deficit > 0`: pull `pulled = min(ceil(deficit / SCALING_FACTOR) + 1,
    EXTERNAL_VAULT.maxWithdraw(this))` from the external vault and `_upgrade`
    it. **Pulls only the deficit, not the whole position** — the external
    surplus stays deployed and compounding (it is counted in NAV and accrues to
    holders as appreciation). While external yield ≥ the promised rate the pull
    is funded by that surplus; under impairment the same deficit-only pull
    continues uncapped into the external position and the loss is borne by
    holders directly via the (unclamped) NAV. The pull is capped at
    `maxWithdraw(this)`, so a compliant (trusted) external vault never reverts
    it → it can **never brick** the calling user op.
  - `deficit < 0`: `_downgrade(uint256(-deficit))` then `forceApprove` +
    `EXTERNAL_VAULT.deposit` the resulting underlying back into the external
    vault so the surplus keeps compounding externally. Inv. 7 is preserved
    (no raw underlying at rest in the FM).
  - Residual `deficit > 0` after the upgrade is **tolerated** — callers (per-op
    hooks and the base setters) guard their `_recalibrateFlow()` accordingly.

- `onDeposit(receiver, assets)` — `VAULT_ROLE`. Receives `assets` underlying
  from the vault:
  1. `YIELD_POOL.increaseMemberUnits(receiver, _toUnit(assets))` — units land
     directly on the receiver; `evaluateYieldAssetsDeficit()` now reflects the
     new (higher) target;
  2. `_rebalanceYieldAssets()` — clears any pre-existing deficit from the
     external position (surplus first, then deeper into the position under
     impairment) before the new units' target widens the gap;
  3. **pre-fund residual**: `deficit = evaluateYieldAssetsDeficit()`;
     `toUpgrade = min(ceil(deficit / SCALING_FACTOR) + 1, assets)` (0 if the
     rebalance already cleared it); `_upgrade(toUpgrade)`;
  4. `EXTERNAL_VAULT.deposit(assets − toUpgrade, address(this))` — the remainder
     is deployed as principal; **no underlying is left at rest in the FM**
     (Invariant 7);
  5. `_recalibrateFlow()` (unconditional) — the stream starts/raises at deposit
     time. This hook cannot be reached under terminal external impairment: the
     vault is paused (`maxDeposit == 0`) whenever `EXTERNAL_VAULT.maxWithdraw(FM)
     == 0`, so a drained, un-refillable reserve never meets a deposit here (see
     Revision 2026-05-27).

- `onWithdraw(holder, shares, totalSharesOwned, supplyBeforeBurn, receiver,
  redeemingAssets)` — `VAULT_ROLE`. The async-`settleEpoch`-netting analog:
  1. `_rebalanceYieldAssets()` — pre-rebalance opportunistically cures any
     *pre-existing* deficit (no-op in the common pre-withdraw solvent case);
  2. proportional unit decrease (same math as async `onRequestRedeem`). Total
     units are now lower;
  3. `_recalibrateFlow()` (unconditional) — the new lower flow rate refunds the
     GDA buffer slice for the removed units back into `YIELD_ASSET.balanceOf(FM)`.
     Like `onDeposit`, this hook is unreachable under terminal external impairment
     (the vault is paused, `maxWithdraw == 0`), so the drained-reserve recalibrate
     revert cannot occur here (see Revision 2026-05-27);
  4. `deficit = evaluateYieldAssetsDeficit()` (post-recalibrate);
     `excessUnderlying = (deficit < 0) ? uint(−deficit) / SCALING_FACTOR : 0`;
     `fromReserve = min(excessUnderlying, redeemingAssets)`;
     `if (fromReserve > 0) _downgrade(fromReserve · SCALING_FACTOR)`;
  5. `fromExternal = redeemingAssets − fromReserve`;
     `if (fromExternal > 0) EXTERNAL_VAULT.withdraw(fromExternal, receiver, this)`
     (reverts only if the external vault is illiquid — accepted, decision 5);
     then `safeTransfer(receiver, fromReserve)` so the receiver gets exactly
     `redeemingAssets`;
  6. `_rebalanceYieldAssets()` — **post-payout trim** (2026-05-22, Q1=B). Any
     residual freed excess `freedExcess − redeemingAssets` (when positive) is
     downgraded and redeposited into the external vault. The reserve returns
     to target; Inv. 7 holds (no raw underlying at rest).

  There is **no principal-counter decrement** — `redeemingAssets` is OZ's
  `previewRedeem(shares) = shares · NAV / supply` (floating, floor), so the burn
  removes exactly the redeemer's pro-rata slice of NAV and the share price is
  unchanged for stayers (floor rounding favours them). The proportional
  `trackedPrincipal` decrement of the old model is no longer needed.

- View helpers the vault proxies (pure reads, no per-call counters):
  `totalManagedAssets()` (the reserve-inclusive NAV — Invariant 2; also caps
  `maxWithdraw`/`maxRedeem`: the per-call freed reserve excess scales with the
  redeemer's unit share, so NAV itself is the global upper bound on what a
  redeem can source, and under impairment the lower recoverable NAV shrinks it
  appropriately), `maxExternalDeposit()`, plus the `EXTERNAL_VAULT` getter (no
  `trackedPrincipal` getter — the counter is gone).

### `StableYieldVault` (extends OZ `ERC4626`, `ReentrancyGuard`) — thin face

Holds **no assets**. Immutable `FUND_MANAGER`; the constructor validates
`IERC4626(_externalVault).asset() == asset()` (keeps `EXTERNAL_ASSET_MISMATCH`
on `IStableYieldVault`) then deploys & pins `SyncFundManager` (`msg.sender ==
vault`), passing `_externalVault` through. The `EXTERNAL_VAULT()` getter
delegates to the FM. Overrides `_decimalsOffset()` to a hardcoded `12`
(implemented 2026-05-27) for first-deposit inflation resistance — `10 ** 12`
attack-cost multiplier, 18-dec shares for the 6-dec USDC deployment (see §Security).

- `totalAssets()` → `FUND_MANAGER.totalManagedAssets()`
  `= EXTERNAL_VAULT.maxWithdraw(FM) + scaledYieldAssetsBalance() +
  UNDERLYING_ASSET.balanceOf(FM)` — the plain sum of recoverable-from-all-sources
  (external position + super-token reserve + transient raw underlying), **no
  clamp**. This is real recoverable value, so it gives honest, immediate loss
  pass-through; the external surplus is included and accrues to holders as share
  appreciation.
- `_deposit(caller, receiver, assets, shares)`: pull underlying from `caller`,
  forward it to the FM, `_mint(receiver, shares)`, `FUND_MANAGER.onDeposit(...)`.
  `nonReentrant`.
- `_withdraw(caller, receiver, owner, assets, shares)`: spend allowance, read
  `balanceOf(owner)` + `totalSupply()` **before** the burn, `_burn(owner, shares)`,
  `FUND_MANAGER.onWithdraw(owner, shares, totalSharesOwnedBefore,
  supplyBeforeBurn, receiver, assets)` (FM moves principal + reserve + units;
  CEI: vault state mutated before the FM's external interaction, `nonReentrant`
  backstop). `nonReentrant`.
- No `harvest()` forwarder — the sync FM has no `harvest()`. Solvency between
  user activity is operator-only via the inherited `ensureYieldFlowDuration()`.
- `maxDeposit/maxMint` capped by `FUND_MANAGER.maxExternalDeposit()` (the
  external vault's deposit limit, FM as holder). `maxWithdraw/maxRedeem` capped
  by `FUND_MANAGER.totalManagedAssets()` (the
  reserve-inclusive NAV is the global upper bound on what a redeem can source,
  since the recalibration-freed reserve excess scales with the redeemer's unit
  share). Under partial external impairment the lower recoverable NAV shrinks
  this appropriately, making `max*` 4626-honest about external illiquidity.
- **Terminal-impairment full pause (Revision 2026-05-27).** When
  `FUND_MANAGER.maxExternalVaultWithdraw() == 0` *and the FM holds an external
  position* (`_isExternallyPaused()`), all four `max*` return `0`, so OZ reverts
  every deposit/mint/withdraw/redeem with `ERC4626ExceededMax*`. The
  empty-position bootstrap (`maxWithdraw(FM) == 0` because nothing is deployed
  yet) is excluded so the first deposit is not bricked. This is the in-engine
  liveness story for terminal impairment — there are deliberately **no**
  `_recalibrateFlow()` guards (the hooks can't run while paused). See
  Revision 2026-05-27.
- `_update` → `FUND_MANAGER.onShareTransfer(from, to, value)` on
  shareholder↔shareholder transfers (unchanged rule).
- `previewDeposit/Mint/Redeem/Withdraw` work synchronously (OZ default — no
  revert, unlike the async vault).

## Flows

### Deposit (stream starts at deposit time)

```mermaid
sequenceDiagram
    participant U as User
    participant V as StableYieldVault
    participant FM as SyncFundManager
    participant E as External ERC-4626
    participant P as GDA Pool
    U->>V: deposit(assets, receiver)
    V->>U: safeTransferFrom underlying (caller → vault)
    V->>FM: forward underlying + onDeposit(receiver, assets)
    V->>V: _mint(receiver, shares ≈ assets)
    FM->>P: increaseMemberUnits(receiver, _toUnit(assets))
    FM->>FM: _rebalanceYieldAssets()  %% deficit-only pull from external (surplus stays compounding; deeper into the position under impairment)
    FM->>FM: _upgrade(min(ceil(deficit/SF)+1, assets))  %% pre-fund residual
    FM->>E: deposit(assets − upgraded, FM)               %% remainder = principal
    FM->>P: _recalibrateFlow()  %% stream starts/raises NOW (only stalls at terminal impairment)
    Note over P: NAV-neutral at entry (principal split into external shares + reserve, both in NAV); thereafter the share floats with the external vault — honest tick-down under impairment
```

### Withdraw / Redeem (reserve-inclusive NAV; reserve slice from recalibration-freed excess)

```mermaid
sequenceDiagram
    participant U as User
    participant V as StableYieldVault
    participant FM as SyncFundManager
    participant E as External ERC-4626
    U->>V: withdraw(assets, receiver, owner)  %% assets = previewRedeem-priced NAV slice
    V->>V: spendAllowance? ; read balance/supply ; _burn(owner, shares)
    V->>FM: onWithdraw(owner, shares, totalOwnedBefore, supplyBeforeBurn, receiver, assets)
    FM->>FM: _rebalanceYieldAssets()  %% pre-rebalance: no-op when solvent (common case)
    FM->>FM: proportional unit decrease  %% required reserve now lower
    FM->>FM: _recalibrateFlow()  %% lower target — refunds GDA buffer slice into reserve (vault paused under terminal impairment, so unreachable here)
    FM->>FM: fromReserve = min(freed excess, assets) ; _downgrade(fromReserve·SF)
    FM->>E: withdraw(assets − fromReserve, receiver, FM)  %% external remainder
    FM->>FM: safeTransfer(receiver, fromReserve)
    FM->>FM: _rebalanceYieldAssets()  %% post-payout trim: residual freed excess back to external
    Note over E: external remainder reverts only if the external vault is illiquid (accepted)
```

Under impairment (external position recoverable < deposited principal): NAV
falls, `previewRedeem` prices the share below par, the redeemer takes the
pro-rata impaired payout. The burn removes exactly `redeemingAssets =
shares · NAV / supply`, so the share price is unchanged for stayers (floor
rounding favours them) — no value transfers between leavers and stayers, handled
by OZ proportional accounting rather than a principal-counter decrement.

### Operator solvency restore (`ensureYieldFlowDuration`)

```mermaid
sequenceDiagram
    participant O as Fund Operator
    participant FM as SyncFundManager
    participant E as External ERC-4626
    O->>FM: ensureYieldFlowDuration()   %% FUND_OPERATOR_ROLE
    FM->>FM: _rebalanceYieldAssets()
    alt deficit > 0
        FM->>E: withdraw(min(ceil(deficit/SF)+1, maxWithdraw(FM)), FM, FM)  %% deficit-only pull
        FM->>FM: _upgrade(pulled) — reserve refilled
    else deficit < 0
        FM->>FM: _downgrade(excess) ; redeposit underlying into external vault (surplus keeps compounding)
    end
    FM->>FM: _recalibrateFlow()  %% restart stalled flow (may revert under terminal impairment — accepted; operator uses setStableYieldRate(0))
    Note over E: surplus beyond the deficit stays compounding in the external vault (counted in NAV, accrues to holders); under impairment the pull eats deeper into the position (loss reflected directly in NAV)
```

The operator runs `ensureYieldFlowDuration()` between user activity to keep the
stream forward-solvent (the stream itself can only stall at terminal external
impairment; per-op hooks already pre-empt any deficit on user activity). There
is **no permissionless `harvest()`** in this design: the sync vault has a
smaller surface in exchange for requiring the operator to remain alert during
periods of low activity. If liveness backstopping is later required, a
permissionless wrapper around `_rebalanceYieldAssets()` is the natural
extension point.

`_rebalanceYieldAssets()` only ever pulls the reserve **deficit** (never the
full surplus when solvent — that is what keeps the external surplus compounding
and accruing to holders as share appreciation). Under impairment the same
deficit-only pull continues uncapped deeper into the external position; the loss
is reflected directly by the (unclamped) NAV falling rather than by the stream
stalling.

## Invariants

1. **Share accounting (OZ-standard, no principal counter).** Shares mint/burn
   against the floating NAV — deposit mints `assets · supply / NAV`, withdraw
   pays `shares · NAV / supply` (floor, favouring stayers). There is **no
   `trackedPrincipal` counter**; the no-inter-holder-value-transfer property
   the old proportional decrement enforced now holds automatically via OZ
   proportional accounting.
2. **Total assets (reserve-inclusive, unclamped).** `totalAssets ==
   EXTERNAL_VAULT.maxWithdraw(FM) + scaledYieldAssetsBalance() +
   UNDERLYING_ASSET.balanceOf(FM)`. *Recoverable from all sources* = external
   position + super-token reserve + raw underlying — a plain sum, **no clamp**.
   The external surplus is included and accrues to holders as share
   appreciation; under impairment the sum falls and the share takes the loss
   immediately and honestly.
3. *(Retired 2026-05-26.)* The old "buffer is non-extracted as treasury but
   fully drawable as reserve" invariant no longer applies — there is no
   protocol-owned excluded buffer. The external surplus is part of NAV and
   belongs to shareholders; the treasury still earns only the 1% fee stream
   (the rebalance pulls only the reserve *deficit*, never extracted as
   treasury revenue).
4. **Stream funded from the external position end-to-end.** Every deposit
   pre-rebalances the reserve (`_rebalanceYieldAssets()` uncapped), then
   upgrades enough of the *incoming* underlying to clear any residual deficit
   (capped by `assets`). Inter-deposit drain is replenished from the external
   position by the per-op rebalance and the operator's
   `ensureYieldFlowDuration()` — surplus first, then deeper into the external
   position once the surplus is exhausted. Principal preserved long-run iff
   external yield ≥ rate (else honest, immediate pass-through via the unclamped
   NAV). The stream only halts at terminal impairment
   (`EXTERNAL_VAULT.maxWithdraw(FM) == 0`).
5. **Reserve horizon.** Maintained on every deposit/withdraw (best-effort,
   deficit-gated rebalance) and by the operator's `ensureYieldFlowDuration()`:
   `yieldAssetsBalance() ≥ totalFlowRate · guaranteedFlowDuration`
   (best-effort; same trust model as async — nothing structurally enforces it).
   A withdraw cannot break it for stayers: units drop → required reserve drops,
   and only the recalibration-*freed* excess up to `redeemingAssets` is
   downgraded for the redeemer (`fromReserve ≤ freedExcess`); any residual is
   trimmed back to the external vault by the post-payout rebalance. The only
   state where the reserve cannot meet horizon is terminal impairment (external
   vault returns 0 on `maxWithdraw`); in that limit the stream is left stalled
   and (re)started by the next operator-called `ensureYieldFlowDuration()`.
   Deposits/withdrawals are never bricked.
6. **Units track shareholding.** A holder's GDA units are proportional to their
   share balance; transfers move a proportional slice (`onShareTransfer`).
7. **FM is the sole custodian.** All vault-controlled assets (external-vault
   shares, super-token reserve, transient unutilized underlying) live in the FM;
   the vault's underlying/super-token balances are 0 at rest. **Custody hazard
   invariant:** principal never rests in the FM as raw underlying across calls —
   it is deployed into the external vault or upgraded into the reserve within
   the same call, otherwise the base rebalance logic would sweep it into the
   reserve and silently consume principal.

## Security considerations

- **Donations under a floating share (clamp dropped 2026-05-26).** NAV is the
  raw sum of external `maxWithdraw` + super-token reserve + raw underlying, with
  no clamp. A super-token or raw-underlying transfer to the FM therefore *does*
  raise NAV and the share price — but it raises it for **existing holders**, so
  it is an irrational gift, not a profitable attack (the donor strictly loses).
  The one genuinely exploitable surface is the classic ERC-4626 **first-deposit
  inflation attack** (front-run the first depositor, donate to inflate price per
  share, the victim's deposit rounds to 0 shares). Mitigation replacing the
  clamp (implemented 2026-05-27): OZ **virtual shares** via a `_decimalsOffset()`
  override on the vault returning a hardcoded `12` — `10 ** 12` attack-cost
  multiplier, 18-dec shares for the 6-dec USDC deployment. The offset alone makes
  the attack economically infeasible; the dead-shares seed was rejected and the
  "mint 0 shares ⇒ revert" guard deferred. For a non-6-dec underlying the value
  must be revisited (the bare `18 − d` normalize form gives `0` protection at an
  18-dec underlying; floor it as `max(K, 18 − d)`). Pinned by
  `test_firstDepositInflation_victimMintsNonZero`.
- **Share price ticks between rebalances.** The stream continuously drains the
  reserve, so NAV (and thus `convertToShares/Assets`, deposit/withdraw/transfer
  pricing) decays between rebalances and recovers at each funded rebalance
  (per-op or operator `ensureYieldFlowDuration()`). This is the async
  forward-priced property made continuously observable. Timing/MEV around
  rebalance cadence is a known consideration; mitigations: per-op rebalance
  on every user activity, OZ virtual shares, rounding favours the vault,
  `nonReentrant`. The operator must call `ensureYieldFlowDuration()` between
  user activity to keep the share-price drift bounded.
- **Impairment is signalled by share price, not by liveness.** With the
  uncapped self-funded replenisher, external under-earn does *not* stall the
  stream — it shows up as a downward move of the (unclamped) NAV / share price as
  the rebalance drains the external position faster than it earns. Off-chain
  monitoring should track `convertToAssets(1 share)` trending below the entry
  price rather than `getTotalFlowRate() == 0`; the only "stream stopped" state is
  terminal external failure (`maxWithdraw(FM) == 0`).
- **Pre-funding can exceed the deposit (pathological config).** If
  `rate × guaranteedFlowDuration / YEAR` approaches 1, a deposit's own
  incremental reserve requirement can approach/exceed `assets`. The pre-fund
  is capped by `assets`; the residual is sourced by the uncapped
  `_rebalanceYieldAssets()` (from the external surplus first, then deeper into
  the external position if the surplus is exhausted — the loss reflects directly
  in NAV). The operator must keep `stableYieldRate × guaranteedFlowDuration`
  sane (no on-chain cap — same trust model as async).
- **A new deposit can subsidise a pre-existing reserve backlog.** The pre-fund
  + uncapped `_rebalanceYieldAssets()` clears the *global*
  `evaluateYieldAssetsDeficit()` (the GDA buffer requirement is global — a
  stream cannot be partially started). In a vault whose external position has
  persistently underperformed, the rebalance is now eating deeper into the
  external position — NAV / share price is already below the entry price; the
  new depositor enters at that impaired price and immediately owns a pro-rata
  slice of the impaired NAV (no value transfer to existing holders beyond what
  the price already reflects). Flagged for audit and disclosure.
- **External vault is trusted but third-party.** `maxWithdraw(FM)` feeds NAV,
  the rebalance source, and the withdraw principal leg — a manipulable external
  share price propagates in. Integrate only standard, audited, non-rebasing
  4626s whose `asset()` equals our underlying.
- **Reentrancy.** `nonReentrant` on `deposit`/`mint`/`withdraw`/`redeem` (vault);
  CEI ordering — vault burns/state-updates before the FM's external interaction;
  the FM's value-bearing `VAULT_ROLE` hooks are reachable only from the pinned
  vault and are backstopped by the vault guard. `ensureYieldFlowDuration()` is
  operator-only (no permissionless reserve-poking entrypoint).
- **FM hooks are now value-bearing.** `onDeposit`/`onWithdraw` move principal +
  reserve (not just GDA units as in the original model). The `VAULT_ROLE` gate
  and the custody hazard invariant (7) are load-bearing; audit must confirm no
  principal can be diverted via the rebalance path.
- **External illiquidity** (accepted, decision 5): the redeemer's reserve slice
  is funded from the recalibration-freed reserve excess (always serviceable via
  `_downgrade`); only the *external remainder* reverts if the external vault
  cannot service it. `maxWithdraw`/`maxRedeem` reflect it via
  `totalManagedAssets()` — under external impairment the lower recoverable NAV
  shrinks the bound, so a request ≤ `max*` never bricks.
- **Rate > sustainable yield** (accepted; **diverges from async**): the external
  surplus depletes, the per-op replenisher continues uncapped deeper into the
  external position, and the (unclamped) NAV passes the loss to shares honestly
  and immediately. The stream itself only stalls at terminal impairment
  (`maxWithdraw(FM) == 0`). The operator's only sustainability lever is
  `setStableYieldRate` — **there is no `fundReserve` injection path** (sync's
  programmatic `EXTERNAL_VAULT` access removes the off-chain top-up gap async
  had). The impairment signal is share-price-below-entry (canonical 4626), not
  a stalled flow.
- **Decimals.** Inherited `SCALING_FACTOR`/`RAW_PER_UNIT` constraints (underlying
  decimals ∈ [6, 18]; the existing 18-dec `FIXME` carries over). External-vault
  share decimals are independent and handled via its own `convert*`.

## Out of scope / explicitly dropped vs async

Epoch lifecycle in its entirety: `requestDeposit`/`requestRedeem`, snapshot,
`closeEpoch`/`settleEpoch`, effective-supply correction, `canSettleEpoch`,
`evaluateFunding`, ERC-7540/7575 interfaces, ERC-7540 operators, `take`/`give`
off-chain capital movement (the external ERC-4626 replaces the working-capital
leg). The async settlement *netting* logic is not dropped — it reappears
synchronously and per-call inside `SyncFundManager.onDeposit`/`onWithdraw`.
