# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Foundry project; `solc 0.8.34`, optimizer on (200 runs).

- `forge build` — compile (CI uses `forge build --sizes`)
- `forge test -vvv` — run all tests
- `forge test --match-contract StableYieldAsyncVaultTest --match-test test_<name>` — single async test; sync suite is `--match-contract StableYieldSyncVaultTest`
- `forge test --match-path test/vault/async/AsyncFundManager.t.sol` — single file
- `forge fmt` (CI runs `forge fmt --check`) — formatter is enforced; uses 120-col, bracket spacing, sorted imports, blank-line between contracts
- `forge coverage --report lcov` — produces `lcov.info` (already tracked at repo root)
- CI uses `FOUNDRY_PROFILE=ci` (identical settings to default; the variable just selects the profile).
- Echidna: `make echidna-smoke` (50k-tx, `test/echidna/EchidnaStableYieldVault.sol`, async) / `make echidna-long` (1M-tx) / `make echidna-sync-smoke` / `make echidna-sync-long` (`test/echidna/EchidnaStableYieldSyncVault.sol`, sync) / `make echidna-clean` (wipe corpus). Harnesses do a full Superfluid deploy in their constructor. Targets export `FOUNDRY_PROFILE=echidna`, which pins all 16 Superfluid external libraries to fixed addresses (`foundry.toml`); the harness `_plantSuperfluidLibraries()` then etches each library's runtime bytecode at its pinned address before deploying the framework. Requires `echidna`, `slither`, `crytic-compile`, and `solc 0.8.34` on `PATH`.

Tests deploy a full Superfluid framework in `setUp` via `SuperfluidFrameworkDeployer`, which is slow — prefer running a focused subset while iterating.

## Architecture

There are **two vault families** that share one Superfluid GDA streaming engine:

- **Async** — an ERC-7540 vault paying a **stable** (capped/smoothed) yield via a request → settle → claim epoch lifecycle: `StableYieldAsyncVault` + `AsyncFundManager`.
- **Sync** — an ERC-4626 vault that routes principal into an external ERC-4626 and streams the same stable yield with no epoch lifecycle: `StableYieldSyncVault` + `SyncFundManager`.

The streaming engine (GDA pools, `_flowRatePerUnit`, `_recalibrateFlow`, `_rebalanceYieldAssets`, `guaranteedFlowDuration`, `setStableYieldRate`, fee pool, scaling, roles, `onShareTransfer`) lives in the abstract `src/common/FundManagerBase.sol`. `AsyncFundManager is FundManagerBase, IAsyncFundManager` (adds epoch hooks); `SyncFundManager is FundManagerBase, ISyncFundManager` (adds synchronous deposit/withdraw hooks). The base was extracted from the old monolithic `FundManager` as a behaviour-preserving refactor, with each family's flow then separated into its own FM.

### Directory map

```
src/common/FundManagerBase.sol               shared GDA engine (abstract)
src/vault/async/StableYieldAsyncVault.sol     ERC-7540 vault
src/vault/async/AsyncFundManager.sol          epoch hooks
src/vault/sync/StableYieldSyncVault.sol       ERC-4626 share/accounting face
src/vault/sync/SyncFundManager.sol            sync custody + deposit/withdraw hooks + self-sourcing rebalance
src/interfaces/common/ + src/interfaces/vault/{async,sync}/   split symmetrically
```

### Vault ↔ FundManager pinning (both families)

The vault's constructor deploys its FundManager with `msg.sender == vault`. The FM grants `VAULT_ROLE` to that address and pins the pair as immutable. There is no factory or proxy — read the **vault** first; the FM is meaningless in isolation.

### Async family — epoch lifecycle (forward-priced)

A request → settle → claim cycle, gated by an operator:

