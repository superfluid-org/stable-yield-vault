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
    address internal immutable FUND_ADMIN = makeAddr("FUND_ADMIN");
    address internal immutable ALICE = makeAddr("ALICE");
    address internal immutable BOB = makeAddr("BOB");
    address internal immutable KAREN = makeAddr("KAREN");

    address internal immutable WHALE = makeAddr("WHALE");

    uint256 internal constant INITIAL_ERA_STABLE_YIELD_RATE = 1000; // 10% annual rate
    uint256 internal constant GUARANTEED_FLOW_DURATION = 7 days;

    uint256 internal constant ONE_BILLION = 1_000_000_000;

    function setUp() public virtual {
        (_sf, _deployer) = _deploySuperfluid();
        (_usdc, _usdcSuperToken) = _deployer.deployWrapperSuperToken("USDC", "USDC", 6, type(uint256).max, address(0));
        _usdcx = ISuperToken(address(_usdcSuperToken));
        _initWhale();

        vm.startPrank(DEPLOYER);
        StableYieldVaultDeployer.DeploymentResult memory deploymentResult = StableYieldVaultDeployer.deployAll(
            NetworkConfig.DeploymentConfig({
                underlyingAsset: address(_usdc),
                yieldAsset: address(_usdcx),
                fundOperator: FUND_OPERATOR,
                fundAdmin: FUND_ADMIN,
                initialEraStableYieldRate: INITIAL_ERA_STABLE_YIELD_RATE,
                guaranteedFlowDuration: GUARANTEED_FLOW_DURATION,
                shareName: "Stable Yield Vault Share",
                shareSymbol: "SYVS"
            })
        );
        vm.stopPrank();

        _fundManager = FundManager(deploymentResult.fundManager);
        _vault = StableYieldAsyncVault(deploymentResult.asyncVault);
    }

    function _initWhale() internal {
        // Mint 2000 billion USDC to the WHALE
        _usdc.mint(WHALE, 1000 * ONE_BILLION * 1e6);

        // Upgrade 1000 billion USDC to USDCx and transfer to the WHALE
        vm.startPrank(WHALE);
        _usdc.approve(address(_usdcx), type(uint256).max);
        _usdcx.upgrade(1000 * ONE_BILLION * 1e18);
        vm.stopPrank();
    }

    function _dealUSDCx(address recipient, uint256 amount) internal {
        vm.prank(WHALE);
        _usdcx.transfer(recipient, amount);
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
