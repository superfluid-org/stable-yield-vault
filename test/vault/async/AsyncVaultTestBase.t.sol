// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { StableYieldVaultDeployer } from "script/StableYieldVaultDeployer.sol";
import { NetworkConfig } from "script/config/NetworkConfig.sol";

import { DeployPermit2 } from "aave-v3/tests/invariants/utils/DeployPermit2.sol";

import { IPermit2 } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/external/IPermit2.sol";

import { IStableYieldAsyncVault } from "src/interfaces/vault/async/IStableYieldAsyncVault.sol";
import { AsyncFundManager } from "src/vault/async/AsyncFundManager.sol";
import { StableYieldAsyncVault } from "src/vault/async/StableYieldAsyncVault.sol";
import { StableYieldVaultTestBase } from "test/vault/base/StableYieldVaultTestBase.t.sol";

contract AsyncVaultTestBase is StableYieldVaultTestBase {

    string internal constant SHARE_NAME = "Stable Yield Async Vault Share";
    string internal constant SHARE_SYMBOL = "SYAVS";

    /// @dev Canonical Permit2 address (mirrors `StableYieldAsyncVault.PERMIT2`).
    address internal constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");

    /// @dev Permit2's `PermitWitnessTransferFrom` typehash stub; the vault's witness type string
    ///      is appended to it (see `StableYieldAsyncVault.DEPOSIT_WITNESS_TYPE_STRING`).
    string internal constant PERMIT_WITNESS_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

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

    //      __  __     __
    //     / / / /__  / /___  ___  _____
    //    / /_/ / _ \/ / __ \/ _ \/ ___/
    //   / __  /  __/ / /_/ /  __/ /
    //  /_/ /_/\___/_/ .___/\___/_/
    //              /_/

    /// @dev Directly drive closeEpoch on the vault (bypasses FM totalAssets calculation).
    function _vaultCloseEpoch(uint256 totalAssetsReported) internal {
        vm.prank(address(_fundManager));
        _vault.onCloseEpoch(totalAssetsReported);
    }

    /// @dev Directly drive settleEpoch on the vault.
    function _vaultSettleEpoch() internal {
        vm.prank(address(_fundManager));
        _vault.onSettleEpoch();
    }

    /// @dev Drives settleEpoch + mimics the pool-unit grant that FM.settleEpoch would normally do.
    ///      Needed so subsequent claims (which call `onClaimDeposit` → `decreaseMemberUnits`) don't underflow.
    function _vaultSettleAndGrantUnits() internal {
        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();

        vm.startPrank(address(_fundManager));
        _vault.onSettleEpoch();

        if (snap.depositingAssets > 0) {
            uint256 units = snap.depositingAssets / _fundManager.RAW_PER_UNIT();
            _fundManager.YIELD_POOL().increaseMemberUnits(address(_fundManager), uint128(units));
        }

        vm.stopPrank();
    }

    //     ____                  _ __  ___
    //    / __ \___  _________ _(_) /_|__ \
    //   / /_/ / _ \/ ___/ __ `_/ / __/__/ /
    //  / ____/  __/ /  / / / / / / /_/ __/
    // /_/    \___/_/  /_/ /_/ /_/\__/____/

    /// @dev Etch the real Permit2 runtime (precompiled bytecode) at the canonical address the
    ///      vault hardcodes. The etched runtime keeps the domain separator cached at deploy time,
    ///      so signatures must be built from `IPermit2(PERMIT2_ADDRESS).DOMAIN_SEPARATOR()`.
    function _etchPermit2() internal {
        if (PERMIT2_ADDRESS.code.length > 0) return;
        vm.etch(PERMIT2_ADDRESS, DeployPermit2.deployPermit2().code);
    }

    /// @dev Fund `user` with `amount` USDC and grant Permit2 the ERC-20 allowance it pulls with.
    ///      Note: the vault itself is NOT approved — the Permit2 signature is the authorization.
    function _fundForPermit2(address user, uint256 amount) internal {
        _dealUSDC(user, amount);
        vm.prank(user);
        _usdc.approve(PERMIT2_ADDRESS, type(uint256).max);
    }

    /// @dev Sign a Permit2 `permitWitnessTransferFrom` for `requestDepositWithPermit2`:
    ///      spender = vault, transferred token/amount = USDC/`assets`, witness = the vault-defined
    ///      binding of `controller`.
    function _signPermit2Deposit(uint256 pk, uint256 assets, address controller, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 typeHash = keccak256(abi.encodePacked(PERMIT_WITNESS_STUB, _vault.DEPOSIT_WITNESS_TYPE_STRING()));
        bytes32 tokenPermissionsHash = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, address(_usdc), assets));
        bytes32 structHash = keccak256(
            abi.encode(
                typeHash, tokenPermissionsHash, address(_vault), nonce, deadline, _vault.depositWitness(controller)
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IPermit2(PERMIT2_ADDRESS).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        signature = abi.encodePacked(r, s, v);
    }

}