1. `requestDeposit` / `requestRedeem` — investor enters; assets escrow in vault; shares for redeems are pulled from the owner; FM decreases the redeemer's GDA units. Reverts with `EPOCH_SETTLEMENT_IN_PROGRESS` while a snapshot is open.
2. `AsyncFundManager.closeEpoch(workingAssets)` (FM operator) — snapshots `{epoch, depositingAssets, redeemingShares, rate}` in the vault, increments `currentEpoch`. NAV = `workingAssets + unutilizedAssetsBalance() + scaledYieldAssetsBalance()`. Rate uses an *effective supply* = `totalSupply + unclaimedDepositShares − unclaimedRedeemShares` to correct for the gap between settlement (assets move) and claim (shares mint/burn).
3. `AsyncFundManager.settleEpoch()` — vault nets deposits vs. redeems: surplus pushed to FM; deficit pulled from FM (downgrades super-token). FM grants itself pool units for the epoch's deposits, then `_recalibrateFlow()`. Settlement is gated by `canSettleEpoch()` precondition checks.
4. `deposit`/`mint`/`redeem`/`withdraw` — claim. Vault lazy-settles the controller's pending request at the locked epoch rate, mints/burns shares, and (for deposits) calls `onClaimDeposit` so FM transfers GDA units from itself to the receiver. **Shares mint at claim time; the yield stream starts at claim time** (design decision D2).

`pendingDepositAssets` and `claimableRedeemAssets` coexist in the vault's underlying balance — the `totalPendingDepositAssets` / `totalClaimableRedeemAssets` counters partition them. Don't conflate the two. `previewDeposit/Mint/Redeem/Withdraw` revert (required for fully async vaults).

### Sync family — `StableYieldSyncVault` + `SyncFundManager`

OZ `ERC4626` + `ReentrancyGuard`. No epoch machinery; ERC-7540/7575 dropped entirely. Design in `docs/sync-vault/design.md` (11 numbered decisions). Pivoted four times (2026-05-19 async-symmetric refactor; 2026-05-21 self-funded stream; 2026-05-22 unified rebalance primitive + `harvest()` dropped; 2026-05-26 NAV clamp / `trackedPrincipal` dropped → floating share). Cumulative shape:

