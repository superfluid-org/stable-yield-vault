# Stable Yield Sync Vault — Design

Status: **locked** (brainstormed 2026-05-18; **revised 2026-05-19 — async-symmetric pivot**; **revised 2026-05-21 — self-funded stream pivot**; **revised 2026-05-22 — unified rebalance primitive, `harvest()` dropped**; implementation in progress)

A synchronous ERC-4626 sibling of `StableYieldAsyncVault`. Users deposit/withdraw
instantly; principal is routed into an external ERC-4626 (Morpho, Beefy, …); a
**stable** yield is streamed to depositors via the same Superfluid GDA engine the
async vault uses. The external vault replaces the async vault's manual off-chain
"working assets" leg.

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
| θ | Base `setStableYieldRate` and `ensureYieldFlowDuration` invoked `_recalibrateFlow()` after the rebalance — `setStableYieldRate` unconditionally, `ensureYieldFlowDuration` only on a stalled-flow + units-out check. Both would revert at terminal external impairment in the sync family (residual positive deficit after best-effort rebalance + Superfluid GDA buffer requirement on `distributeFlow`). | **Both base callers gain a `evaluateYieldAssetsDeficit() <= 0` guard before `_recalibrateFlow()`.** Async healthy path is unchanged (the override enforces deficit ≤ 0 or reverts, so the guard is trivially true). Sync terminal-impairment path silently skips the recalibrate — the next funded `ensureYieldFlowDuration()` restarts the stream. |

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

> **Principal is tracked by shares and custodied by the FundManager (deployed
> into the external ERC-4626). A stable yield is delivered out-of-band as a
> Superfluid stream, pre-funded from each deposit into the FM's super-token
> reserve and continuously replenished from the external position — surplus
> first, then principal-backing slice under impairment.**

NAV is the FM's recoverable external principal **plus** the super-token reserve,
so a deposit only changes the *form* of the FM's assets (external-vault shares ↔
super-token), never their total — the share is NAV-neutral at entry and stays
≈1:1 with the underlying while the external vault earns at least the promised
rate. This is structurally identical to the async vault (FM custodies capital +
a super-token reserve; NAV = working + unutilized + scaled reserve; the stream
distributes the reserve and is replenished by yield) **minus the epoch
lifecycle**. The streamed APY is operator-committed and decoupled from the
external vault's real performance; the surplus above it compounds inside the
external vault as a protocol-owned solvency **buffer**.

Consequences:

- The share is a principal receipt, **≈**1:1 with the underlying — *not* a hard
  peg. Between rebalances the stream continuously drains the reserve, so NAV
  (and the share price) ticks slightly below par and recovers at the next
  funded rebalance (per-op or operator `ensureYieldFlowDuration()`), exactly
  like the async forward-priced share but continuously observable instead of
  epoch-snapshotted.
- External yield above the promised rate is **not** booked into the share price
  — it stays inside the external vault as compounding external-vault shares, the
  protocol-owned **buffer**.
- That buffer is the loss-absorption layer: external losses (and rate
  over-promises) shrink the buffer first; once the buffer is exhausted the
  replenisher continues uncapped into the principal-backing slice and the
  residual loss passes through honestly via the `min(trackedPrincipal, ext +
  reserve)` clamp in NAV.
- The buffer is **never extracted as treasury revenue** (treasury earns only the
  pre-existing 1% fee stream) but it **is** fully drawable to fund the stream
  under impairment — there is no protocol-owned slice kept idle.
- Principal *transiently* funds the stream (the pre-fund slice) and continues
  to fund it under impairment (the uncapped replenisher); principal is
  preserved long-run **iff** external yield ≥ the promised rate, otherwise the
  loss passes through honestly. This is the async risk profile minus the
  operator-injection recovery channel — there is no `fundReserve`; the operator
  must keep the rate sustainable (`setStableYieldRate` lever). The stream
  itself never stalls until `EXTERNAL_VAULT.maxWithdraw(FM) == 0` (terminal
  impairment).

## Locked decisions

