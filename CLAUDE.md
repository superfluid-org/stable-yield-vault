# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Foundry project; `solc 0.8.34`, optimizer on (200 runs).

- `forge build` — compile (CI uses `forge build --sizes`)
- `forge test -vvv` — run all tests
- `forge test --match-contract StableYieldAsyncVaultTest --match-test test_<name>` — single test
- `forge test --match-path test/FundManager.t.sol` — single file
- `forge fmt` (CI runs `forge fmt --check`) — formatter is enforced; uses 120-col, bracket spacing, sorted imports, blank-line between contracts
- `forge coverage --report lcov` — produces `lcov.info` (already tracked at repo root)
- CI uses `FOUNDRY_PROFILE=ci` (identical settings to default; the variable just selects the profile).

Tests deploy a full Superfluid framework in `setUp` via `SuperfluidFrameworkDeployer`, which is slow — prefer running a focused subset while iterating.

## Architecture

Two pinned contracts implement an ERC-7540 asynchronous vault that pays a **stable** (capped/smoothed) yield via a Superfluid GDA stream. Roles: `StableYieldAsyncVault` does ERC-7540 accounting; `FundManager` (FM) does treasury, the GDA pool, and yield-flow plumbing.

### Vault ↔ FundManager pinning

`StableYieldAsyncVault`'s constructor deploys its `FundManager` with `msg.sender == vault`. The FM grants `VAULT_ROLE` to that address and pins the pair as immutable. There is no factory or proxy — read `StableYieldAsyncVault` first; FM is meaningless in isolation.

### Epoch lifecycle (forward-priced)

A request → settle → claim cycle, gated by an operator:

1. `requestDeposit` / `requestRedeem` — investor enters; assets escrow in vault; shares for redeems are pulled from the owner; FM decreases the redeemer's GDA units. Reverts with `EPOCH_SETTLEMENT_IN_PROGRESS` while a snapshot is open.
2. `FundManager.closeEpoch(workingAssets)` (FM operator) — snapshots `{epoch, depositingAssets, redeemingShares, rate}` in the vault, increments `currentEpoch`. NAV = `workingAssets + unutilizedAssetsBalance() + scaledYieldAssetsBalance()`. Rate uses an *effective supply* = `totalSupply + unclaimedDepositShares − unclaimedRedeemShares` to correct for the gap between settlement (assets move) and claim (shares mint/burn).
3. `FundManager.settleEpoch()` — vault nets deposits vs. redeems: surplus pushed to FM; deficit pulled from FM (downgrades super-token). FM grants itself pool units for the epoch's deposits, then `_recalibrateFlow()`. Settlement is gated by `canSettleEpoch()` precondition checks.
4. `deposit`/`mint`/`redeem`/`withdraw` — claim. Vault lazy-settles the controller's pending request at the locked epoch rate, mints/burns shares, and (for deposits) calls `onClaimDeposit` so FM transfers GDA units from itself to the receiver. **Shares mint at claim time; the yield stream starts at claim time** (design decision D2).

`pendingDepositAssets` and `claimableRedeemAssets` coexist in the vault's underlying balance — the `totalPendingDepositAssets` / `totalClaimableRedeemAssets` counters partition them. Don't conflate the two.

### Stable-yield mechanism (FundManager)

- Underlying (e.g. USDC) is upgraded to a Superfluid super-token (`YIELD_ASSET`, e.g. USDCx) and held as a "yield reserve."
- `_flowRatePerUnit = SCALING_FACTOR · stableYieldRate / (YEAR · BP_DENOMINATOR)`. Total flow = `_flowRatePerUnit · POOL.getTotalUnits()`.
- `guaranteedFlowDuration` is the forward-solvency horizon: FM rebalances yield-asset balance so the stream is funded for at least that long. `MIN_GUARANTEED_FLOW_DURATION = 1 days` is a sanity floor.
- `SCALING_FACTOR = 10 ** (18 − underlyingDecimals)` lifts underlying amounts into 18-dec super-token amounts. Hard-coded math currently assumes <18-dec underlyings (see `FIXME` in `setStableYieldRate` / constructor about 18-dec assets).
- Operator capital management: `give` / `take` are unrelated to settlement and let the operator deploy unutilized assets externally. Returned value is reported back via `workingAssets` on the next `closeEpoch`.

### ERC-7540 specifics

- `previewDeposit/Mint/Redeem/Withdraw` revert (required for fully async vaults).
- Shares are **non-transferable** — `transfer`/`transferFrom` revert with `SHARES_NON_TRANSFERABLE`.
- `convertToShares` / `convertToAssets` use the *last settled* epoch rate, falling back to 1e18 before the first settlement.

### Roles

`FUND_OPERATOR_ROLE` (epoch ops + capital movement), `DEFAULT_ADMIN_ROLE` (sets `guaranteedFlowDuration`), `VAULT_ROLE` (granted to the vault for the FM hooks `onClaimDeposit`, `onRequestRedeem`).

## Dependencies & remappings

`lib/` is git submodules (`forge install`). Subtleties in `remappings.txt`:

- `@openzeppelin/contracts/` and `@openzeppelin-v5/contracts/` **both** map to `lib/openzeppelin-contracts-v5/`. The vault imports via `@openzeppelin/contracts/...`, FM via `@openzeppelin-v5/contracts/...` — same code; don't "fix" one to match the other.
- Superfluid contracts come from `lib/superfluid-protocol-monorepo/packages/ethereum-contracts/`.
- ERC-7540 reference interfaces are vendored locally in `src/interfaces/vault/` (not pulled from the `ERC-7540-Reference` lib).

## Docs

`docs/flow/{deposit,redeem,settlement}-flow.md` are authoritative for the lifecycle (sequence diagrams + step-by-step semantics + invariants). Read these before changing epoch logic. `docs/glossary.md` defines terms (epoch, era, working/unutilized/depositing/redeeming/yield assets).
