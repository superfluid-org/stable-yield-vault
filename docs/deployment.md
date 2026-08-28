# Deploying a vault

## Prerequisites

- Foundry (`forge`, `cast`); `solc 0.8.34` is fetched automatically.
- A funded deployer key imported into the Foundry keystore (`cast wallet import <name>`), or
  any other signer `forge script` supports. The scripts call `vm.startBroadcast()` with no
  key argument, so the signer comes from the CLI flags.
- `.env` with the RPC URL of the target network and an explorer API key for verification (see
  [`.env.example`](../.env.example)).
- On the target network: the underlying token (**6 decimals**), its Superfluid super-token
  wrapper (find both on the [Superfluid protocol addresses page](https://docs.superfluid.org/docs/protocol/contract-addresses)),
  and — for the sync vault — a Morpho Vault V2 whose `asset()` is the underlying.

## 1. Configure the network

All deployment parameters are hard-coded per `chainId` in
[`script/config/NetworkConfig.sol`](../script/config/NetworkConfig.sol). Add or edit a
`DeploymentConfig` for your chain:

```solidity
DeploymentConfig({
    treasury: <multisig>,              // fee stream + DEPOSIT_FEE + emergencyWithdraw recipient
    underlyingAsset: <USDC>,           // must have exactly 6 decimals
    yieldAsset: <USDCx>,               // super-token wrapping underlyingAsset
    externalVault: <Morpho V2 vault>,  // sync only; address(0) for async
    fundOperator: <ops key>,
    fundAdmin: <multisig / timelock>,
    initialEraStableYieldRate: 300,    // bps, 3 %
    guaranteedFlowDuration: 2 days,    // ≥ 1 day; rate × duration ≤ 365 days × 10_000
    shareName: "…",
    shareSymbol: "…"
})
```

and route it in `getNetworkConfig(chainId)`.

## 2. Dry-run, then broadcast

```bash
# sync vault (ERC-4626 on Morpho V2)
forge script script/sync/DeploySync.s.sol:DeploySync --rpc-url $BASE_MAINNET_RPC_URL --account <keystore-name>
forge script script/sync/DeploySync.s.sol:DeploySync --rpc-url $BASE_MAINNET_RPC_URL --account <keystore-name> --broadcast --verify

# async vault (ERC-7540)
forge script script/async/DeployAsync.s.sol:DeployAsync --rpc-url $POLYGON_MAINNET_RPC_URL --account <keystore-name> --broadcast --verify
```

Without `--broadcast` the script simulates and prints the configuration and the would-be
addresses. Each script deploys **two** contracts: the vault (whose constructor deploys the
FundManager, pinning the pair) and the matching ClearMacro. Deployment logs land in
`broadcast/<Script>/<chainId>/`.

The library behind both scripts is
[`script/StableYieldVaultDeployer.sol`](../script/StableYieldVaultDeployer.sol)
(`deploySyncVault` / `deployAsyncVault`) — reuse it from your own scripts or tests.

## 3. Post-deployment

1. Record the addresses in [`deployments.md`](./deployments.md).
2. The FM's GDA pools exist and the FM is connected to its yield pool — nothing to do.
3. **Sync:** the stream starts with the first deposit (which also pre-funds the reserve). Make a
   first deposit of at least a few USDC yourself so the vault is live and the empty-vault edge
   cases are behind you.
4. **Async:** `currentEpoch()` starts at 1; the first `closeEpoch` / `settleEpoch` cycle mints
   the first shares. Nothing streams until the first deposit is claimed.
5. Set up the operator cron for `ensureYieldFlowDuration()` and monitoring
   ([`operator-guide.md`](./operator-guide.md)).
6. Verify role holders: `hasRole(DEFAULT_ADMIN_ROLE, fundAdmin)`,
   `hasRole(FUND_OPERATOR_ROLE, fundOperator)`, `hasRole(VAULT_ROLE, vault)` on the FM.

## Constructor reference

See the table in [`integration-guide.md` §10](./integration-guide.md#10-deploying-your-own-instance).
