// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { StableYieldVaultDeployer } from "script/StableYieldVaultDeployer.sol";
import { NetworkConfig } from "script/config/NetworkConfig.sol";

import { StableYieldSyncVault } from "src/vault/sync/StableYieldSyncVault.sol";
import { SyncFundManager } from "src/vault/sync/SyncFundManager.sol";
import { MockMorphoVaultV2 } from "test/mocks/MockMorphoVaultV2.sol";
import { StableYieldVaultTestBase } from "test/vault/base/StableYieldVaultTestBase.t.sol";

/**
 * @title SyncVaultTestBase
 * @notice Shared fixture for the synchronous StableYieldSyncVault suite. Deploys a full Superfluid
 *         framework (mirroring the async `StableYieldVaultTestBase`), a USDC TestToken + USDCx
 *         wrapper, a configurable `MockMorphoVaultV2` external vault (Morpho V2 semantics: `max*`
 *         hardcoded to 0, gate views), and the StableYieldSyncVault (which deploys & pins its
 *         `SyncFundManager`).
 */
contract SyncVaultTestBase is StableYieldVaultTestBase {

    string internal constant SHARE_NAME = "Stable Yield Sync Vault Share";
    string internal constant SHARE_SYMBOL = "SYSVS";

    MockMorphoVaultV2 internal _external;
    SyncFundManager internal _fundManager;
    StableYieldSyncVault internal _vault;

    function setUp() public virtual override {
        super.setUp();

        _external = new MockMorphoVaultV2(IERC20(address(_usdc)), "Mock External USDC Vault", "mxUSDC");

        vm.startPrank(DEPLOYER);
        StableYieldVaultDeployer.DeploymentResult memory deploymentResult = StableYieldVaultDeployer.deploySyncVault(
            NetworkConfig.DeploymentConfig({
                treasury: TREASURY,
                underlyingAsset: address(_usdc),
                yieldAsset: address(_usdcx),
                externalVault: address(_external),
                fundOperator: FUND_OPERATOR,
                fundAdmin: FUND_ADMIN,
                initialEraStableYieldRate: INITIAL_ERA_STABLE_YIELD_RATE,
                guaranteedFlowDuration: GUARANTEED_FLOW_DURATION,
                shareName: SHARE_NAME,
                shareSymbol: SHARE_SYMBOL
            })
        );
        vm.stopPrank();

        _fundManager = SyncFundManager(deploymentResult.fundManager);
        _vault = StableYieldSyncVault(deploymentResult.vault);
    }

    //      __  __     __
    //     / / / /__  / /___  ___  _____
    //    / /_/ / _ \/ / __ \/ _ \/ ___/
    //   / __  /  __/ / /_/ /  __/ /
    //  /_/ /_/\___/_/ .___/\___/_/
    //              /_/

    /// @dev Fund `user` with `amount` USDC, approve the vault to pull it, and top up ETH so the
    ///      caller can pay the participation fee on `depositWithFee`/`mintWithFee`.
    function _fund(address user, uint256 amount) internal {
        _dealUSDC(user, amount);
        vm.deal(user, 1 ether);
        vm.prank(user);
        _usdc.approve(address(_vault), type(uint256).max);
    }

    /// @dev Deposit `amount` for `user` (funds + approves first) through the fee-bearing entrypoint.
    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        _fund(user, amount);
        // Cache the fee before pranking: an external call in the `{value:}` arg would otherwise
        // consume the prank, so the actual deposit would run as the test contract (no allowance).
        uint256 fee = _vault.DEPOSIT_FEE();
        vm.prank(user);
        shares = _vault.depositWithFee{ value: fee }(amount, user);
    }

    /// @dev Seed the FundManager reserve so the stream can start without waiting for harvest.
    function _seedReserve(uint256 usdcxAmount) internal {
        _dealUSDCx(address(_fundManager), usdcxAmount);
    }

}
