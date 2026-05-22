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

OZ `ERC4626` + `ReentrancyGuard`. No epoch machinery; ERC-7540/7575 dropped entirely. Design in `docs/sync-vault/design.md` (11 numbered decisions). Pivoted three times (2026-05-19 async-symmetric refactor; 2026-05-21 self-funded stream; 2026-05-22 unified rebalance primitive + `harvest()` dropped). Cumulative shape:

- **FM is the sole capital custodian + NAV authority (decision 11).** `EXTERNAL_VAULT`, the external-vault shares, `trackedPrincipal`, and the super-token reserve all live in `SyncFundManager`. `StableYieldSyncVault` holds no assets — it pulls underlying from the caller, forwards it to the FM, mints/burns shares, and proxies `totalAssets`/`max*` to FM views. Same split as async (FM custodies capital; vault is the share face).
- **Reserve-inclusive NAV (decision 1, revised).** `totalAssets = min(trackedPrincipal, EXTERNAL_VAULT.maxWithdraw(FM) + scaledYieldAssetsBalance() + UNDERLYING_ASSET.balanceOf(FM))` — all recoverable terms inside the clamp so the compounding buffer AND every donation path (super-token OR raw underlying) are symmetrically absorbed. The share is ≈1:1 (not a hard peg): NAV-neutral at deposit, ticks below par between rebalances as the stream drains the reserve, honest loss pass-through via the `min(…)` floor. `trackedPrincipal -= trackedPrincipal · sharesBurned / supplyBeforeBurn` (floor) on withdraw keeps V/P constant through impaired exits.
- **Unified rebalance primitive (2026-05-22).** `_rebalanceYieldAssets()` is **abstract** on `FundManagerBase`; each family supplies its own. `SyncFundManager` override sources from the external position: `deficit > 0` pulls `min(need, EXTERNAL_VAULT.maxWithdraw(FM))` (uncapped at the surplus — under impairment eats into the principal-backing slice, loss → NAV clamp); `deficit < 0` downgrades excess + redeposits underlying into the external vault. Best-effort; residual positive deficit at terminal impairment is tolerated (callers guard their `_recalibrateFlow()`). Runs from `onDeposit` (pre-bump), `onWithdraw` (top + post-payout), and the inherited operator entrypoints (`setStableYieldRate`, `setGuaranteedFlowDuration`, `ensureYieldFlowDuration`).
- **Stream pre-funded from each deposit (decision 4, revised).** `onDeposit` grants `_toUnit(assets)` units, runs `_rebalanceYieldAssets()` (uncapped) against the OLD `trackedPrincipal`, bumps `trackedPrincipal += assets`, upgrades the residual `min(ceil(deficit/SCALING_FACTOR)+1, assets)` of the incoming underlying into the reserve, deposits the remainder into the external vault, then guarded `_recalibrateFlow()` — the stream starts at deposit time including the first deposit. `_recalibrateFlow()` is guarded so terminal impairment does not revert the deposit.
- **`onWithdraw(holder, shares, totalSharesOwned, supplyBeforeBurn, receiver, redeemingAssets)`** (the async settle-netting analog): pre-`_rebalanceYieldAssets()`; proportional unit decrease (→ required reserve drops); guarded `_recalibrateFlow()`; the **recalibration-freed reserve excess** `fromReserve = min(freedExcess, redeemingAssets)` is downgraded for the reserve slice (preserves stayers' horizon by construction); the external remainder `redeemingAssets − fromReserve` is drawn from the external vault (reverts only if illiquid, decision 5 revised); **post-payout `_rebalanceYieldAssets()`** trims residual freed excess back to external (Q1=B, 2026-05-22); proportional `trackedPrincipal` decrement.
- **No `harvest()` / no `fundReserve` (2026-05-22).** Solvency between user activity is operator-only via the inherited `ensureYieldFlowDuration()` (`FUND_OPERATOR_ROLE`). Per-op hooks keep the stream solvent on any user activity; the operator must call `ensureYieldFlowDuration()` between periods of inactivity. Both `setStableYieldRate` and `ensureYieldFlowDuration` in the base now guard their `_recalibrateFlow()` calls with `if (evaluateYieldAssetsDeficit() <= 0)` so they don't revert at terminal external impairment in the sync family. Operator's only sustainability lever under impairment is `setStableYieldRate`.
- **Custody hazard invariant (design.md Inv. 7).** Principal never rests in the FM as raw underlying across calls (deployed to external or upgraded within the same call) or the base rebalance silently consumes it.
- **New audit surfaces from the pivot:** reserve-inclusive NAV folds all donation paths (super-token + raw underlying) inside the min-clamp at `trackedPrincipal` so neither can inflate share price (locked 2026-05-22); share price ticks between rebalances (timing/MEV — mitigated by per-op rebalance + frequent operator `ensureYieldFlowDuration()`); pathological `rate × guaranteedFlowDuration` can make the pre-fund exceed the deposit; a deposit into a buffer-exhausted vault enters at the impaired NAV but doesn't transfer value beyond what the share price already reflects. All in `docs/sync-vault/design.md §Security`.
- `maxDeposit/maxMint` capped by `FUND_MANAGER.maxExternalDeposit()`; `maxWithdraw/maxRedeem` capped by `FUND_MANAGER.totalManagedAssets()` (the reserve-inclusive NAV; conservative lower bound, 4626-honest, never bricks ≤ max*). `previewDeposit/Mint/Redeem/Withdraw` work synchronously (OZ default — they do **not** revert, unlike the async vault).

### Stable-yield mechanism (`FundManagerBase`, both families)

- Underlying (e.g. USDC) is upgraded to a Superfluid super-token (`YIELD_ASSET`, e.g. USDCx) and held as a "yield reserve."
- `_flowRatePerUnit = SCALING_FACTOR · stableYieldRate / (YEAR · BP_DENOMINATOR)`. Total flow = `_flowRatePerUnit · POOL.getTotalUnits()`.
- `guaranteedFlowDuration` is the forward-solvency horizon: FM rebalances yield-asset balance so the stream is funded for at least that long. `MIN_GUARANTEED_FLOW_DURATION = 1 days` is a sanity floor.
- `SCALING_FACTOR = 10 ** (18 − underlyingDecimals)` lifts underlying amounts into 18-dec super-token amounts. Hard-coded math currently assumes <18-dec underlyings (see `FIXME`s in `FundManagerBase.sol`).
- Async-only operator capital management: `give` / `take` deploy unutilized assets externally; the returned value is reported back via `workingAssets` on the next `closeEpoch`. The sync vault replaces this leg with the external ERC-4626.

### Shares & roles

- Shares are transferable in both families. The vault's `_update` hook calls `FundManagerBase.onShareTransfer(from, to, value)` on shareholder-to-shareholder transfers (skipping mint/burn and vault-custody legs); FM moves a proportional slice of GDA pool units so the yield stream follows the shares.
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
- `docs/glossary.md` defines terms for both families (epoch, era, working/unutilized/depositing/redeeming/yield assets; external vault, trackedPrincipal, buffer, share peg, reserve-inclusive NAV, `_rebalanceYieldAssets`).
