// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { StableYieldVaultTestBase } from "./StableYieldVaultTestBase.t.sol";

import { IAccessControl } from "@openzeppelin-v5/contracts/access/AccessControl.sol";

import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";
import { FundManager } from "src/FundManager.sol";

import { StableYieldAsyncVault } from "src/StableYieldAsyncVault.sol";
import { IFundManager } from "src/interfaces/IFundManager.sol";
import { IStableYieldAsyncVault } from "src/interfaces/vault/IStableYieldAsyncVault.sol";

contract FundManagerTest is StableYieldVaultTestBase {

    event EraStableYieldRateChanged(uint256 oldRate, uint256 newRate);
    event GuaranteedFlowDurationChanged(uint256 oldDuration, uint256 newDuration);
    event Gave(address indexed from, uint256 amount);
    event Took(address indexed to, uint256 amount);

    uint256 internal constant DEFAULT_DEPOSIT = 1000 * 1e6;
    uint256 internal constant USDCX_SEED = 100 ether;

    function setUp() public override {
        super.setUp();
    }

    /// @dev Seeds the FundManager with USDCx so flow recalibration / invariant checks succeed.
    ///      Called only by tests that exercise the streaming flow (keeps fuzz-balance tests unaffected).
    function _seedYieldBuffer() internal {
        _dealUSDCx(address(_fundManager), USDCX_SEED);
    }

    function _calculateExpectedFlowRate(uint128 poolUnits) internal view returns (int96 expectedFlowRate) {
        int96 flowRatePerUnit = int96(
            int256(_fundManager.SCALING_FACTOR() * _fundManager.eraStableYieldRate() / (_fundManager.YEAR() * 10_000))
        );

        expectedFlowRate = flowRatePerUnit * int96(int128(poolUnits));
    }

    //     ______                 __                  __                ______          __
    //    / ____/___  ____  _____/ /________  _______/ /_____  _____   /_  __/__  _____/ /______
    //   / /   / __ \/ __ \/ ___/ __/ ___/ / / / ___/ __/ __ \/ ___/    / / / _ \/ ___/ __/ ___/
    //  / /___/ /_/ / / / (__  ) /_/ /  / /_/ / /__/ /_/ /_/ / /       / / /  __(__  ) /_(__  )
    //  \____/\____/_/ /_/____/\__/_/   \__,_/\___/\__/\____/_/       /_/  \___/____/\__/____/

    function test_constructor_initialState() public view {
        vm.assertEq(address(_fundManager.UNDERLYING_ASSET()), address(_usdc), "incorrect underlying asset");
        vm.assertEq(address(_fundManager.YIELD_ASSET()), address(_usdcx), "incorrect yield asset");
        vm.assertEq(_fundManager.SCALING_FACTOR(), 1e12, "incorrect scaling factor");
        vm.assertEq(_fundManager.eraStableYieldRate(), INITIAL_ERA_STABLE_YIELD_RATE, "incorrect stable yield rate");
        vm.assertEq(
            _fundManager.guaranteedFlowDuration(), GUARANTEED_FLOW_DURATION, "incorrect guaranteed flow duration"
        );
        vm.assertTrue(
            _fundManager.hasRole(_fundManager.FUND_OPERATOR_ROLE(), FUND_OPERATOR), "Fund Operator role mismatch"
        );
        vm.assertTrue(_fundManager.hasRole(_fundManager.DEFAULT_ADMIN_ROLE(), FUND_ADMIN), "Fund Admin role mismatch");
        vm.assertTrue(_fundManager.hasRole(_fundManager.VAULT_ROLE(), address(_vault)), "Vault role mismatch");
        vm.assertEq(address(_fundManager.VAULT()), address(_vault), "incorrect vault address");
        vm.assertNotEq(address(_fundManager.POOL()), address(0), "GDA pool not created");
    }

    function test_constructor_revertsOnMismatchedSuperToken() public {
        (, address otherUsdcx) = _deployFreshWrapper("XYZ", 6);

        vm.expectRevert(IFundManager.ASSET_MISMATCH.selector);
        new FundManager(
            address(_usdc),
            otherUsdcx,
            FUND_OPERATOR,
            FUND_ADMIN,
            INITIAL_ERA_STABLE_YIELD_RATE,
            GUARANTEED_FLOW_DURATION
        );
    }

    function test_constructor_revertsOnDurationBelowFloor(uint256 belowFloorDuration) public {
        belowFloorDuration = bound(belowFloorDuration, 0, _fundManager.MIN_GUARANTEED_FLOW_DURATION() - 1);

        vm.expectRevert(IFundManager.DURATION_BELOW_FLOOR.selector);
        new FundManager(
            address(_usdc),
            address(_usdcx),
            FUND_OPERATOR,
            FUND_ADMIN,
            INITIAL_ERA_STABLE_YIELD_RATE,
            belowFloorDuration
        );
    }

    //    ________                   ______                 __
    //   / ____/ /___  ________     / ____/___  ____  _____/ /_
    //  / /   / / __ \/ ___/ _ \   / __/ / __ \/ __ \/ ___/ __ \
    // / /___/ / /_/ (__  )  __/  / /___/ /_/ / /_/ / /__/ / / /
    // \____/_/\____/____/\___/  /_____/ .___/\____/\___/_/ /_/
    //                                /_/
    function test_closeEpoch(uint256 workingAssets, uint256 unutilizedAssets, uint256 yieldAssets) public {
        workingAssets = bound(workingAssets, 0, ONE_BILLION * 1e6);
        unutilizedAssets = bound(unutilizedAssets, 0, ONE_BILLION * 1e6);
        yieldAssets = bound(yieldAssets, 0, ONE_BILLION * 1e18);

        // Seed FM with some unutilized USDC and USDCx
        _dealUSDC(address(_fundManager), unutilizedAssets);
        _dealUSDCx(address(_fundManager), yieldAssets);

        uint256 expectedScaledYield = yieldAssets / _fundManager.SCALING_FACTOR();

        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(workingAssets);

        // Vault captures the reported total in totalAssets()
        vm.assertEq(_vault.totalAssets(), workingAssets + unutilizedAssets + expectedScaledYield);
    }

    //     _____      __  __  __        ______                 __
    //    / ___/___  / /_/ /_/ /__     / ____/___  ____  _____/ /_
    //    \__ \/ _ \/ __/ __/ / _ \   / __/ / __ \/ __ \/ ___/ __ \
    //   ___/ /  __/ /_/ /_/ /  __/  / /___/ /_/ / /_/ / /__/ / / /
    //  /____/\___/\__/\__/_/\___/  /_____/ .___/\____/\___/_/ /_/
    //                                   /_/

    function test_settleEpoch_revertsIfNoEpochClosed() public {
        vm.prank(FUND_OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(IFundManager.SETTLEMENT_PRECONDITIONS_NOT_MET.selector, "CURRENT_EPOCH_NOT_CLOSED")
        );

        _fundManager.settleEpoch();
    }

    function test_settleEpoch_grantsUnitsToFundManager_andRecalibratesFlow() public {
        _seedYieldBuffer();
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);

        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);

        ISuperfluidPool pool = _fundManager.POOL();

        vm.prank(FUND_OPERATOR);
        _fundManager.settleEpoch();

        uint128 totalUnits = pool.getTotalUnits();
        uint128 expectedUnits = uint128(DEFAULT_DEPOSIT * _fundManager.UNIT_PER_ASSET_DEPOSITED());
        vm.assertEq(totalUnits, expectedUnits);
        vm.assertEq(pool.getUnits(address(_fundManager)), expectedUnits);
        vm.assertEq(pool.getTotalFlowRate(), _calculateExpectedFlowRate(totalUnits));
        vm.assertEq(pool.getMemberFlowRate(address(_fundManager)), _calculateExpectedFlowRate(totalUnits));
    }

    //     ______               _____      __  __  __        ______                 __
    //    / ____/___ _____     / ___/___  / /_/ /_/ /__     / ____/___  ____  _____/ /_
    //   / /   / __ `/ __ \    \__ \/ _ \/ __/ __/ / _ \   / __/ / __ \/ __ \/ ___/ __ \
    //  / /___/ /_/ / / / /   ___/ /  __/ /_/ /_/ /  __/  / /___/ /_/ / /_/ / /__/ / / /
    //  \____/\__,_/_/ /_/   /____/\___/\__/\__/_/\___/  /_____/ .___/\____/\___/_/ /_/
    //                                                        /_/

    function test_canSettleEpoch_returnsFalseBeforeClose() public {
        uint256 epoch = _vault.getSnapshot().epoch;

        vm.assertEq(epoch, 0);

        (bool canSettle, string memory reason,) = _fundManager.canSettleEpoch();

        vm.assertFalse(canSettle);
        vm.assertEq(reason, "CURRENT_EPOCH_NOT_CLOSED");

        vm.prank(FUND_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(IFundManager.SETTLEMENT_PRECONDITIONS_NOT_MET.selector, reason));
        _fundManager.settleEpoch();
    }

    function test_canSettleEpoch_returnsFalseWhenInsufficientYield() public {
        // FM holds zero USDCx and zero unutilized USDC. Inflating pool units before close
        // pushes the post-settle yield buffer requirement above what depositing assets can fund.
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        _inflateUnitsToBreakInvariant();

        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);

        (bool canSettle, string memory reason,) = _fundManager.canSettleEpoch();

        vm.assertFalse(canSettle);
        vm.assertEq(reason, "INSUFFICIENT_ASSETS_IN_FUND_MANAGER");

        vm.prank(FUND_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(IFundManager.SETTLEMENT_PRECONDITIONS_NOT_MET.selector, reason));
        _fundManager.settleEpoch();
    }

    function test_canSettleEpoch_returnsFalseWhenDeficitCannotBeCovered() public {
        _seedYieldBuffer();

        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        vm.prank(FUND_OPERATOR);
        _fundManager.settleEpoch();

        vm.prank(ALICE);
        _vault.deposit(DEFAULT_DEPOSIT, ALICE);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        vm.prank(ALICE);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);

        // Close while FM still holds full reserves so the snapshot rate is rich.
        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);

        // Drain FM's unutilized USDC after the snapshot — available now sits below the
        // redeem outflow priced at the snapshotted rate.
        uint256 fmUsdc = _usdc.balanceOf(address(_fundManager));
        vm.prank(address(_fundManager));
        _usdc.transfer(address(0xdead), fmUsdc);

        (bool canSettle, string memory reason,) = _fundManager.canSettleEpoch();

        vm.assertFalse(canSettle);
        vm.assertEq(reason, "INSUFFICIENT_ASSETS_IN_FUND_MANAGER");

        vm.prank(FUND_OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(IFundManager.SETTLEMENT_PRECONDITIONS_NOT_MET.selector, reason));
        _fundManager.settleEpoch();
    }

    function test_give_pullsAndEmits() public {
        _dealUSDC(FUND_OPERATOR, DEFAULT_DEPOSIT);
        vm.prank(FUND_OPERATOR);
        _usdc.approve(address(_fundManager), DEFAULT_DEPOSIT);

        uint256 fmBefore = _usdc.balanceOf(address(_fundManager));

        vm.expectEmit(true, false, false, true, address(_fundManager));
        emit Gave(FUND_OPERATOR, DEFAULT_DEPOSIT);

        vm.prank(FUND_OPERATOR);
        _fundManager.give(DEFAULT_DEPOSIT);

        vm.assertEq(_usdc.balanceOf(address(_fundManager)), fmBefore + DEFAULT_DEPOSIT);
    }

    function test_take_transfersAndEmits() public {
        _dealUSDC(address(_fundManager), DEFAULT_DEPOSIT);
        uint256 opBefore = _usdc.balanceOf(FUND_OPERATOR);

        vm.expectEmit(true, false, false, true, address(_fundManager));
        emit Took(FUND_OPERATOR, DEFAULT_DEPOSIT);

        vm.prank(FUND_OPERATOR);
        _fundManager.take(DEFAULT_DEPOSIT);

        vm.assertEq(_usdc.balanceOf(FUND_OPERATOR), opBefore + DEFAULT_DEPOSIT);
    }

    function test_setStableYieldRate_updatesAndEmits() public {
        uint256 newRate = 2000; // 20%

        vm.expectEmit(false, false, false, true, address(_fundManager));
        emit EraStableYieldRateChanged(INITIAL_ERA_STABLE_YIELD_RATE, newRate);

        vm.prank(FUND_OPERATOR);
        _fundManager.setStableYieldRate(newRate);

        vm.assertEq(_fundManager.eraStableYieldRate(), newRate);
    }

    function test_setStableYieldRate_revertsIfInvariantWouldBeViolated() public {
        _seedYieldBuffer();
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        vm.prank(FUND_OPERATOR);
        _fundManager.settleEpoch();

        // Choose a rate where the new flow still fits the GDA security deposit (~hours of flow)
        // but the 7-day invariant horizon exceeds the yield buffer.
        vm.prank(FUND_OPERATOR);
        vm.expectRevert(IFundManager.INVARIANT_VIOLATED.selector);
        _fundManager.setStableYieldRate(INITIAL_ERA_STABLE_YIELD_RATE * 500);
    }

    function test_setGuaranteedFlowDuration_updatesAndEmits() public {
        uint256 newDuration = 30 days;

        vm.expectEmit(false, false, false, true, address(_fundManager));
        emit GuaranteedFlowDurationChanged(GUARANTEED_FLOW_DURATION, newDuration);

        vm.prank(FUND_ADMIN);
        _fundManager.setGuaranteedFlowDuration(newDuration);

        vm.assertEq(_fundManager.guaranteedFlowDuration(), newDuration);
    }

    function test_setGuaranteedFlowDuration_revertsBelowFloor() public {
        uint256 below = _fundManager.MIN_GUARANTEED_FLOW_DURATION() - 1;

        vm.prank(FUND_ADMIN);
        vm.expectRevert(IFundManager.DURATION_BELOW_FLOOR.selector);
        _fundManager.setGuaranteedFlowDuration(below);
    }

    function test_setGuaranteedFlowDuration_revertsIfInvariantWouldBeViolated() public {
        _seedYieldBuffer();
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        vm.prank(FUND_OPERATOR);
        _fundManager.settleEpoch();

        // Raising the horizon to 1000 years would require far more yield buffer than we hold
        vm.prank(FUND_ADMIN);
        vm.expectRevert(IFundManager.INSUFFICIENT_UNUTILIZED_ASSETS.selector);
        _fundManager.setGuaranteedFlowDuration(365 days * 1000);
    }

    function test_onRequestRedeem_revertsOnBadArgs() public {
        // sharesRedeemed > totalSharesOwned
        vm.prank(address(_vault));
        vm.expectRevert(IFundManager.BAD_REDEEM_ARGS.selector);
        _fundManager.onRequestRedeem(ALICE, 10, 5);

        // totalSharesOwned == 0
        vm.prank(address(_vault));
        vm.expectRevert(IFundManager.BAD_REDEEM_ARGS.selector);
        _fundManager.onRequestRedeem(ALICE, 0, 0);
    }

    function test_onRequestRedeem_revertsWhenNoUnits() public {
        // ALICE has zero pool units — the hook should be a no-op
        ISuperfluidPool pool = _fundManager.POOL();
        vm.assertEq(pool.getUnits(ALICE), 0);

        vm.expectRevert(IFundManager.BAD_REDEEM_ARGS.selector);
        vm.prank(address(_vault));
        _fundManager.onRequestRedeem(ALICE, 100, 100);
    }

    function test_onRequestRedeem_reducesUnitsProportionally() public {
        _seedYieldBuffer();
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        vm.prank(FUND_OPERATOR);
        _fundManager.settleEpoch();

        vm.prank(ALICE);
        _vault.deposit(DEFAULT_DEPOSIT, ALICE);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        ISuperfluidPool pool = _fundManager.POOL();
        uint128 aliceUnitsBefore = pool.getUnits(ALICE);
        vm.assertGt(aliceUnitsBefore, 0);

        // Redeem half — units should drop by ~half
        vm.prank(ALICE);
        _vault.requestRedeem(aliceShares / 2, ALICE, ALICE);

        uint128 aliceUnitsAfter = pool.getUnits(ALICE);
        vm.assertLt(aliceUnitsAfter, aliceUnitsBefore);
        vm.assertApproxEqAbs(aliceUnitsAfter, aliceUnitsBefore / 2, 1);
    }

    function test_onClaimDeposit_movesUnitsFromFmToController() public {
        _seedYieldBuffer();
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        vm.prank(FUND_OPERATOR);
        _fundManager.settleEpoch();

        ISuperfluidPool pool = _fundManager.POOL();
        uint128 fmUnitsBefore = pool.getUnits(address(_fundManager));
        uint128 aliceUnitsBefore = pool.getUnits(ALICE);
        uint128 totalUnitsBefore = pool.getTotalUnits();

        vm.assertGt(fmUnitsBefore, 0);
        vm.assertEq(aliceUnitsBefore, 0);

        vm.prank(ALICE);
        _vault.deposit(DEFAULT_DEPOSIT, ALICE);

        // FM's units drop to 0, Alice picks them up; total is conserved
        vm.assertEq(pool.getUnits(address(_fundManager)), 0);
        vm.assertEq(pool.getUnits(ALICE), fmUnitsBefore);
        vm.assertEq(pool.getTotalUnits(), totalUnitsBefore);
    }

    //   _    ___                 ______                 __  _                ______          __
    //  | |  / (_)__ _      __   / ____/_  ______  _____/ /_(_)___  ____     /_  __/__  _____/ /______
    //  | | / / / _ \ | /| / /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \     / / / _ \/ ___/ __/ ___/
    //  | |/ / /  __/ |/ |/ /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / /    / / /  __(__  ) /_(__  )
    //  |___/_/\___/|__/|__/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/    /_/  \___/____/\__/____/

    function test_unutilizedAssetsBalance(uint256 expectedBalance, uint256 usdcxBalance) public {
        usdcxBalance = bound(usdcxBalance, 0, 100e9 ether);
        expectedBalance = bound(expectedBalance, 0, 100e9 * 1e6);

        _dealUSDC(address(_fundManager), expectedBalance);
        _dealUSDCx(address(_fundManager), usdcxBalance);

        vm.assertEq(_fundManager.unutilizedAssetsBalance(), expectedBalance);
    }

    function test_yieldAssetsBalance(uint256 expectedBalance, uint256 usdcBalance) public {
        usdcBalance = bound(usdcBalance, 0, 100e9 * 1e6);
        expectedBalance = bound(expectedBalance, 0, 100e9 ether);

        _dealUSDC(address(_fundManager), usdcBalance);
        _dealUSDCx(address(_fundManager), expectedBalance);

        vm.assertEq(_fundManager.yieldAssetsBalance(), expectedBalance);
    }

    function test_scaledYieldAssetsBalance(uint256 expectedBalance, uint256 usdcBalance) public {
        usdcBalance = bound(usdcBalance, 0, 100e9 * 1e6);
        expectedBalance = bound(expectedBalance, 0, 100e9 ether);

        _dealUSDC(address(_fundManager), usdcBalance);
        _dealUSDCx(address(_fundManager), expectedBalance);

        uint256 expectedScaled = expectedBalance / _fundManager.SCALING_FACTOR();
        vm.assertEq(_fundManager.scaledYieldAssetsBalance(), expectedScaled);
    }

    function test_evaluateYieldAssetsDeficit_zeroWhenFullyFunded() public view {
        // No units yet => target flow 0 => deficit 0
        vm.assertEq(_fundManager.evaluateYieldAssetsDeficit(), 0);
    }

    function test_evaluateYieldAssetsDeficit_positiveWhenUnderfunded() public {
        _seedYieldBuffer();
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        vm.prank(FUND_OPERATOR);
        _fundManager.settleEpoch();

        // Push required balance above actual by inflating pool units
        _inflateUnitsToBreakInvariant();

        vm.assertGt(_fundManager.evaluateYieldAssetsDeficit(), 0);
    }

    function _requestDeposit(address user, uint256 amount) internal {
        _dealUSDC(user, amount);
        vm.prank(user);
        _usdc.approve(address(_vault), type(uint256).max);
        vm.prank(user);
        _vault.requestDeposit(amount, user, user);
    }

    /// @dev Inflates the pool's total units so the target flow rate exceeds what the yield buffer can sustain.
    ///      Does not call distributeFlow, so the real stream keeps running at the old rate; only the
    ///      required-balance calculation in `evaluateYieldAssetsDeficit` tips over into a deficit.
    function _inflateUnitsToBreakInvariant() internal {
        ISuperfluidPool pool = _fundManager.POOL(); // resolve before the prank is consumed
        vm.prank(address(_fundManager));
        pool.updateMemberUnits(address(0xbeef), uint128(1e12));
    }

    /// @dev Deploys a fresh wrapper super-token pair using the base's framework deployer.
    function _deployFreshWrapper(string memory name, uint8 decimals)
        internal
        returns (address underlying, address superToken)
    {
        (, address stk) = (address(0), address(0));
        bytes memory callData = abi.encodeWithSignature(
            "deployWrapperSuperToken(string,string,uint8,uint256,address)",
            name,
            name,
            decimals,
            type(uint256).max,
            address(0)
        );
        (bool ok, bytes memory ret) = address(_deployer).call(callData);
        require(ok, "deployWrapperSuperToken failed");
        (underlying, stk) = abi.decode(ret, (address, address));
        superToken = stk;
    }

    //      ___                               ______            __             __   ______          __
    //     /   | _____________  __________   / ____/___  ____  / /__________  / /  /_  __/__  _____/ /______
    //    / /| |/ ___/ ___/ _ \/ ___/ ___/  / /   / __ \/ __ \/ __/ ___/ __ \/ /    / / / _ \/ ___/ __/ ___/
    //   / ___ / /__/ /__/  __(__  |__  )  / /___/ /_/ / / / / /_/ /  / /_/ / /    / / /  __(__  ) /_(__  )
    //  /_/  |_\___/\___/\___/____/____/   \____/\____/_/ /_/\__/_/   \____/_/    /_/  \___/____/\__/____/

    function test_closeEpoch_accessControl(address nonFundOperator, uint256 workingAssets) public {
        vm.assume(_fundManager.hasRole(_fundManager.FUND_OPERATOR_ROLE(), nonFundOperator) == false);
        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.closeEpoch(workingAssets);
    }

    function test_settleEpoch_accessControl(address nonFundOperator) public {
        vm.assume(_fundManager.hasRole(_fundManager.FUND_OPERATOR_ROLE(), nonFundOperator) == false);
        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.settleEpoch();
    }

    function test_give_accessControl(address nonFundOperator, uint256 amount) public {
        vm.assume(_fundManager.hasRole(_fundManager.FUND_OPERATOR_ROLE(), nonFundOperator) == false);
        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.give(amount);
    }

    function test_take_accessControl(address nonFundOperator, uint256 amount) public {
        vm.assume(_fundManager.hasRole(_fundManager.FUND_OPERATOR_ROLE(), nonFundOperator) == false);
        amount = bound(amount, 1, 100e9 * 1e6);

        _dealUSDC(address(_fundManager), amount);

        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.take(amount);
    }

    function test_setStableYieldRate_accessControl(address nonFundOperator, uint256 newRate) public {
        vm.assume(_fundManager.hasRole(_fundManager.FUND_OPERATOR_ROLE(), nonFundOperator) == false);
        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.setStableYieldRate(newRate);
    }

    function test_setGuaranteedFlowDuration_accessControl(address nonFundOperator, uint256 newDuration) public {
        vm.assume(_fundManager.hasRole(_fundManager.DEFAULT_ADMIN_ROLE(), nonFundOperator) == false);
        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.setGuaranteedFlowDuration(newDuration);
    }

    function test_onRequestRedeem_accessControl(address nonVault, address redeemer, uint256 shareAmount) public {
        vm.assume(_fundManager.hasRole(_fundManager.VAULT_ROLE(), nonVault) == false);

        vm.prank(nonVault);
        vm.expectRevert();

        _fundManager.onRequestRedeem(redeemer, shareAmount, shareAmount);
    }

    function test_onClaimDeposit_accessControl(address nonVault, address depositor, uint256 depositAmount) public {
        vm.assume(_fundManager.hasRole(_fundManager.VAULT_ROLE(), nonVault) == false);

        vm.prank(nonVault);
        vm.expectRevert();

        _fundManager.onClaimDeposit(depositor, depositAmount);
    }

}