| # | Decision | Choice | Status |
|---|---|---|---|
| 1 | Share / loss model | Principal receipt **≈1:1** (reserve-inclusive NAV, ticks below par between rebalances); honest loss pass-through via the `min(trackedPrincipal, external)` floor | **revised** |
| 2 | Surplus handling | External surplus (buffer) compounds inside the external vault; the per-op rebalance and `ensureYieldFlowDuration()` pull only the reserve *deficit* — surplus first, **then into the principal-backing slice when surplus is exhausted** (uncapped at `EXTERNAL_VAULT.maxWithdraw(FM)`). Trim of excess super-token back to the external vault runs on every rebalance — `onWithdraw` trims its post-payout residual freed excess (no above-target slack at rest) | **revised** |
| 3 | Rate model | Operator-set promised `stableYieldRate` (reuse async model) | unchanged |
| 4 | Stream funding | **Pre-funded from each deposit** into the super-token reserve (async-style), then continuously replenished from the external position — surplus first, principal-backing slice under impairment (uncapped). Stream only stalls at terminal impairment (`maxWithdraw(FM) == 0`); no on-chain operator subsidy | **revised** |
| 5 | Withdraw liquidity | Async-faithful: decreasing the redeemer's units lowers the required reserve; the **recalibration-freed excess** (capped at `min(freedExcess, redeemingAssets)`) funds the reserve slice (preserves stayers' horizon by construction), the remainder is drawn from the external vault (reverts only if the external vault is illiquid). Reserve is redeemable | **revised** |
| 6 | Reserve-poking entrypoint | **Operator-only via inherited `ensureYieldFlowDuration()`** (`FUND_OPERATOR_ROLE`). No permissionless `harvest()`. Per-op hooks keep the stream forward-solvent on any user activity; the operator must call between periods of inactivity. Tradeoff: loses permissionless liveness backstop in exchange for a smaller surface | **revised** |
| 7 | Code reuse | Extract shared `FundManagerBase` | unchanged |
| 8 | Solvency trust model | Operator + views (no rate cap / settle gate). Stream starts at deposit via pre-funding and is continuously self-funded from the external position thereafter. **No operator injection / no `fundReserve`** — sync diverges from async here because programmatic `EXTERNAL_VAULT` access removes the off-chain top-up gap. The operator's only sustainability lever is `setStableYieldRate`; impairment is signalled by share-price-below-par (canonical 4626) | **revised** |
| 9 | Async re-audit | Accepted as part of the base extraction | unchanged |
| 10 | First-deposit inflation | OZ ERC-4626 default mitigation; **re-examine** — reserve-inclusive NAV adds a super-token donation surface (see §Security) | refined |
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

**`_recalibrateFlow()` guards** in `setStableYieldRate` and
`ensureYieldFlowDuration`: both wrap the recalibrate in
`if (evaluateYieldAssetsDeficit() <= 0)` so the call short-circuits silently at
terminal external impairment in the sync family. Async healthy path unchanged
(the override enforces `deficit ≤ 0` or reverts).

### `SyncFundManager` (extends `FundManagerBase`) — the capital custodian

Holds the immutable `EXTERNAL_VAULT` reference, the `trackedPrincipal` counter,
the external-vault shares, and the super-token reserve. `_externalVault` is
passed in by the vault constructor, which already validated
`EXTERNAL_VAULT.asset() == UNDERLYING_ASSET` (no re-validation in the FM). No
`harvest()` entrypoint — solvency between user activity is maintained via the
inherited `ensureYieldFlowDuration()` (`FUND_OPERATOR_ROLE`).

- `_rebalanceYieldAssets()` (override of the abstract base) — the unified
  rebalance primitive, called by:
  - `onDeposit` (pre-bump): clears any pre-existing deficit before the new
    units' target widens the gap. Trim branch structurally unreachable here.
  - `onWithdraw` (top): clears any pre-existing deficit before the unit
    decrease frees buffer. Trim branch effectively unreachable here.
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
    it. **Uncapped at the surplus** — while solvent (`maxWithdraw(this) >
    trackedPrincipal`) only the buffer is consumed; once the buffer is
    exhausted the pull continues into the principal-backing slice (the loss is
    then borne by holders via the `min(trackedPrincipal, ext + reserve +
    rawUnderlying)` NAV clamp). The pull is capped at `maxWithdraw(this)`, so
    a compliant (trusted) external vault never reverts it → it can **never
    brick** the calling user op.
  - `deficit < 0`: `_downgrade(uint256(-deficit))` then `forceApprove` +
    `EXTERNAL_VAULT.deposit` the resulting underlying back into the external
    vault so the buffer keeps compounding externally. Inv. 7 is preserved
    (no raw underlying at rest in the FM).
  - Residual `deficit > 0` after the upgrade is **tolerated** — callers (per-op
    hooks and the base setters) guard their `_recalibrateFlow()` accordingly.

