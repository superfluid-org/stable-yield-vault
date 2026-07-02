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
- Echidna: `make echidna-async-smoke` (50k-tx, `test/echidna/EchidnaStableYieldAsyncVault.sol`, async, config `echidna.async.yaml`) / `make echidna-async-long` (1M-tx) / `make echidna-sync-smoke` / `make echidna-sync-long` (`test/echidna/EchidnaStableYieldSyncVault.sol`, sync, config `echidna.sync.yaml`) / `make echidna-clean` (wipe corpus). Both harnesses inherit the shared Superfluid bootstrap from the abstract `test/echidna/base/EchidnaVaultHarnessBase.sol` and do a full Superfluid deploy in their constructor. Targets export `FOUNDRY_PROFILE=echidna`, which pins all 16 Superfluid external libraries to fixed addresses (`foundry.toml`); the base's `_plantSuperfluidLibraries()` then etches each library's runtime bytecode at its pinned address before deploying the framework. Requires `echidna`, `slither`, `crytic-compile`, and `solc 0.8.34` on `PATH`.

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

OZ `ERC4626` + `ReentrancyGuard`. No epoch machinery; ERC-7540/7575 dropped entirely. Authoritative docs: `docs/sync-vault/` (`design.md` model + decisions, `invariants.md` properties, `flow/`). Shape:

