// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { SyncVaultTestBase } from "./SyncVaultTestBase.t.sol";
import { MockMorphoVaultV2 } from "test/mocks/MockMorphoVaultV2.sol";

import { ISuperToken, SuperToken } from "@superfluid-finance/ethereum-contracts/contracts/superfluid/SuperToken.sol";
import { TestToken } from "@superfluid-finance/ethereum-contracts/contracts/utils/TestToken.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IFundManagerBase } from "src/interfaces/common/IFundManagerBase.sol";
import { ISyncFundManager } from "src/interfaces/vault/sync/ISyncFundManager.sol";
import { StableYieldSyncVault } from "src/vault/sync/StableYieldSyncVault.sol";

/**
 * @title SyncFundManagerTest
 * @notice FundManager-level suite for the sync family. Covers the SyncFundManager hooks and the
 *         shared {FundManagerBase} engine branches that are only reachable by calling the FM
 *         directly with the vault role (mirrors the async `AsyncFundManagerTest` structure). The
 *         value-bearing hooks are `onlyRole(VAULT_ROLE)`, so these tests `vm.prank(address(_vault))`
 *         to drive them, exactly as the async FM suite does.
 */
contract SyncFundManagerTest is SyncVaultTestBase {

    uint256 internal constant DEFAULT_DEPOSIT = 1000 * 1e6;

    //     ______                 __                  __                ______          __
    //    / ____/___  ____  _____/ /________  _______/ /_____  _____   /_  __/__  _____/ /______
    //   / /   / __ \/ __ \/ ___/ __/ ___/ / / / ___/ __/ __ \/ ___/    / / / _ \/ ___/ __/ ___/
    //  / /___/ /_/ / / / (__  ) /_/ /  / /_/ / /__/ /_/ /_/ / /       / / /  __(__  ) /_(__  )
    //  \____/\____/_/ /_/____/\__/_/   \__,_/\___/\__/\____/_/       /_/  \___/____/\__/____/

    /// @dev The shared base constructor rejects underlyings outside [6, 18] decimals
    ///      (`FundManagerBase.sol:144`). Deploy a full vault over a 5-dec underlying (below the
    ///      floor) and assert the FM construction inside the vault constructor reverts.
    function test_constructor_revertsOnUnsupportedDecimals() public {
        // 5-dec underlying + matching wrapper super-token + external vault over the same token.
        (TestToken lowDec, SuperToken lowDecx) =
            _deployer.deployWrapperSuperToken("LOW", "LOW", 5, type(uint256).max, address(0));
        MockMorphoVaultV2 lowExternal = new MockMorphoVaultV2(IERC20(address(lowDec)), "Low External", "lx");

        vm.expectRevert(IFundManagerBase.UNSUPPORTED_DECIMALS.selector);
        new StableYieldSyncVault(
            TREASURY,
            address(lowDec),
            address(lowDecx),
            address(lowExternal),
            FUND_OPERATOR,
            FUND_ADMIN,
            INITIAL_ERA_STABLE_YIELD_RATE,
            GUARANTEED_FLOW_DURATION,
            "Low",
            "Low"
        );
    }

    //    _    __             ____     ______      __           __
    //   | |  / /___ ___  __/ / /_   / ____/___ _/ /____  ____/ /
    //   | | / / __ `/ / / / / __/  / / __/ __ `/ __/ _ \/ __  /
    //   | |/ / /_/ / /_/ / / /_   / /_/ / /_/ / /_/  __/ /_/ /
    //   |___/\__,_/\__,_/_/\__/   \____/\__,_/\__/\___/\__,_/

    /// @dev `onWithdraw` sanity-checks the snapshot args the vault passes (design Inv. C.4). The
    ///      vault never passes bad args (it burns against a real balance first), so this revert
    ///      branch (`SyncFundManager.sol:124`) is only reachable by a direct vault-role call.
    function test_onWithdraw_revertsOnBadArgs(uint256 sharesOwned, uint256 sharesRedeemed) public {
        sharesOwned = bound(sharesOwned, 1, ONE_BILLION * 1e6);
        sharesRedeemed = bound(sharesRedeemed, sharesOwned + 1, ONE_BILLION * 1e6 + 1);

        // shares > totalSharesOwned
        vm.prank(address(_vault));
        vm.expectRevert(ISyncFundManager.BAD_WITHDRAW_ARGS.selector);
        _fundManager.onWithdraw(ALICE, sharesRedeemed, sharesOwned, sharesOwned, ALICE, 1e6);

        // totalSharesOwned == 0
        vm.prank(address(_vault));
        vm.expectRevert(ISyncFundManager.BAD_WITHDRAW_ARGS.selector);
        _fundManager.onWithdraw(ALICE, 0, 0, 0, ALICE, 1e6);
    }

    /// @dev The shared `onShareTransfer` skips (no-op) when the sender holds zero pool units rather
    ///      than reverting. A zero-units sender has nothing to move (`delta` would be 0), and
    ///      reverting would brick transfers of a dust share position whose units were `Ceil`-zeroed
    ///      by a near-full redeem. The end-to-end reachable path is covered by
    ///      `test_residualSharesTransferableAfterUnitZeroingRedeem` in the vault suite.
    function test_onShareTransfer_skipsOnZeroUnits() public {
        // ALICE never deposited → zero units.
        assertEq(_fundManager.YIELD_POOL().getUnits(ALICE), 0, "precondition: ALICE has no units");

        vm.prank(address(_vault));
        _fundManager.onShareTransfer(ALICE, BOB, 1); // must not revert

        assertEq(_fundManager.YIELD_POOL().getUnits(ALICE), 0, "sender units unchanged");
        assertEq(_fundManager.YIELD_POOL().getUnits(BOB), 0, "receiver gets no units (sender had none)");
    }

    /// @dev The shared base bounds `rate * duration <= YEAR * BP_DENOMINATOR` (the pre-fund for the
    ///      guarantee horizon never exceeds 100% of the streamed notional). The operator cannot set a
    ///      rate that, combined with the current duration, breaches it; the boundary itself is allowed.
    function test_setStableYieldRate_revertsOnUnsustainableCombination() public {
        uint256 maxRate = (_fundManager.YEAR() * 10_000) / _fundManager.guaranteedFlowDuration();

        vm.startPrank(FUND_OPERATOR);
        vm.expectRevert(IFundManagerBase.INVALID_YIELD_DURATION_COMBINATION.selector);
        _fundManager.setStableYieldRate(maxRate + 1);

        // Exactly at the bound is allowed (empty vault ⇒ 0 units ⇒ rebalance/recalibrate are no-ops).
        _fundManager.setStableYieldRate(maxRate);
        vm.stopPrank();

        assertEq(_fundManager.stableYieldRate(), maxRate, "rate set to the sustainability boundary");
    }

    /// @dev Duration side: the admin cannot set a duration that, combined with the current rate,
    ///      breaches `rate * duration <= YEAR * BP_DENOMINATOR`; the boundary is allowed.
    function test_setGuaranteedFlowDuration_revertsOnUnsustainableCombination() public {
        uint256 maxDuration = (_fundManager.YEAR() * 10_000) / _fundManager.stableYieldRate();

        vm.startPrank(FUND_ADMIN);
        vm.expectRevert(IFundManagerBase.INVALID_YIELD_DURATION_COMBINATION.selector);
        _fundManager.setGuaranteedFlowDuration(maxDuration + 1);

        _fundManager.setGuaranteedFlowDuration(maxDuration); // boundary allowed
        vm.stopPrank();

        assertEq(_fundManager.guaranteedFlowDuration(), maxDuration, "duration set to the sustainability boundary");
    }

    //    _    ___                 ______                 __  _
    //   | |  / (_)__ _      __   / ____/_  ______  _____/ /_(_)___  ____  _____
    //   | | / / / _ \ | /| / /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   | |/ / /  __/ |/ |/ /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //   |___/_/\___/|__/|__/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @dev `canDepositExternal` is the AND of Morpho V2's deposit-side gate views for the FM
    ///      (`canSendAssets(FM) && canReceiveShares(FM)`); both gates are open by default and
    ///      blocking either one flips it.
    function test_canDepositExternal_followsGates() public {
        assertTrue(_fundManager.canDepositExternal(), "gates open by default");

        _external.setCanSendAssets(false);
        assertFalse(_fundManager.canDepositExternal(), "blocked send-assets gate closes deposits");
        _external.setCanSendAssets(true);

        _external.setCanReceiveShares(false);
        assertFalse(_fundManager.canDepositExternal(), "blocked receive-shares gate closes deposits");
        _external.setCanReceiveShares(true);

        assertTrue(_fundManager.canDepositExternal(), "reopens once both gates clear");
    }

    /// @dev `canWithdrawExternal` is the AND of the exit-side gate views for the FM
    ///      (`canSendShares(FM) && canReceiveAssets(FM)` — the FM is always the receiver of the
    ///      external leg since withdrawals are routed FM-first).
    function test_canWithdrawExternal_followsGates() public {
        assertTrue(_fundManager.canWithdrawExternal(), "gates open by default");

        _external.setCanSendShares(false);
        assertFalse(_fundManager.canWithdrawExternal(), "blocked send-shares gate closes withdrawals");
        _external.setCanSendShares(true);

        _external.setCanReceiveAssets(false);
        assertFalse(_fundManager.canWithdrawExternal(), "blocked receive-assets gate closes withdrawals");
        _external.setCanReceiveAssets(true);

        assertTrue(_fundManager.canWithdrawExternal(), "reopens once both gates clear");
    }

    /// @dev `totalManagedAssets` is the plain reserve-inclusive sum (no clamp), valuing the external
    ///      leg via `previewRedeem(balanceOf)` (Morpho V2's `maxWithdraw` is hardcoded 0 and unusable).
    ///      After a deposit it is NAV-neutral (~ deposit) and equals the live recoverable balance.
    function test_totalManagedAssets_tracksRecoverable(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        uint256 recoverable = _external.previewRedeem(_external.balanceOf(address(_fundManager)))
            + _fundManager.scaledYieldAssetsBalance() + _usdc.balanceOf(address(_fundManager));
        assertEq(_fundManager.totalManagedAssets(), recoverable, "totalManagedAssets == recoverable");
        assertEq(
            _fundManager.externalPositionValue(),
            _external.previewRedeem(_external.balanceOf(address(_fundManager))),
            "externalPositionValue == previewRedeem(balanceOf)"
        );
    }

}
