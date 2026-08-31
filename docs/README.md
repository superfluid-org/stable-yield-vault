# Documentation index

| Document | What it covers |
|---|---|
| [`architecture.md`](./architecture.md) | The system in one read: contracts, the streaming engine, the maths, roles, both families side by side. Start here. |
| [`integration-guide.md`](./integration-guide.md) | For front-end and contract developers: deposit / withdraw / receive the stream / gasless macros / error catalogue. |
| [`operator-guide.md`](./operator-guide.md) | For whoever holds `FUND_OPERATOR_ROLE` / `DEFAULT_ADMIN_ROLE`: cadence, epoch lifecycle, reserve upkeep, incidents. |
| [`deployment.md`](./deployment.md) | Deploying your own instance with `NetworkConfig` and the forge scripts. |
| [`reference-deployments.md`](./reference-deployments.md) | Addresses of the live and superseded deployments. |
| [`glossary.md`](./glossary.md) | Every term used across the docs (epoch, era, units, reserve-inclusive NAV, ClearMacro, …). |

## Sync vault (`StableYieldSyncVault` + `SyncFundManager`)

| Document | What it covers |
|---|---|
| [`sync-vault/design.md`](./sync-vault/design.md) | Model, design decisions, contract-by-contract description, security considerations. Authoritative. |
| [`sync-vault/invariants.md`](./sync-vault/invariants.md) | Property catalogue (custody, NAV, stream solvency, share accounting) with the code that enforces each. |
| [`sync-vault/flow/deposit-flow.md`](./sync-vault/flow/deposit-flow.md) | Step-by-step deposit, including the fee and the pre-funded stream. |
| [`sync-vault/flow/withdraw-flow.md`](./sync-vault/flow/withdraw-flow.md) | Step-by-step withdraw / redeem and payout sourcing. |
| [`sync-vault/flow/batched-deposit-flow.md`](./sync-vault/flow/batched-deposit-flow.md) | One-signature onboarding through `SyncVaultMacro` (permit + deposit + pool connect). |
| [`sync-vault/security-notes/`](./sync-vault/security-notes/) | Internal AI-assisted review and Echidna reports (not a third-party audit). |

## Async vault (`StableYieldAsyncVault` + `AsyncFundManager`)

| Document | What it covers |
|---|---|
| [`async-vault/flow/deposit-flow.md`](./async-vault/flow/deposit-flow.md) | Request → settle → claim for deposits. Authoritative for the epoch logic. |
| [`async-vault/flow/redeem-flow.md`](./async-vault/flow/redeem-flow.md) | Request → settle → claim for redeems. |
| [`async-vault/flow/settlement-flow.md`](./async-vault/flow/settlement-flow.md) | `closeEpoch` / `settleEpoch`: NAV, effective supply, netting, unit grants. |
| [`async-vault/flow/batched-request-flow.md`](./async-vault/flow/batched-request-flow.md) | Gasless requests and claims through `AsyncVaultMacro` (Permit2 witness + EIP-2771). |
| [`async-vault/invariants.md`](./async-vault/invariants.md) | Property catalogue with the code that enforces each. |
| [`async-vault/security-notes/`](./async-vault/security-notes/) | Internal AI-assisted review and Echidna fuzzing notes (not a third-party audit). |