- `onDeposit(receiver, assets)` — `VAULT_ROLE`. Receives `assets` underlying
  from the vault:
  1. `YIELD_POOL.increaseMemberUnits(receiver, _toUnit(assets))` — units land
     directly on the receiver; `evaluateYieldAssetsDeficit()` now reflects the
     new (higher) target;
  2. `_rebalanceYieldAssets()` — buffer-first, against the OLD
     `trackedPrincipal`: the compounding buffer covers the deficit first and
     principal is skimmed only as a fallback;
  3. `trackedPrincipal += assets`;
  4. **pre-fund residual**: `deficit = evaluateYieldAssetsDeficit()`;
     `toUpgrade = min(ceil(deficit / SCALING_FACTOR) + 1, assets)` (0 if the
     rebalance already cleared it); `_upgrade(toUpgrade)`;
  5. `EXTERNAL_VAULT.deposit(assets − toUpgrade, address(this))` — the remainder
     is deployed as principal; **no underlying is left at rest in the FM**
     (Invariant 7);
  6. **guarded** `_recalibrateFlow()` (`if evaluateYieldAssetsDeficit() <= 0`)
     — the stream starts/raises at deposit time. Terminal impairment
     (`EXTERNAL_VAULT.maxWithdraw(FM) == 0` AND `assets` cannot cover the
     residual) silently skips; units are granted; the next
     `ensureYieldFlowDuration()` restarts the stream.

- `onWithdraw(holder, shares, totalSharesOwned, supplyBeforeBurn, receiver,
  redeemingAssets)` — `VAULT_ROLE`. The async-`settleEpoch`-netting analog:
  1. `_rebalanceYieldAssets()` — pre-rebalance opportunistically cures any
     *pre-existing* deficit (no-op in the common pre-withdraw solvent case);
  2. proportional unit decrease (same math as async `onRequestRedeem`). Total
     units are now lower;
  3. **guarded `_recalibrateFlow()`**
     (`if getTotalFlowRate() != 0 || evaluateYieldAssetsDeficit() <= 0`) — the
     new lower flow rate refunds the GDA buffer slice for the removed units
     back into `YIELD_ASSET.balanceOf(FM)`. Terminal impairment leaves a
     stalled vault stalled; the withdrawal is never bricked;
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
     to target; Inv. 7 holds (no raw underlying at rest);
  7. `trackedPrincipal -= trackedPrincipal · shares / supplyBeforeBurn` (floor,
     favours remaining holders — Invariant 1).

- View helpers the vault proxies (pure reads, no per-call counters):
  `totalManagedAssets()` (the reserve-inclusive NAV — Invariant 2),
  `serviceableUnderlying()` (returns `totalManagedAssets()` — per-call freed
  reserve excess scales with the redeemer's unit share, so NAV itself is the
  global upper bound on what a redeem can source; under impairment the clamp
  shrinks it appropriately), `maxExternalDeposit()`, plus
  `EXTERNAL_VAULT`/`trackedPrincipal` getters.

### `StableYieldVault` (extends OZ `ERC4626`, `ReentrancyGuard`) — thin face

Holds **no assets**. Immutable `FUND_MANAGER`; the constructor validates
`IERC4626(_externalVault).asset() == asset()` (keeps `EXTERNAL_ASSET_MISMATCH`
on `IStableYieldVault`) then deploys & pins `SyncFundManager` (`msg.sender ==
vault`), passing `_externalVault` through. `EXTERNAL_VAULT()` / `trackedPrincipal()`
getters delegate to the FM (ABI/back-compat).

