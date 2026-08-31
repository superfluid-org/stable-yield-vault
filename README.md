# Stable Yield Vault

[![CI](https://github.com/superfluid-org/stable-yield-vault/actions/workflows/test.yml/badge.svg)](https://github.com/superfluid-org/stable-yield-vault/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Solidity 0.8.34](https://img.shields.io/badge/solidity-0.8.34-363636.svg)](foundry.toml)

ERC-4626 / ERC-7540 vaults that pay a **stable, operator-committed yield as a continuous
Superfluid stream**. Depositors put in a stablecoin (USDC), receive vault shares, and from that
moment their wallet balance of the wrapped super-token (USDCx) grows every second at the
promised annual rate — no claiming, no epochs to wait for the yield, no lock-up of the stream.

> **Status: technical preview.** The code is unaudited and the live deployments are demos run
> with EOA admin keys. Read [Trust assumptions](#trust-assumptions) before depositing anything.

## How it works

```
        USDC                    ┌──────────────────────┐   principal   ┌──────────────────┐
  user ────────► Vault (shares) │     FundManager      │──────────────►│ external yield   │
   ▲                            │  · custodies capital │◄──────────────│ source           │
   │  USDCx stream (GDA pool)   │  · USDCx reserve     │  real yield   │ (Morpho V2 / op) │
   └────────────────────────────│  · streams the rate  │               └──────────────────┘
                                └──────────────────────┘
```

1. Principal is routed to a yield source that earns the *real* return.
2. The FundManager keeps a small reserve of the super-token (USDCx) and opens a Superfluid
   **General Distribution Agreement (GDA)** stream to the pool of shareholders. Each holder's
   pool units are proportional to the principal they contributed, so a holder of 100 USDC at a
   5 % promised rate streams exactly 5 USDCx / year.
3. The reserve is topped up from the yield source on every deposit / withdraw and by the
   operator between periods of inactivity, so the stream is always funded for at least
   `guaranteedFlowDuration` ahead (the forward-solvency horizon).
4. In the **sync** vault, whatever the external source earns *above* the promised rate stays in
   the position and shows up as share appreciation; losses pass through to the share price
   immediately and honestly. Total return = streamed rate + share appreciation.

## Two vault families

| | **Sync** — `StableYieldSyncVault` | **Async** — `StableYieldAsyncVault` |
|---|---|---|
| Standard | ERC-4626 | ERC-7540 (async deposits & redeems) + ERC-7575 |
| Yield source | An external ERC-4626 (**Morpho Vault V2**), fully on-chain | Operator-managed capital (`take` / `give`), NAV reported at each epoch close |
| Entry / exit | Instant: `deposit` → shares + stream start in the same tx | Request → operator closes & settles the epoch → claim |
| Share price | Floats with the external vault's NAV | Locked per epoch at settlement (forward-priced) |
| Fees | 1 % of the yield stream to the treasury + flat 0.2 USDC per deposit | 1 % of the yield stream to the treasury |
| Gasless UX | `SyncVaultMacro` (permit + deposit + pool connect in one signature) | `AsyncVaultMacro` (Permit2-funded request + pool connect) |
| Contracts | `src/vault/sync/` | `src/vault/async/` |

Both share the streaming engine in [`src/common/FundManagerBase.sol`](src/common/FundManagerBase.sol).

## Live deployments

| Family | Network | Vault | Underlying |
|---|---|---|---|
| Sync | Base (8453) | [`0x8C60503C0353ED12c3Eebc3036BF033A3BbB95Aa`](https://basescan.org/address/0x8C60503C0353ED12c3Eebc3036BF033A3BbB95Aa) | USDC → Morpho Vault V2 |
| Async | Polygon (137) | [`0x0cEE806c01F9F261808CdEbc125818Dd7af3e887`](https://polygonscan.com/address/0x0cEE806c01F9F261808CdEbc125818Dd7af3e887) | pUSD -> Polytheme |

Full address tables (FundManagers, macros, superseded release candidates) in
[`docs/reference-deployments.md`](docs/reference-deployments.md).

## Quick start

Requires [Foundry](https://book.getfoundry.sh/) (the CI pins `solc 0.8.34`).

```bash
git clone --recurse-submodules https://github.com/superfluid-org/stable-yield-vault.git
cd stable-yield-vault
forge build
forge test            # ~230 tests; setUp deploys a full Superfluid framework, so give it a minute
forge fmt --check     # formatting is enforced in CI
```

Focused runs while iterating:

```bash
forge test --match-contract StableYieldSyncVaultTest -vvv
forge test --match-contract StableYieldAsyncVaultTest --match-test test_requestDeposit -vvv
make fork-test        # Base-mainnet fork suite (needs BASE_MAINNET_RPC_URL in .env)
make echidna-sync-smoke / echidna-async-smoke   # property fuzzing (needs echidna + slither)
```

Copy [`.env.example`](.env.example) to `.env` for RPC / explorer keys.

## Documentation

| I want to… | Read |
|---|---|
| Integrate the vault into a front-end or a contract | [`docs/integration-guide.md`](docs/integration-guide.md) |
| Understand the design and the maths | [`docs/architecture.md`](docs/architecture.md), then the family docs below |
| Run a vault (operator / admin) | [`docs/operator-guide.md`](docs/operator-guide.md) |
| Deploy my own instance | [`docs/deployment.md`](docs/deployment.md) |
| Sync vault deep-dive | [`docs/sync-vault/design.md`](docs/sync-vault/design.md), [`invariants.md`](docs/sync-vault/invariants.md), [`flow/`](docs/sync-vault/flow/) |
| Async vault deep-dive | [`docs/async-vault/flow/`](docs/async-vault/flow/), [`invariants.md`](docs/async-vault/invariants.md) |
| Look up a term | [`docs/glossary.md`](docs/glossary.md) |
| See what security work has been done | [`SECURITY.md`](SECURITY.md), `docs/*/security-notes/` |

## Repository layout

```
src/common/FundManagerBase.sol        shared GDA streaming engine (abstract)
src/vault/sync/                       StableYieldSyncVault · SyncFundManager · SyncVaultMacro
src/vault/async/                      StableYieldAsyncVault · AsyncFundManager · AsyncVaultMacro
src/interfaces/                       public interfaces (ERC-7540 refs vendored, IMorphoVaultV2)
script/                               deploy scripts + per-network config (NetworkConfig.sol)
test/vault/{base,sync,async}/         Foundry suites (one shared Superfluid bootstrap)
test/fork/                            Base-mainnet fork suite
test/echidna/                         Echidna property harnesses
docs/                                 design, invariants, flows, guides
```

## Trust assumptions

Read this before depositing funds you are not prepared to lose.

- **Unaudited.** No third-party audit has been performed. `docs/*/security-notes/` are internal,
  AI-assisted reviews and fuzzing reports, not an audit.
- **Privileged roles are not timelocked.** `DEFAULT_ADMIN_ROLE` on the FundManager can
  `emergencyWithdraw` *any* token the FundManager holds (principal in the external vault, the
  USDCx reserve) to the treasury, and can `terminate()` the sync vault's deposit leg.
  `FUND_OPERATOR_ROLE` sets the promised rate at will (no minimum era) and, on the async vault,
  reports NAV and moves capital off-chain via `take` / `give`. Holders are trusting those
  key-holders. **On the current deployments both roles are held by EOAs.**
- **The promised rate is a target, not a guarantee.** The stream is funded from the yield
  source; if it underperforms, the reserve is topped up from principal (sync: NAV falls; async:
  the operator must fund it). The operator's lever is `setStableYieldRate`.
- **Sync vault liquidity.** Withdrawals pull from Morpho V2, which exposes no instant-liquidity
  view. `maxWithdraw` reports the position's *value*; a withdrawal within it can still revert
  during an external liquidity crunch until liquidity returns.
- **Sync vault entry fee.** A flat 0.2 USDC (`DEPOSIT_FEE`) is taken on every deposit.
- **Superfluid semantics.** Streamed USDCx accrues in your balance only while you are
  connected to the GDA pool (otherwise it accumulates as claimable). See the integration guide.

## Security

Please report vulnerabilities privately — see [`SECURITY.md`](SECURITY.md).

## License

[MIT](LICENSE) © Superfluid Finance.
