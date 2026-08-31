# CLAUDE.md

Guidance for Claude Code when working in this repository. The architecture is documented for
humans in `docs/` — **read [`docs/architecture.md`](docs/architecture.md) first**, then the
family docs; don't duplicate them here.

## Commands

Foundry project; `solc 0.8.34`, optimizer on (200 runs).

- `forge build` — compile (CI uses `forge build --sizes`)
- `forge test -vvv` — run all tests (slow `setUp`: a full Superfluid framework deploy per suite — prefer focused runs while iterating)
- `forge test --match-contract StableYieldSyncVaultTest --match-test test_<name>` — single sync test; async suite is `StableYieldAsyncVaultTest`
- `forge test --match-path test/vault/async/AsyncFundManager.t.sol` — single file
- `forge fmt` — **enforced in CI** (`forge fmt --check`): 120-col, bracket spacing, sorted imports, blank line between contracts
- `forge coverage --report lcov` — `lcov.info` is gitignored
- `make fork-test` — Base-mainnet fork suite (`BASE_MAINNET_RPC_URL`, optional `BASE_FORK_BLOCK_NUMBER`)
- `make echidna-{async,sync}-{smoke,long}` / `make echidna-clean` — property fuzzing; needs `echidna`, `slither`, `crytic-compile`, `solc 0.8.34` on `PATH`. Uses `FOUNDRY_PROFILE=echidna` (pins the 16 Superfluid libraries at fixed addresses; the harness base etches their bytecode there).
- CI (`.github/workflows/test.yml`) runs fmt-check, build, test with `FOUNDRY_PROFILE=ci` (identical to default).

## Where things are

| Topic | Read |
|---|---|
| System overview, both families, engine maths, roles, tests | `docs/architecture.md` |
| Sync vault model / decisions / security | `docs/sync-vault/design.md`, `invariants.md`, `flow/` |
| Async epoch lifecycle (read before touching epoch logic) | `docs/async-vault/flow/{deposit,redeem,settlement}-flow.md`, `invariants.md` |
| Macros / EIP-2771 / Permit2 | `docs/*/flow/batched-*.md`, `docs/integration-guide.md` §6 |
| Terms | `docs/glossary.md` |
| Operator / admin behaviour | `docs/operator-guide.md` |
| Deploy scripts + per-network config | `docs/deployment.md`, `script/config/NetworkConfig.sol` |
| Live addresses | `docs/reference-deployments.md` |

## Repo conventions and gotchas

- **Two vault families share `src/common/FundManagerBase.sol`.** `AsyncFundManager is
  FundManagerBase, IAsyncFundManager`; `SyncFundManager is FundManagerBase, ISyncFundManager`.
  `_rebalanceYieldAssets()` is abstract — each family sources the reserve differently.
- **The vault deploys its FundManager** in its constructor (`VAULT = msg.sender`, `VAULT_ROLE`).
  Never deploy an FM standalone; tests go through `script/StableYieldVaultDeployer.sol`
  (`deployAsyncVault` / `deploySyncVault`).
- **Underlying is pinned to 6 decimals** by both vault constructors (`INVALID_CONFIGURATION`).
  The base computes `SCALING_FACTOR`/`RAW_PER_UNIT` generically for `[6, 18]` but `1e12`,
  `_decimalsOffset() = 12` and `VIRTUAL_SHARES = 1e12` assume 6.
- **Both vaults are `ERC2771Context`** — use `_msgSender()`, never `msg.sender`, in user entry
  points. In fuzz tests that prank an "invalid caller", exclude `vault.trustedForwarder()`
  (pranking as the forwarder makes `_msgSender()` read the appended calldata).
- **Sync vault entry fee.** `DEPOSIT_FEE = 0.2e6` is skimmed to `TREASURY` in `_deposit`;
  `deposit(assets)` is gross, `mint(shares)` adds the fee on top; `preview*` include it.
- **Morpho V2 `max*` are hardcoded 0** — never consult them; use `externalPositionValue()` and
  the `can*External()` gate views. `MIN_EXTERNAL_PULL = 10` exists because the Base USDCx wrapper
  supplies to Aave, which reverts dust.
- **Custody hazard (sync A.2):** principal must never rest in the FM as raw underlying across
  calls — deploy or upgrade it within the same call.
- **Remappings:** `@openzeppelin/contracts/` and `@openzeppelin-v5/contracts/` both resolve to
  `lib/openzeppelin-contracts-v5/contracts/` — the first via the submodule's nested
  `remappings.txt`, the second via the root one. Different files use different prefixes; don't
  "fix" one to match the other. Superfluid comes from
  `lib/superfluid-protocol-monorepo/packages/ethereum-contracts/`. ERC-7540 interfaces are
  vendored in `src/interfaces/vault/async/`.
- **Docs cite code by function name, not line number.** Keep it that way; line citations rot.
- **`docs/*/security-notes/`** are internal AI-assisted reviews / fuzz reports with a banner —
  not a third-party audit. Don't present them as one.
- Deployment parameters are hard-coded per `chainId` in `script/config/NetworkConfig.sol`
  (no env-var config); `.env` only holds RPC URLs / explorer keys.
