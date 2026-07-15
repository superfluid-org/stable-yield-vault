// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/* Local imports */
import { StableYieldVaultDeployer } from "script/StableYieldVaultDeployer.sol";
import { NetworkConfig } from "script/config/NetworkConfig.sol";

/* Foundry imports */
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract DeploySync is Script {

    function _startBroadcast() internal returns (address deployer) {
        vm.startBroadcast();

        (, deployer,) = vm.readCallers();
    }

    function _stopBroadcast() internal {
        vm.stopBroadcast();
    }

    function run() external {
        uint256 chainId = block.chainid;

        // Get Strategy deployment configuration
        NetworkConfig.DeploymentConfig memory config = NetworkConfig.getNetworkConfig(chainId);

        console.log("");
        console.log("===> DEPLOYMENT CONFIGURATION");
        console.log(" --- Treasury                      :", config.treasury);
        console.log(" --- Underlying Asset              :", config.underlyingAsset);
        console.log(" --- Yield Asset                   :", config.yieldAsset);
        console.log(" --- External Vault                :", config.externalVault);
        console.log(" --- Fund Operator                 :", config.fundOperator);
        console.log(" --- Fund Admin                    :", config.fundAdmin);
        console.log(" --- Initial Era Stable Yield Rate :", config.initialEraStableYieldRate);
        console.log(" --- Guaranteed Flow Duration      :", config.guaranteedFlowDuration);
        console.log(" --- Share Name                    :", config.shareName);
        console.log(" --- Share Symbol                  :", config.shareSymbol);
        console.log("");

        // Start broadcasting transactions
        address deployer = _startBroadcast();

        console.log("===> STARTING STRATEGY DEPLOYMENT :");
        console.log(" --- Chain ID          :   ", chainId);
        console.log(" --- Deployer address  :   ", deployer);
        console.log("");

        // Deploy Strategy Protocol
        StableYieldVaultDeployer.DeploymentResult memory result = StableYieldVaultDeployer.deploySyncVault(config);

        _stopBroadcast();

        console.log("");
        console.log("===> DEPLOYMENT RESULTS");
        console.log(" --- Sync Fund Manager    :", result.fundManager);
        console.log(" --- Sync Vault           :", result.vault);
        console.log(" --- Sync Vault Macro     :", result.vaultMacro);
        console.log("");
    }

}
