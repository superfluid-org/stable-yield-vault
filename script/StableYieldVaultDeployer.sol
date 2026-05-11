// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Script } from "forge-std/Script.sol";
import { NetworkConfig } from "script/config/NetworkConfig.sol";

import { AsyncFundManager } from "src/async-vault/AsyncFundManager.sol";
import { StableYieldAsyncVault } from "src/async-vault/StableYieldAsyncVault.sol";

library StableYieldVaultDeployer {

    struct DeploymentResult {
        address fundManager;
        address asyncVault;
    }

    function deployAll(NetworkConfig.DeploymentConfig memory config)
        internal
        returns (DeploymentResult memory results)
    {
        // Deploy the AsyncVault and AsyncFundManager Contract
        results = _deploy(config);
    }

    function _deploy(NetworkConfig.DeploymentConfig memory config) internal returns (DeploymentResult memory results) {
        StableYieldAsyncVault asyncVault = new StableYieldAsyncVault(
            config.underlyingAsset,
            config.yieldAsset,
            config.fundOperator,
            config.fundAdmin,
            config.initialEraStableYieldRate,
            config.guaranteedFlowDuration,
            config.shareName,
            config.shareSymbol
        );

        results.asyncVault = address(asyncVault);
        results.fundManager = address(asyncVault.FUND_MANAGER());
    }

}