- `totalAssets()` → `FUND_MANAGER.totalManagedAssets()`
  `= min(trackedPrincipal, EXTERNAL_VAULT.maxWithdraw(FM) +
  scaledYieldAssetsBalance() + UNDERLYING_ASSET.balanceOf(FM))`. The `min(…)`
  clamp on recoverable-from-all-sources (external + reserve + raw underlying)
  is the on-chain honest analog of async's NAV — it gives honest loss
  pass-through *and* absorbs every donation path (compounding external buffer,
  super-token donations, raw-underlying donations) symmetrically.
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
  by `FUND_MANAGER.serviceableUnderlying()` (= `totalManagedAssets()` — the
  reserve-inclusive NAV is the global upper bound on what a redeem can source,
  since the recalibration-freed reserve excess scales with the redeemer's unit
  share). Under external impairment the NAV clamp shrinks this appropriately,
  making `max*` 4626-honest about external illiquidity.
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
    FM->>FM: trackedPrincipal += assets
    FM->>P: increaseMemberUnits(receiver, _toUnit(assets))
    FM->>FM: _rebalanceYieldAssets()  %% uncapped at maxWithdraw(FM): buffer first, then principal-backing slice under impairment
    FM->>FM: _upgrade(min(ceil(deficit/SF)+1, assets))  %% pre-fund residual
    FM->>E: deposit(assets − upgraded, FM)               %% remainder = principal
    FM->>P: _recalibrateFlow()  %% stream starts/raises NOW (only stalls at terminal impairment)
    Note over P: NAV-neutral at entry while solvent (principal split into external shares + reserve, both in NAV); honest tick-down under impairment via the min(P, ext+reserve) clamp
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
    FM->>FM: guarded _recalibrateFlow()  %% lower target — refunds GDA buffer slice into reserve
    FM->>FM: fromReserve = min(freed excess, assets) ; _downgrade(fromReserve·SF)
    FM->>E: withdraw(assets − fromReserve, receiver, FM)  %% external remainder
    FM->>FM: safeTransfer(receiver, fromReserve)
    FM->>FM: _rebalanceYieldAssets()  %% post-payout trim: residual freed excess back to external
    FM->>FM: trackedPrincipal -= principal slice
    Note over E: external remainder reverts only if the external vault is illiquid (accepted)
```

Under impairment (`EXTERNAL_VAULT.maxWithdraw(FM) < trackedPrincipal`): the NAV
floor falls, `previewRedeem` prices the share below par, the redeemer takes the
pro-rata impaired payout. The proportional `trackedPrincipal` decrement
(Invariant 1) keeps `V/P` constant across the exit, so no value transfers
between leavers and stayers.

### Operator solvency restore (`ensureYieldFlowDuration`)

```mermaid
sequenceDiagram
    participant O as Fund Operator
    participant FM as SyncFundManager
    participant E as External ERC-4626
    O->>FM: ensureYieldFlowDuration()   %% FUND_OPERATOR_ROLE
    FM->>FM: _rebalanceYieldAssets()
    alt deficit > 0
        FM->>E: withdraw(min(ceil(deficit/SF)+1, maxWithdraw(FM)), FM, FM)  %% uncapped at the surplus
        FM->>FM: _upgrade(pulled) — reserve refilled
    else deficit < 0
        FM->>FM: _downgrade(excess) ; redeposit underlying into external vault (buffer compounds)
    end
    FM->>FM: guarded _recalibrateFlow()  %% restart stalled flow iff deficit <= 0
    Note over E: surplus beyond the deficit stays compounding as the buffer; under impairment the pull eats into the principal-backing slice (loss reflected via NAV clamp)
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
full surplus when solvent — that is what makes the buffer compound and absorb
losses). Under impairment the same deficit-only pull continues uncapped into
the principal-backing slice; the loss is reflected by the NAV clamp inverting
(`recoverable < trackedPrincipal`) rather than by the stream stalling.

## Invariants

1. **Principal accounting (FM-owned).** `trackedPrincipal += assets` on deposit;
   `trackedPrincipal −= trackedPrincipal · sharesBurned / totalSupplyBeforeBurn`
   (floor) on withdraw. Proportional, not by payout — keeps `V/P` invariant
   through impaired exits.
2. **Total assets (reserve-inclusive, clamped to principal).** `totalAssets ==
   min(trackedPrincipal, EXTERNAL_VAULT.maxWithdraw(FM) +
   scaledYieldAssetsBalance() + UNDERLYING_ASSET.balanceOf(FM))`. *Recoverable
   from all sources* = external position + super-token reserve + raw
   underlying, clamped at `trackedPrincipal` so the compounding external
   buffer **and every donation path** (super-token OR raw underlying) are
   excluded from share price. Under impairment the clamp goes the other way
   (clamped at the lower recoverable) and the share takes the loss honestly.