- **FM is the sole capital custodian + NAV authority (decision 11).** `EXTERNAL_VAULT`, the external-vault shares, and the super-token reserve all live in `SyncFundManager` (no `trackedPrincipal` counter). `StableYieldSyncVault` holds no assets — it pulls underlying from the caller, forwards it to the FM, mints/burns shares, and proxies `totalAssets`/`max*` to FM views. Same split as async (FM custodies capital; vault is the share face).
- **Floating share, reserve-inclusive NAV, NO clamp (decision 1, revised 2026-05-26).** `totalAssets = EXTERNAL_VAULT.maxWithdraw(FM) + scaledYieldAssetsBalance() + UNDERLYING_ASSET.balanceOf(FM)` — a plain sum of recoverable balances, no clamp, no `trackedPrincipal`. The share **floats** (`totalAssets/supply`, OZ standard): a holder's total return = the external vault's real yield, split into the streamed promised rate (the "stable" component) PLUS share appreciation for the excess (`external − promised`). Single-counted (the stream is funded by pulling from external, lowering `maxWithdraw(FM)` by exactly the streamed amount; appreciation is the residual). No protocol-owned buffer excluded from price — the external surplus accrues to holders. Immediate honest loss pass-through (no cushion). Withdraws are OZ-proportional (`shares · NAV / supply`, floor); no `trackedPrincipal` decrement — stayers stay whole automatically. The earlier `min(trackedPrincipal, …)` clamp / ≈1:1-peg model was dropped 2026-05-26 (see `docs/sync-vault/design.md §Revision 2026-05-26`).
- **Unified rebalance primitive (2026-05-22, trim gated 2026-05-28).** `_rebalanceYieldAssets()` is **abstract** on `FundManagerBase`; each family supplies its own. `SyncFundManager` override sources from the external position: `deficit > 0` pulls `min(need, EXTERNAL_VAULT.maxWithdraw(FM))` (deficit-only — the surplus stays compounding; under impairment the same pull continues deeper into the external position, loss → the unclamped NAV falls); `deficit < 0` **best-effort trim** — gated on `EXTERNAL_VAULT.maxDeposit(FM) >= underlyingNeeded`, downgrades excess + redeposits underlying into the external vault; if external deposits are closed (`maxDeposit == 0`), the **whole branch is skipped** and the excess stays as above-target super-token slack in the reserve (next rebalance retries; Inv. 7 / A.2 preserved hard, D.4 weakened to "best-effort, gated on external `maxDeposit`"). Known limitation: a non-compliant external whose `deposit` reverts despite `maxDeposit > 0` still bricks (pinned by `test_withdraw_brickedByNonCompliantExternal`). Residual positive deficit at terminal impairment is tolerated (no `_recalibrateFlow()` guards — terminal impairment is handled by the vault-level full pause, see below). Runs from `onDeposit`, `onWithdraw` (top + post-payout), and the inherited operator entrypoints (`setStableYieldRate`, `setGuaranteedFlowDuration`, `ensureYieldFlowDuration`).
- **Stream pre-funded from each deposit (decision 4, revised).** `onDeposit` grants `_toUnit(assets)` units, runs `_rebalanceYieldAssets()` (deficit-only), upgrades the residual `min(ceil(deficit/SCALING_FACTOR)+1, assets)` of the incoming underlying into the reserve, deposits the remainder into the external vault, then `_recalibrateFlow()` (unconditional) — the stream starts at deposit time including the first deposit (NAV-neutral at entry). The hook is unreachable under terminal external impairment because the vault is paused there (`maxDeposit == 0`), so the recalibrate is never met with a drained, un-refillable reserve.
- **`onWithdraw(holder, shares, totalSharesOwned, supplyBeforeBurn, receiver, redeemingAssets)`** (the async settle-netting analog, rewritten 2026-05-29 / OQ #5): proportional unit decrease (→ required reserve drops); **shares-proportional reserve slice (R-shares)** `fromReserve = ceil(scaledYieldAssetsBalance() · shares / supplyBeforeBurn)` clamped at `redeemingAssets` is downgraded — combined with OZ's `redeemingAssets = shares · NAV / supply` (floor), `fromExternal = f · ext.maxWithdraw + f · raw ≤ ext.maxWithdraw(FM)` for a compliant external, so F.2 (`request ≤ max* ⇒ never reverts`) holds end-to-end under any **loss** state; the external remainder is drawn from the external vault (reverts only on a non-compliant external — known limit pinned by `test_withdraw_lateEntrantAfterGain_brickedByNonCompliantExternal`); **post-payout `_rebalanceYieldAssets()`** cures any deficit (`f > f_u`, pulls from external; D.1 best-effort) or surplus (`f < f_u`, trims back to external — **best-effort, gated on `EXTERNAL_VAULT.maxDeposit(FM)`**, OQ #4); `_recalibrateFlow()` runs at the end (flow rate decreases ⇒ releases GDA buffer ⇒ never reverts from a drained reserve). The pre-payout `_rebalanceYieldAssets()` is **removed** — it was the eviction mechanism that broke the redeemer's reserve slice under loss. Decision 5's "preserves stayers' horizon by construction" was softened to "best-effort, via the post-payout rebalance (D.1)" — the "by construction" claim only held under the dropped clamp's uniform `units / share`. No `trackedPrincipal` decrement (removed 2026-05-26) — `redeemingAssets` is OZ's pro-rata `shares · NAV / supply`. "Partial impairment" terminology dropped: use **loss** (`ext.maxWithdraw(FM) > 0`, principal lost) vs **terminal impairment** (`== 0` → D.2 pause).
- **No `harvest()` / no `fundReserve` (2026-05-22).** Solvency between user activity is operator-only via the inherited `ensureYieldFlowDuration()` (`FUND_OPERATOR_ROLE`). Per-op hooks keep the stream solvent on any user activity; the operator must call `ensureYieldFlowDuration()` between periods of inactivity. **Terminal external impairment (`EXTERNAL_VAULT.maxWithdraw(FM) == 0` while the FM holds a position) is a full pause** (`StableYieldSyncVault._isExternallyPaused()` → all four `max*` = 0; Revision 2026-05-27): no deposits/withdrawals, the stream keeps paying from the reserve until naturally liquidated. There are **no `_recalibrateFlow()` guards** — the user hooks can't run while paused; operator setters are allowed to revert under terminal impairment (accepted). Operator's only sustainability lever under impairment is `setStableYieldRate` (and `setStableYieldRate(0)` always works — a zero-flow recalibrate is a *close*, no GDA buffer needed).
- **Custody hazard invariant (design.md Inv. 7).** Principal never rests in the FM as raw underlying across calls (deployed to external or upgraded within the same call) or the base rebalance silently consumes it.
- **New audit surfaces from the pivot:** with the clamp gone, donations (super-token + raw underlying to the FM) raise NAV and the share price — but only for existing holders, so they are irrational gifts, not attacks; the genuine residual is the classic ERC-4626 first-deposit inflation attack, mitigated by `StableYieldSyncVault._decimalsOffset()` returning a hardcoded `12` (landed 2026-05-27 — `10 ** 12` attack-cost multiplier, 18-dec shares for the 6-dec USDC deployment; offset alone, no dead-shares seed, min-shares-minted guard deferred). Share price ticks between rebalances and floats with external performance (timing/MEV — mitigated by per-op rebalance + frequent operator `ensureYieldFlowDuration()`); pathological `rate × guaranteedFlowDuration` can make the pre-fund exceed the deposit; a deposit into an impaired vault enters at the impaired (below-entry) NAV but doesn't transfer value beyond what the share price already reflects. All in `docs/sync-vault/design.md §Security`.
- `maxDeposit/maxMint` capped by `FUND_MANAGER.maxExternalDeposit()`; `maxWithdraw/maxRedeem` capped by `FUND_MANAGER.totalManagedAssets()` (the reserve-inclusive unclamped NAV; 4626-honest, never bricks ≤ max*). **All four are forced to 0 under terminal external impairment** (`_isExternallyPaused()` — gated on the FM holding a position so the empty-vault bootstrap isn't paused; `FUND_MANAGER.maxExternalVaultWithdraw()` exposes `EXTERNAL_VAULT.maxWithdraw(FM)`). `previewDeposit/Mint/Redeem/Withdraw` work synchronously (OZ default — they do **not** revert, unlike the async vault).

### Stable-yield mechanism (`FundManagerBase`, both families)

- Underlying (e.g. USDC) is upgraded to a Superfluid super-token (`YIELD_ASSET`, e.g. USDCx) and held as a "yield reserve."
- `_flowRatePerUnit = SCALING_FACTOR · stableYieldRate / (YEAR · BP_DENOMINATOR)`. Total flow = `_flowRatePerUnit · POOL.getTotalUnits()`.
- `guaranteedFlowDuration` is the forward-solvency horizon: FM rebalances yield-asset balance so the stream is funded for at least that long. `MIN_GUARANTEED_FLOW_DURATION = 1 days` is a sanity floor.
- `SCALING_FACTOR = 10 ** (18 − underlyingDecimals)` lifts underlying amounts into 18-dec super-token amounts. Hard-coded math currently assumes <18-dec underlyings (see `FIXME`s in `FundManagerBase.sol`).
- Async-only operator capital management: `give` / `take` deploy unutilized assets externally; the returned value is reported back via `workingAssets` on the next `closeEpoch`. The sync vault replaces this leg with the external ERC-4626.

### Shares & roles

- Shares are transferable in both families. The vault's `_update` hook calls `FundManagerBase.onShareTransfer(from, to, value)` on shareholder-to-shareholder transfers (skipping mint/burn and vault-custody legs); FM moves a proportional slice of GDA pool units so the yield stream follows the shares. **Units are granted on nominal underlying contributed (`_toUnit(assets) = assets / RAW_PER_UNIT`), so the streamed yield tracks the principal each holder put in (the "Alice deposits 100 USDC at 5% → receives 5 USDCx/year, exits at 105 USDC if external earned 10%" narrative). Under the sync vault's floating share `units / share` is intentionally NOT a global constant — equal-dollar deposits buy equal units but unequal shares once NAV departs from `supply · RAW_PER_UNIT`; the residual `external − promised` is delivered via share appreciation (the two-part total-return decomposition). Restated in `docs/sync-vault/design.md` Invariant 6 (2026-05-28), pinned by the `test_prop_units*` suite.**
- `convertToShares` / `convertToAssets`: async uses the *last settled* epoch rate (1e18 before first settlement); sync uses the OZ ERC-4626 default off `totalAssets()`.
- Roles: `FUND_OPERATOR_ROLE` (inherited base setters `setStableYieldRate`, `ensureYieldFlowDuration`; async-extra: epoch ops + `give`/`take` capital movement; the sync FM has no extra operator-only entrypoints — no `fundReserve`), `DEFAULT_ADMIN_ROLE` (`setGuaranteedFlowDuration`), `VAULT_ROLE` (granted to the vault for its FM hooks).

## Dependencies & remappings

`lib/` is git submodules (`forge install`). Subtleties in `remappings.txt`:

- `@openzeppelin/contracts/` and `@openzeppelin-v5/contracts/` **both** resolve to `lib/openzeppelin-contracts-v5/contracts/` — but only `@openzeppelin-v5/` is declared in the root `remappings.txt`; `@openzeppelin/contracts/` comes from the submodule's own nested `remappings.txt`. The vaults import mostly via `@openzeppelin/contracts/...`, the FundManagers mostly via `@openzeppelin-v5/contracts/...` (`Math` is imported via `@openzeppelin/` everywhere) — same code; don't "fix" one to match the other.
- Superfluid contracts come from `lib/superfluid-protocol-monorepo/packages/ethereum-contracts/`.
- ERC-7540 reference interfaces are vendored locally in `src/interfaces/vault/async/` (not pulled from the `ERC-7540-Reference` lib).

## Tests

Three-level base hierarchy, all wired through the `script/StableYieldVaultDeployer.sol` library (now exposing `deployAsyncVault` / `deploySyncVault`):

- `test/vault/base/StableYieldVaultTestBase.t.sol` (`is Test`) — **shared** base for both families; deploys the Superfluid framework + a 6-dec USDC wrapper super-token in `setUp`.
- `test/vault/async/AsyncVaultTestBase.t.sol` (`is StableYieldVaultTestBase`) — async base; deploys via `deployAsyncVault`. Used by `StableYieldAsyncVaultTest` and `AsyncFundManagerTest`.
- `test/vault/sync/SyncVaultTestBase.t.sol` (`is StableYieldVaultTestBase`) — sync base; deploys via `deploySyncVault` and wires a configurable `test/mocks/MockERC4626.sol` as the external vault. Used by `StableYieldSyncVaultTest`.

## Docs

- `docs/async-vault/flow/{deposit,redeem,settlement}-flow.md` — authoritative for the async lifecycle (sequence diagrams + step-by-step semantics + invariants). Read before changing epoch logic.
- `docs/sync-vault/design.md` (locked decisions + invariants + security) and `docs/sync-vault/flow/{deposit,withdraw}-flow.md` — authoritative for the sync vault.
- `docs/glossary.md` defines terms for both families (epoch, era, working/unutilized/depositing/redeeming/yield assets; external vault, external surplus, floating share / reserve-inclusive NAV, pre-funded stream, `_rebalanceYieldAssets`; `trackedPrincipal` / `buffer` / `share peg` are retired stubs from the dropped clamp model).
