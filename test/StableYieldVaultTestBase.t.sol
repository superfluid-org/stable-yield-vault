// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import { ERC1820RegistryCompiled } from
    "@superfluid-finance/ethereum-contracts/contracts/libs/ERC1820RegistryCompiled.sol";
import { ISuperToken, SuperToken } from "@superfluid-finance/ethereum-contracts/contracts/superfluid/SuperToken.sol";

import { SuperfluidFrameworkDeployer } from
    "@superfluid-finance/ethereum-contracts/contracts/utils/SuperfluidFrameworkDeployer.t.sol";
import { TestToken } from "@superfluid-finance/ethereum-contracts/contracts/utils/TestToken.sol";

import { Test } from "forge-std/Test.sol";

import { StableYieldVaultDeployer } from "script/StableYieldVaultDeployer.sol";
import { NetworkConfig } from "script/config/NetworkConfig.sol";
import { FundManager } from "src/FundManager.sol";
import { StableYieldAsyncVault } from "src/StableYieldAsyncVault.sol";

contract StableYieldVaultTestBase is Test {

    using SuperTokenV1Library for ISuperToken;

    SuperfluidFrameworkDeployer.Framework internal _sf;
    SuperfluidFrameworkDeployer internal _deployer;
    TestToken internal _usdc;
    ISuperToken internal _usdcx;
    SuperToken internal _usdcSuperToken;

    FundManager internal _fundManager;
    StableYieldAsyncVault internal _vault;

    address internal immutable DEPLOYER = makeAddr("DEPLOYER");
    address internal immutable FUND_OPERATOR = makeAddr("FUND_OPERATOR");
    address internal immutable ALICE = makeAddr("ALICE");
    address internal immutable BOB = makeAddr("BOB");
    address internal immutable KAREN = makeAddr("KAREN");

    uint256 internal constant INITIAL_ANNUAL_RATE = 1000; // 10% annual rate
    uint256 internal constant GUARANTEED_FLOW_DURATION = 7 days;

    function setUp() public {
        (_sf, _deployer) = _deploySuperfluid();
        (_usdc, _usdcSuperToken) = _deployer.deployWrapperSuperToken("USDC", "USDC", 6, type(uint256).max, address(0));
        _usdcx = ISuperToken(address(_usdcSuperToken));

        vm.startPrank(DEPLOYER);
        StableYieldVaultDeployer.DeploymentResult memory deploymentResult = StableYieldVaultDeployer.deployAll(
            NetworkConfig.DeploymentConfig({
                underlying: address(_usdc),
                superToken: address(_usdcx),
                fundOperator: FUND_OPERATOR,
                initialAnnualRate: INITIAL_ANNUAL_RATE,
                guaranteedFlowDuration: GUARANTEED_FLOW_DURATION,
                shareName: "Stable Yield Vault Share",
                shareSymbol: "SYVS"
            })
        );
        vm.stopPrank();

        _fundManager = FundManager(deploymentResult.fundManager);
        _vault = StableYieldAsyncVault(deploymentResult.asyncVault);
    }

    function _dealUSDCx(address recipient, uint256 amount) internal {
        vm.startPrank(DEPLOYER);
        _usdc.mint(DEPLOYER, amount / 1e12);
        _usdc.approve(address(_usdcx), amount / 1e12);
        _usdcx.upgrade(amount);
        _usdcx.transfer(recipient, amount);
        vm.stopPrank();
    }

    function _dealUSDC(address recipient, uint256 amount) internal {
        _usdc.mint(recipient, amount);
    }

    function _deploySuperfluid()
        internal
        returns (SuperfluidFrameworkDeployer.Framework memory sf, SuperfluidFrameworkDeployer deployer)
    {
        // Superfluid Protocol Deployment Start
        vm.etch(ERC1820RegistryCompiled.at, ERC1820RegistryCompiled.bin);

        deployer = new SuperfluidFrameworkDeployer();
        deployer.deployTestFramework();
        sf = deployer.getFramework();

        // Superfluid Protocol Deployment End
    }

}