3. **Buffer is non-extracted as treasury, but fully drawable as reserve.**
   Rebalance pulls (per-op + operator `ensureYieldFlowDuration()`) only ever
   target the reserve *deficit* — never extracted as treasury revenue (treasury
   earns only the 1% fee stream). While external yield ≥ rate,
   `EXTERNAL_VAULT.maxWithdraw(FM) ≥ trackedPrincipal` is preserved (only the
   surplus moves). Under impairment the same deficit-only pull continues
   uncapped (`min(deficit, maxWithdraw(FM))`) and the buffer +
   principal-backing slice are both drawable; the loss flows to shares via the
   NAV clamp, never to the treasury.
4. **Stream funded from the external position end-to-end.** Every deposit
   pre-rebalances the reserve (`_rebalanceYieldAssets()` uncapped), then
   upgrades enough of the *incoming* underlying to clear any residual deficit
   (capped by `assets`). Inter-deposit drain is replenished from the external
   position by the per-op rebalance and the operator's
   `ensureYieldFlowDuration()` — surplus first, then principal-backing slice
   once the buffer is exhausted. Principal preserved long-run iff external
   yield ≥ rate (else honest pass-through via the NAV clamp). The stream only
   halts at terminal impairment (`EXTERNAL_VAULT.maxWithdraw(FM) == 0`).
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

- **Reserve-inclusive NAV is donation-resistant by the min-clamp (locked
  2026-05-19; refined).** The decision was to use the raw super-token balance
  (matching async). The corrected NAV formula `min(trackedPrincipal, ext +
  reserve) + unutilized` (Invariant 2) additionally **clamps the recoverable at
  `trackedPrincipal`**, so a super-token donation pushing `ext + reserve` above
  `trackedPrincipal` leaves NAV unchanged in the healthy/solvent state — the
  donation is absorbed by the clamp, not the share price. The residual surface
  is **also folded into the clamp** (`UNDERLYING_ASSET.balanceOf(FM)` is a
  third term inside `min(trackedPrincipal, …)`), so raw-underlying donations
  are absorbed symmetrically with super-token donations. There is no
  outside-the-clamp slack term left; the residual surface is bounded by OZ
  virtual shares as defense-in-depth and characterised by tests on both
  donation paths.
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
  stream — it shows up as a downward tick of the NAV clamp once
  `ext + reserve` falls below `trackedPrincipal`. Off-chain monitoring should
  track `convertToAssets(1 share)` (or `totalManagedAssets() < trackedPrincipal`)
  rather than `getTotalFlowRate() == 0`; the only "stream stopped" state is
  terminal external failure (`maxWithdraw(FM) == 0`).
- **Pre-funding can exceed the deposit (pathological config).** If
  `rate × guaranteedFlowDuration / YEAR` approaches 1, a deposit's own
  incremental reserve requirement can approach/exceed `assets`. The pre-fund
  is capped by `assets`; the residual is sourced by the uncapped
  `_rebalanceYieldAssets()` (from the buffer first, then from the
  principal-backing slice if the buffer is exhausted — the loss reflects in
  the NAV clamp). The operator must keep
  `stableYieldRate × guaranteedFlowDuration` sane (no on-chain cap — same trust
  model as async).
- **A new deposit can subsidise a pre-existing reserve backlog.** The pre-fund
  + uncapped `_rebalanceYieldAssets()` clears the *global*
  `evaluateYieldAssetsDeficit()` (the GDA buffer requirement is global — a
  stream cannot be partially started). In a vault whose buffer is exhausted
  (external persistently underperformed) the rebalance is now eating into the
  principal-backing slice — the NAV clamp has already inverted and share price
  is below par; the new depositor enters at the impaired price and immediately
  owns a pro-rata slice of the impaired NAV (no value transfer to existing
  holders beyond what the price already reflects). Flagged for audit and
  disclosure.
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
  `serviceableUnderlying() = totalManagedAssets()` — under external impairment
  the NAV clamp shrinks the bound, so a request ≤ `max*` never bricks.
- **Rate > sustainable yield** (accepted; **diverges from async**): the buffer
  depletes, the per-op replenisher continues uncapped into the
  principal-backing slice, and the NAV clamp passes the loss to shares
  honestly. The stream itself only stalls at terminal impairment
  (`maxWithdraw(FM) == 0`). The operator's only sustainability lever is
  `setStableYieldRate` — **there is no `fundReserve` injection path** (sync's
  programmatic `EXTERNAL_VAULT` access removes the off-chain top-up gap async
  had). The impairment signal is share-price-below-par (canonical 4626), not
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
