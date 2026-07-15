// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Script } from "forge-std/Script.sol";
import { NetworkConfig } from "script/config/NetworkConfig.sol";

import { AsyncVaultMacro } from "src/vault/async/AsyncVaultMacro.sol";
import { StableYieldAsyncVault } from "src/vault/async/StableYieldAsyncVault.sol";
import { StableYieldSyncVault } from "src/vault/sync/StableYieldSyncVault.sol";
import { SyncVaultMacro } from "src/vault/sync/SyncVaultMacro.sol";

library StableYieldVaultDeployer {

    struct DeploymentResult {
        address fundManager;
        address vault;
        address vaultMacro;
    }

    function deployAsyncVault(NetworkConfig.DeploymentConfig memory config)
        internal
        returns (DeploymentResult memory results)
    {
        // Deploy the AsyncVault and AsyncFundManager Contract
        results = _deployAsyncVault(config);
    }

    function deploySyncVault(NetworkConfig.DeploymentConfig memory config)
        internal
        returns (DeploymentResult memory results)
    {
        // Deploy the SyncVault and SyncFundManager Contract
        results = _deploySyncVault(config);
    }

    function _deployAsyncVault(NetworkConfig.DeploymentConfig memory config)
        internal
        returns (DeploymentResult memory results)
    {
        StableYieldAsyncVault asyncVault = new StableYieldAsyncVault(
            config.treasury,
            config.underlyingAsset,
            config.yieldAsset,
            config.fundOperator,
            config.fundAdmin,
            config.initialEraStableYieldRate,
            config.guaranteedFlowDuration,
            config.shareName,
            config.shareSymbol
        );

        results.vault = address(asyncVault);
        results.fundManager = address(asyncVault.FUND_MANAGER());

        // Periphery: the macro exposing the request/claim user actions.
        results.vaultMacro = address(new AsyncVaultMacro(asyncVault));
    }

    function _deploySyncVault(NetworkConfig.DeploymentConfig memory config)
        internal
        returns (DeploymentResult memory results)
    {
        StableYieldSyncVault syncVault = new StableYieldSyncVault(
            config.treasury,
            config.underlyingAsset,
            config.yieldAsset,
            config.externalVault,
            config.fundOperator,
            config.fundAdmin,
            config.initialEraStableYieldRate,
            config.guaranteedFlowDuration,
            config.shareName,
            config.shareSymbol
        );

        results.vault = address(syncVault);
        results.fundManager = address(syncVault.FUND_MANAGER());

        // Periphery: the macro exposing deposit-and-connect + redeem user actions.
        results.vaultMacro = address(new SyncVaultMacro(syncVault));
    }

}