- **The external is a Morpho Vault V2** — a non-conventional ERC-4626 whose four `max*` views are **hardcoded to 0** (gates can't be guaranteed revert-free) and which has **no instant-liquidity view**. The integration never consults the external's `max*`: position value via `EXTERNAL_VAULT.previewRedeem(balanceOf(FM))` (`externalPositionValue()`), deposit/withdraw eligibility via the gate views (`canDepositExternal()` = `canSendAssets(FM) && canReceiveShares(FM)`; `canWithdrawExternal()` = `canSendShares(FM) && canReceiveAssets(FM)`), vendored interface `src/interfaces/vault/sync/IMorphoVaultV2.sol`. A curator-set gate MAY revert → the FM `can*External` views (and vault `max*`) revert too (accepted).
- **FM is the sole capital custodian + NAV authority.** `EXTERNAL_VAULT`, the external-vault shares, and the super-token reserve all live in `SyncFundManager` (no principal counter). `StableYieldSyncVault` holds no assets — it pulls underlying from the caller, forwards it to the FM, mints/burns shares, and proxies `totalAssets`/`max*` to FM views. Same split as async (FM custodies capital; vault is the share face).
- **Floating share, reserve-inclusive NAV, no clamp.** `totalAssets = EXTERNAL_VAULT.previewRedeem(EXTERNAL_VAULT.balanceOf(FM)) + scaledYieldAssetsBalance() + UNDERLYING_ASSET.balanceOf(FM)` — a plain sum of recoverable balances. The share **floats** (`totalAssets/supply`, OZ standard): a holder's total return = the external vault's real yield, split into the streamed promised rate (the "stable" component) PLUS share appreciation for the excess (`external − promised`). Single-counted (the stream is funded by pulling from external, lowering the position value by exactly the streamed amount; appreciation is the residual). The external surplus accrues to holders. Loss passes through immediately and honestly. Withdraws are OZ-proportional (`shares · NAV / supply`, floor); no principal decrement — stayers stay whole automatically.
- **Unified rebalance primitive.** `_rebalanceYieldAssets()` is **abstract** on `FundManagerBase`; each family supplies its own. `SyncFundManager` override sources from the external position: `deficit > 0` pulls `min(deficit/SCALING_FACTOR + 1, externalPositionValue())` (deficit-only — the surplus stays compounding; under impairment the same pull continues deeper into the position, loss → NAV falls), **skipped when the pull is below `MIN_EXTERNAL_PULL` (10 atoms)** — the production Base USDCx wrapper auto-supplies its reserves into Aave v3, which reverts dust supplies (scaled amount rounds to 0), so a 1-atom pull would brick the calling op; the skipped sub-dust shortfall self-corrects (invariant D.1 is `deficit < MIN_EXTERNAL_PULL · SCALING_FACTOR`, not `≤ 0`). The cap is the position's **value**, not liquidity (none exists), so the pull **can revert on an external liquidity shortfall and brick the calling op** until liquidity returns (`forceDeallocate` unsticks; the standing post-deposit deficit is ~one GDA stream buffer, so the liveness threshold is buffer-scale liquidity). `deficit < 0` **best-effort trim** — early-returns for sub-`SCALING_FACTOR` surplus, otherwise gated on `canDepositExternal()`, downgrades and redeposits **exactly** `underlyingNeeded` into the external vault (not `balanceOf(FM)` — that would sweep in-flight raw underlying mid-call, e.g. the user's just-arrived `assets` during `onDeposit`, and brick the outer call). If the deposit-side gates are blocked, the whole branch is skipped (excess stays as above-target reserve slack; next rebalance retries idempotently). Known limitation: a non-compliant external whose `deposit` reverts despite open gates still bricks the calling op. Residual positive deficit at terminal impairment is tolerated (handled by the vault-level full pause, see below). Runs from `onDeposit`, `onWithdraw` (post-payout), and the operator setters.
- **Stream pre-funded from each deposit.** `onDeposit` grants `_toUnit(assets)` units, runs `_rebalanceYieldAssets()`, upgrades the residual `min(max(deficit/SCALING_FACTOR + 1, MIN_EXTERNAL_PULL), assets)` of the incoming underlying into the reserve (the `MIN_EXTERNAL_PULL` floor keeps the upgrade wrapper-acceptable and repairs any skipped sub-dust deficit; sub-`MIN_EXTERNAL_PULL` deposits onto an empty reserve can't fund the GDA buffer and revert), deposits the remainder into the external vault, then `_recalibrateFlow()` — the stream starts at deposit time including the first deposit (NAV-neutral at entry). The hook is unreachable while externally paused (`maxDeposit == 0`).
- **`onWithdraw(holder, shares, totalSharesOwned, supplyBeforeBurn, receiver, redeemingAssets)`** — proportional unit decrease (→ required reserve drops); then pays `redeemingAssets` sourced in priority order: (1) **any resting raw underlying** (only ever a donation; measured pre-downgrade, spent first, capped at the external slice); (2) a **shares-proportional reserve slice** `fromReserve = ceil(scaledYieldAssetsBalance() · shares / supplyBeforeBurn)` clamped at `redeemingAssets` (downgraded); (3) the **external vault** for the remainder — pulled **FM-first** (`withdraw(fromExternal, FM, FM)`, so only the FM ever needs to clear Morpho's `receiveAssetsGate`), then one `safeTransfer(receiver, redeemingAssets)` (the three legs sum exactly). Combined with OZ's floor-priced `redeemingAssets = shares · NAV / supply`, the external leg is `≤` the position's value for a compliant external — but whether it *lands* also depends on Morpho's instant liquidity (no view): a within-`max*` request can revert at the external leg (accepted deviation). Then **post-payout `_rebalanceYieldAssets()`** (cure deficit/surplus) and `_recalibrateFlow()` at the end (flow rate decreases ⇒ releases GDA buffer ⇒ never reverts from a drained reserve). No principal decrement — `redeemingAssets` is OZ's pro-rata.
- **No `harvest()` / no `fundReserve`.** Solvency between user activity is operator-only via the inherited `ensureYieldFlowDuration()` (`FUND_OPERATOR_ROLE`). Per-op hooks keep the stream solvent on any user activity; the operator must call `ensureYieldFlowDuration()` between periods of inactivity. **External pause: `totalSupply() > 0 && (externalPositionValue() == 0 || !canWithdrawExternal())`** (`StableYieldSyncVault._isExternallyPaused()` → all four `max*` = 0): no deposits/withdrawals, the stream keeps paying from the reserve until naturally liquidated. Triggers: terminal impairment (total loss — price→0 or share-burn, both read 0 through `previewRedeem(balanceOf)`) or Morpho exit gates blocking the FM. A pure **liquidity freeze does NOT pause** (no liquidity view) — the affected withdrawal reverts at the external leg instead. The gate keys on `totalSupply() > 0` (are there depositors to protect?) rather than the FM's external share balance — a balance gate would be blind to a total-loss share-burn, and a dust external-share donation can only *raise* the position value. There are **no `_recalibrateFlow()` guards** — the user hooks can't run while paused; operator setters are allowed to revert under the pause (accepted). The operator's only sustainability lever under impairment is `setStableYieldRate` (and `setStableYieldRate(0)` always works — a zero-flow recalibrate is a *close*, no GDA buffer needed).
- **Custody hazard invariant (invariants.md A.2).** Principal never rests in the FM as raw underlying across calls (deployed to external or upgraded within the same call) or the base rebalance silently consumes it.
- **Security surfaces:** donations (super-token + raw underlying to the FM) raise NAV and the share price — but only for existing holders, so they are irrational gifts, not attacks (a raw-underlying donation is realized first on the next withdraw, so it reaches holders rather than being stranded). The genuine residual is the classic ERC-4626 first-deposit inflation attack, mitigated by `StableYieldSyncVault._decimalsOffset()` returning a hardcoded `12` (`10 ** 12` attack-cost multiplier, 18-dec shares for the 6-dec USDC deployment). Share price ticks between rebalances and floats with external performance (timing/MEV — mitigated by per-op rebalance + frequent operator `ensureYieldFlowDuration()`); **NAV is a live spot read of `EXTERNAL_VAULT.previewRedeem(balanceOf(FM))` (no TWAP/clamp), so the external MUST have a non-manipulable, accrual-priced share price — Morpho V2 satisfies this (`maxRate`-capped growth, once-per-tx accrual ⇒ not donation/flashloan-spikable; losses pass through immediately, by design)**; **`maxWithdraw`/`maxRedeem` overestimate under an external liquidity crunch** (no liquidity view — accepted ERC-4626 deviation, `forceDeallocate` unsticks); pathological `rate × guaranteedFlowDuration` (pre-fund exceeding the deposit) is bounded on-chain by the `rate × duration ≤ YEAR × BP_DENOMINATOR` guard in the constructor + both operator setters (`INVALID_YIELD_DURATION_COMBINATION`); a deposit into an impaired vault enters at the impaired (below-entry) NAV but doesn't transfer value beyond what the share price already reflects. All in `docs/sync-vault/design.md`.
- `maxDeposit/maxMint` are **binary**: `type(uint256).max` while `FUND_MANAGER.canDepositExternal()` (Morpho has no amount cap), else 0. `maxWithdraw/maxRedeem` capped by `FUND_MANAGER.totalManagedAssets()` (the reserve-inclusive NAV — the position's *value*, so they can overestimate vs. Morpho's instant liquidity). **All four are forced to 0 under the external pause** (`_isExternallyPaused()` — gated on `totalSupply() > 0` so the empty-vault bootstrap isn't paused). `previewDeposit/Mint/Redeem/Withdraw` work synchronously (OZ default — they do **not** revert, unlike the async vault).

### Stable-yield mechanism (`FundManagerBase`, both families)

- Underlying (e.g. USDC) is upgraded to a Superfluid super-token (`YIELD_ASSET`, e.g. USDCx) and held as a "yield reserve."
- `_flowRatePerUnit = SCALING_FACTOR · stableYieldRate / (YEAR · BP_DENOMINATOR)`. Total flow = `_flowRatePerUnit · POOL.getTotalUnits()`.
- `guaranteedFlowDuration` is the forward-solvency horizon: FM rebalances yield-asset balance so the stream is funded for at least that long. `MIN_GUARANTEED_FLOW_DURATION = 1 days` is a sanity floor.
- `SCALING_FACTOR = 10 ** (18 − underlyingDecimals)` lifts underlying amounts into 18-dec super-token amounts. Supported underlying decimals are `[6, 18]` (constructor reverts `UNSUPPORTED_DECIMALS` otherwise); the hard-coded `1e12 = SCALING_FACTOR · RAW_PER_UNIT` and the 18-dec edge need review for a non-6-dec underlying (see `docs/sync-vault/open-questions.md`).
- Async-only operator capital management: `give` / `take` deploy unutilized assets externally; the returned value is reported back via `workingAssets` on the next `closeEpoch`. The sync vault replaces this leg with the external ERC-4626.

### Shares & roles

- Shares are transferable in both families. The vault's `_update` hook calls `FundManagerBase.onShareTransfer(from, to, value)` on shareholder-to-shareholder transfers (skipping mint/burn and vault-custody legs); FM moves a proportional slice of GDA pool units so the yield stream follows the shares (a zero-units sender — e.g. a dust position whose units were `Ceil`-zeroed by a near-full redeem — is **skipped, not reverted**, so the residual shares stay transferable). **Units are granted on nominal underlying contributed (`_toUnit(assets) = assets / RAW_PER_UNIT`), so the streamed yield tracks the principal each holder put in (the "Alice deposits 100 USDC at 5% → receives 5 USDCx/year, exits at 105 USDC if external earned 10%" narrative). Under the sync vault's floating share `units / share` is intentionally NOT a global constant — equal-dollar deposits buy equal units but unequal shares once NAV departs from `supply · RAW_PER_UNIT`; the residual `external − promised` is delivered via share appreciation (the two-part total-return decomposition; see `docs/sync-vault/invariants.md` C.1).**
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
- `test/vault/sync/SyncVaultTestBase.t.sol` (`is StableYieldVaultTestBase`) — sync base; deploys via `deploySyncVault` and wires a configurable `test/mocks/MockMorphoVaultV2.sol` as the external vault (Morpho V2 semantics: `max*` hardcoded 0, four configurable gate views, per-call `liquidityCap` enforced as an unadvertised withdraw revert). Used by `StableYieldSyncVaultTest`.

## Docs

- `docs/async-vault/flow/{deposit,redeem,settlement}-flow.md` — authoritative for the async lifecycle (sequence diagrams + step-by-step semantics + invariants). Read before changing epoch logic.
- `docs/sync-vault/` — authoritative for the sync vault: `design.md` (model + decisions + contracts + security), `invariants.md` (property catalogue), `flow/{deposit,withdraw}-flow.md` (step-by-step), `open-questions.md`.
- `docs/glossary.md` defines terms for both families (epoch, era, working/unutilized/depositing/redeeming/yield assets; external vault, external surplus, floating share / reserve-inclusive NAV, pre-funded stream, `_rebalanceYieldAssets`).
