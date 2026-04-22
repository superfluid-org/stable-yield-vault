// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Script } from "forge-std/Script.sol";
import { NetworkConfig } from "script/config/NetworkConfig.sol";

import { FundManager } from "src/FundManager.sol";
import { StableYieldAsyncVault } from "src/StableYieldAsyncVault.sol";

library StableYieldVaultDeployer {

    struct DeploymentResult {
        address fundManager;
        address asyncVault;
    }

    function deployAll(NetworkConfig.DeploymentConfig memory config)
        internal
        returns (DeploymentResult memory results)
    {
        // Deploy the Liquidity Strategy Contract
        results = _deployFundManager(config);
        results = _deployVault(config, results);
        _configureFundManager(results);
    }

    function _deployFundManager(NetworkConfig.DeploymentConfig memory config)
        internal
        returns (DeploymentResult memory results)
    {
        FundManager fundManager = new FundManager(
            config.underlying,
            config.superToken,
            config.fundOperator,
            config.initialAnnualRate,
            config.guaranteedFlowDuration
        );

        results.fundManager = address(fundManager);
    }

    function _deployVault(NetworkConfig.DeploymentConfig memory config, DeploymentResult memory results)
        internal
        returns (DeploymentResult memory)
    {
        StableYieldAsyncVault asyncVault =
            new StableYieldAsyncVault(config.underlying, results.fundManager, config.shareName, config.shareSymbol);

        results.asyncVault = address(asyncVault);
    }

    function _configureFundManager(DeploymentResult memory results) internal {
        FundManager(results.fundManager).setVault(results.asyncVault);
    }

}
