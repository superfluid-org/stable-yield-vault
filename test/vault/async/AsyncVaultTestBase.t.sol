// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { StableYieldVaultDeployer } from "script/StableYieldVaultDeployer.sol";
import { NetworkConfig } from "script/config/NetworkConfig.sol";

import { AsyncFundManager } from "src/vault/async/AsyncFundManager.sol";
import { StableYieldAsyncVault } from "src/vault/async/StableYieldAsyncVault.sol";
import { StableYieldVaultTestBase } from "test/vault/base/StableYieldVaultTestBase.t.sol";

contract AsyncVaultTestBase is StableYieldVaultTestBase {

    string internal constant SHARE_NAME = "Stable Yield Async Vault Share";
    string internal constant SHARE_SYMBOL = "SYAVS";

    AsyncFundManager internal _fundManager;
    StableYieldAsyncVault internal _vault;

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(DEPLOYER);
        StableYieldVaultDeployer.DeploymentResult memory deploymentResult = StableYieldVaultDeployer.deployAsyncVault(
            NetworkConfig.DeploymentConfig({
                treasury: TREASURY,
                underlyingAsset: address(_usdc),
                yieldAsset: address(_usdcx),
                externalVault: address(0),
                fundOperator: FUND_OPERATOR,
                fundAdmin: FUND_ADMIN,
                initialEraStableYieldRate: INITIAL_ERA_STABLE_YIELD_RATE,
                guaranteedFlowDuration: GUARANTEED_FLOW_DURATION,
                shareName: SHARE_NAME,
                shareSymbol: SHARE_SYMBOL
            })
        );
        vm.stopPrank();

        _fundManager = AsyncFundManager(deploymentResult.fundManager);
        _vault = StableYieldAsyncVault(deploymentResult.vault);
    }

}
