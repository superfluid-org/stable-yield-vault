// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { StableYieldVaultTestBase } from "./StableYieldVaultTestBase.t.sol";

import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";

import { ISuperToken, SuperToken } from "@superfluid-finance/ethereum-contracts/contracts/superfluid/SuperToken.sol";
import { TestToken } from "@superfluid-finance/ethereum-contracts/contracts/utils/TestToken.sol";

import { AsyncFundManager } from "src/async-vault/AsyncFundManager.sol";
import { IAsyncFundManager } from "src/interfaces/async-vault/IAsyncFundManager.sol";
import { IStableYieldAsyncVault } from "src/interfaces/async-vault/IStableYieldAsyncVault.sol";

contract AsyncFundManagerTest is StableYieldVaultTestBase {

    using SuperTokenV1Library for ISuperToken;

    event StableYieldRateChanged(uint256 oldRate, uint256 newRate);
    event GuaranteedFlowDurationChanged(uint256 oldDuration, uint256 newDuration);
    event Gave(address indexed from, uint256 amount);
    event Took(address indexed to, uint256 amount);

    uint256 internal constant DEFAULT_DEPOSIT = 1000 * 1e6;
    uint256 internal constant USDCX_SEED = 100 ether;

    function setUp() public override {
        super.setUp();
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
        vm.assertEq(_fundManager.stableYieldRate(), INITIAL_ERA_STABLE_YIELD_RATE, "incorrect stable yield rate");
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

        vm.expectRevert(IAsyncFundManager.ASSET_MISMATCH.selector);
        new AsyncFundManager(
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

        vm.expectRevert(IAsyncFundManager.DURATION_BELOW_FLOOR.selector);
        new AsyncFundManager(
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
            abi.encodeWithSelector(
                IAsyncFundManager.SETTLEMENT_PRECONDITIONS_NOT_MET.selector, "CURRENT_EPOCH_NOT_CLOSED"
            )
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
        uint128 expectedUnits = uint128(DEFAULT_DEPOSIT / _fundManager.RAW_PER_UNIT());
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
        vm.expectRevert(abi.encodeWithSelector(IAsyncFundManager.SETTLEMENT_PRECONDITIONS_NOT_MET.selector, reason));
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
        vm.expectRevert(abi.encodeWithSelector(IAsyncFundManager.SETTLEMENT_PRECONDITIONS_NOT_MET.selector, reason));
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
        vm.expectRevert(abi.encodeWithSelector(IAsyncFundManager.SETTLEMENT_PRECONDITIONS_NOT_MET.selector, reason));
        _fundManager.settleEpoch();
    }

    function test_give_pullsAndEmits() public {
        _dealUSDC(FUND_OPERATOR, DEFAULT_DEPOSIT);
        vm.startPrank(FUND_OPERATOR);

        _usdc.approve(address(_fundManager), DEFAULT_DEPOSIT);
        uint256 fmBefore = _usdc.balanceOf(address(_fundManager));

        vm.expectEmit(true, false, false, true, address(_fundManager));
        emit Gave(FUND_OPERATOR, DEFAULT_DEPOSIT);
        _fundManager.give(DEFAULT_DEPOSIT);

        vm.stopPrank();

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

    function test_setStableYieldRate_updatesAndEmits(uint256 newRate) public {
        newRate = bound(newRate, 1, 100_000); // ranges from 0.01% and 1000%

        // Prefund FM with underlying assets and yield asset (to cover for yield rebalance)
        _dealUSDCx(address(_fundManager), 100_000e18);
        _dealUSDC(address(_fundManager), 100_000e6);

        // Put the system in a state where its already flowing yield to users
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.startPrank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        _fundManager.settleEpoch();

        uint128 totalUnits = _fundManager.POOL().getTotalUnits();

        int96 previousFlowRatePerUnits = int96(
            int256(_fundManager.SCALING_FACTOR() * INITIAL_ERA_STABLE_YIELD_RATE / (_fundManager.YEAR() * 10_000))
        );

        vm.assertEq(
            int256(_fundManager.POOL().getTotalFlowRate()), int256(int128(totalUnits) * previousFlowRatePerUnits)
        );

        vm.expectEmit(false, false, false, true, address(_fundManager));
        emit StableYieldRateChanged(INITIAL_ERA_STABLE_YIELD_RATE, newRate);

        _fundManager.setStableYieldRate(newRate);
        vm.stopPrank();

        int96 newFlowRatePerUnits =
            int96(int256(_fundManager.SCALING_FACTOR() * newRate / (_fundManager.YEAR() * 10_000)));

        vm.assertEq(int256(_fundManager.POOL().getTotalFlowRate()), int256(int128(totalUnits) * newFlowRatePerUnits));
        vm.assertEq(_fundManager.stableYieldRate(), newRate);
    }

    function test_setStableYieldRate_revertsIfInvariantWouldBeViolated(uint256 increasedAnnualRate) public {
        increasedAnnualRate = bound(increasedAnnualRate, 1100, 10_000); // Range from 11% to 100% annual rate

        // Seed 2 USDCx (e.g. sufficient yield asset to cover for 1 x 1000 USDC deposit @ 10% stable yield rate)
        _dealUSDCx(address(_fundManager), 2 ether);
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.startPrank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        _fundManager.settleEpoch();

        // Fund Operator take the unutilized assets
        _fundManager.take(DEFAULT_DEPOSIT);

        // Choose a rate where the new flow still fits the GDA security deposit (~hours of flow)
        // but the 7-day invariant horizon exceeds the yield buffer.
        vm.expectRevert(IAsyncFundManager.INSUFFICIENT_UNUTILIZED_ASSETS.selector);
        _fundManager.setStableYieldRate(increasedAnnualRate);

        vm.stopPrank();
    }

    function test_setGuaranteedFlowDuration_updatesAndEmits(uint256 newDuration) public {
        newDuration = bound(newDuration, _fundManager.MIN_GUARANTEED_FLOW_DURATION(), 100 days);

        vm.expectEmit(false, false, false, true, address(_fundManager));
        emit GuaranteedFlowDurationChanged(GUARANTEED_FLOW_DURATION, newDuration);

        vm.prank(FUND_ADMIN);
        _fundManager.setGuaranteedFlowDuration(newDuration);

        vm.assertEq(_fundManager.guaranteedFlowDuration(), newDuration);
    }

    function test_setGuaranteedFlowDuration_revertsBelowFloor(uint256 belowFloorDuration) public {
        belowFloorDuration = bound(belowFloorDuration, 0, _fundManager.MIN_GUARANTEED_FLOW_DURATION() - 1);

        vm.prank(FUND_ADMIN);
        vm.expectRevert(IAsyncFundManager.DURATION_BELOW_FLOOR.selector);
        _fundManager.setGuaranteedFlowDuration(belowFloorDuration);
    }

    function test_setGuaranteedFlowDuration_cannotRebalanceYieldAssets() public {
        _seedYieldBuffer();
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        vm.prank(FUND_OPERATOR);
        _fundManager.settleEpoch();

        // Raising the horizon to 1000 years would require far more yield buffer than we hold
        vm.prank(FUND_ADMIN);
        vm.expectRevert(IAsyncFundManager.INSUFFICIENT_UNUTILIZED_ASSETS.selector);
        _fundManager.setGuaranteedFlowDuration(365 days * 1000);
    }

    //     ______      ______               __      ______          __
    //    / ____/___ _/ / / /_  ____ ______/ /__   /_  __/__  _____/ /______
    //   / /   / __ `/ / / __ \/ __ `/ ___/ //_/    / / / _ \/ ___/ __/ ___/
    //  / /___/ /_/ / / / /_/ / /_/ / /__/ ,<      / / /  __(__  ) /_(__  )
    //  \____/\__,_/_/_/_.___/\__,_/\___/_/|_|    /_/  \___/____/\__/____/

    function test_onRequestRedeem_revertsOnBadArgs(uint256 sharesOwned, uint256 sharesRedeemed) public {
        // Cap shares redeemed to strictly greated than share owned
        sharesOwned = bound(sharesOwned, 1, ONE_BILLION * 1e18);
        sharesRedeemed = bound(sharesRedeemed, sharesOwned, ONE_BILLION * 1e18);

        // sharesRedeemed > totalSharesOwned
        vm.prank(address(_vault));
        vm.expectRevert(IAsyncFundManager.BAD_REDEEM_ARGS.selector);
        _fundManager.onRequestRedeem(ALICE, sharesRedeemed, sharesOwned);

        // totalSharesOwned == 0
        vm.prank(address(_vault));
        vm.expectRevert(IAsyncFundManager.BAD_REDEEM_ARGS.selector);
        _fundManager.onRequestRedeem(ALICE, 0, 0);
    }

    function test_onRequestRedeem_revertsWhenNoUnits(uint256 sharesOwned, uint256 sharesRedeemed) public {
        // Cap shares redeemed to strictly lower than share owned
        sharesOwned = bound(sharesOwned, 1, ONE_BILLION * 1e18);
        sharesRedeemed = bound(sharesRedeemed, 1, sharesOwned);

        // ALICE has zero pool units — the hook shall revert
        ISuperfluidPool pool = _fundManager.POOL();
        vm.assertEq(pool.getUnits(ALICE), 0);

        vm.expectRevert(IAsyncFundManager.BAD_REDEEM_ARGS.selector);
        vm.prank(address(_vault));
        _fundManager.onRequestRedeem(ALICE, sharesRedeemed, sharesOwned);
    }

    function test_onRequestRedeem_reducesUnitsProportionally(uint256 proportion) public {
        proportion = bound(proportion, 100, 9900); // ranges from 1% to 99% of ALICE shares being redeemed
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
        _vault.requestRedeem(aliceShares * proportion / 10_000, ALICE, ALICE);

        uint128 aliceUnitsAfter = pool.getUnits(ALICE);

        vm.assertLt(aliceUnitsAfter, aliceUnitsBefore);
        vm.assertEq(aliceUnitsAfter, aliceUnitsBefore - (aliceUnitsBefore * proportion / 10_000));
    }

    function test_onClaimDeposit_movesUnitsFromFmToController() public {
        _seedYieldBuffer();
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);

        vm.startPrank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        _fundManager.settleEpoch();
        vm.stopPrank();

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
        usdcxBalance = bound(usdcxBalance, 0, ONE_BILLION * 1 ether);
        expectedBalance = bound(expectedBalance, 0, ONE_BILLION * 1e6);

        _dealUSDC(address(_fundManager), expectedBalance);
        _dealUSDCx(address(_fundManager), usdcxBalance);

        vm.assertEq(_fundManager.unutilizedAssetsBalance(), expectedBalance);
    }

    function test_yieldAssetsBalance(uint256 expectedBalance, uint256 usdcBalance) public {
        usdcBalance = bound(usdcBalance, 0, ONE_BILLION * 1e6);
        expectedBalance = bound(expectedBalance, 0, ONE_BILLION * 1 ether);

        _dealUSDC(address(_fundManager), usdcBalance);
        _dealUSDCx(address(_fundManager), expectedBalance);

        vm.assertEq(_fundManager.yieldAssetsBalance(), expectedBalance);
    }

    function test_scaledYieldAssetsBalance(uint256 expectedBalance, uint256 usdcBalance) public {
        usdcBalance = bound(usdcBalance, 0, ONE_BILLION * 1e6);
        expectedBalance = bound(expectedBalance, 0, ONE_BILLION * 1 ether);

        _dealUSDC(address(_fundManager), usdcBalance);
        _dealUSDCx(address(_fundManager), expectedBalance);

        uint256 expectedScaled = expectedBalance / _fundManager.SCALING_FACTOR();
        vm.assertEq(_fundManager.scaledYieldAssetsBalance(), expectedScaled);
    }

    function test_evaluateYieldAssetsDeficit_positiveWhenUnderfunded() public {
        _seedYieldBuffer();
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.startPrank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        _fundManager.settleEpoch();
        vm.stopPrank();

        vm.assertGt(_fundManager.evaluateYieldAssetsDeficit(), 0);
    }

    function test_evaluateYieldAssetsDeficit() public {
        // No units yet => target flow 0 => deficit 0
        vm.assertEq(_fundManager.evaluateYieldAssetsDeficit(), 0);

        _seedYieldBuffer();
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.startPrank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        _fundManager.settleEpoch();
        vm.stopPrank();

        // After settlement, yield asset is approximately balanced
        // So, we move forward 3 days (to stream-out the yield balance)
        vm.warp(block.timestamp + 3 days);

        int96 expectedFlowRate = _calculateExpectedFlowRate(_fundManager.POOL().getTotalUnits());
        uint256 requiredYieldAssetBalance =
            uint256(int256(expectedFlowRate) * int256(_fundManager.guaranteedFlowDuration()));

        int256 expectedDeficit = int256(requiredYieldAssetBalance) - int256(_fundManager.yieldAssetsBalance());

        // Deficit shall be positive (e.g. there are not enough yield assets)
        vm.assertGt(_fundManager.evaluateYieldAssetsDeficit(), 0);
        vm.assertEq(_fundManager.evaluateYieldAssetsDeficit(), expectedDeficit);

        _dealUSDCx(address(_fundManager), 1000 ether);

        expectedDeficit = int256(requiredYieldAssetBalance) - int256(_fundManager.yieldAssetsBalance());

        // Deficit shall be negative (e.g. there are more yield assets than needed)
        vm.assertLt(_fundManager.evaluateYieldAssetsDeficit(), 0);
        vm.assertEq(_fundManager.evaluateYieldAssetsDeficit(), expectedDeficit);
    }

    function test_ensureYieldFlowDuration_upgradeUnderlyingAsset() public {
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.startPrank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        _fundManager.settleEpoch();

        // Move 3 days forward (yield asset deficit shall be positive now)
        vm.warp(block.timestamp + 3 days);

        // Seed underlying assets (necessary for reblaancing the yield assets)
        _dealUSDC(address(_fundManager), 100 * 1e6);

        uint256 yieldAssetBefore = _fundManager.yieldAssetsBalance();
        uint256 underlyingAssetBefore = _fundManager.unutilizedAssetsBalance();

        _fundManager.ensureYieldFlowDuration();
        vm.stopPrank();

        vm.assertGt(_fundManager.yieldAssetsBalance(), yieldAssetBefore);
        vm.assertLt(_fundManager.unutilizedAssetsBalance(), underlyingAssetBefore);
    }

    function test_ensureYieldFlowDuration_downgradeYieldAsset() public {
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.startPrank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        _fundManager.settleEpoch();
        vm.stopPrank();

        // Move 3 days forward (yield asset deficit shall be positive now)
        vm.warp(block.timestamp + 3 days);

        // Seed more yield assets (more than necessary to trigger rebalancing into underlying assets)
        _dealUSDCx(address(_fundManager), 100 * 1e18);

        uint256 yieldAssetBefore = _fundManager.yieldAssetsBalance();
        uint256 underlyingAssetBefore = _fundManager.unutilizedAssetsBalance();

        int256 deficit = _fundManager.evaluateYieldAssetsDeficit();
        vm.assertLt(deficit, 0);

        vm.prank(FUND_OPERATOR);
        _fundManager.ensureYieldFlowDuration();

        vm.assertLt(_fundManager.yieldAssetsBalance(), yieldAssetBefore);
        vm.assertGt(_fundManager.unutilizedAssetsBalance(), underlyingAssetBefore);
    }

    function test_ensureYieldFlowDuration_restartFlow() public {
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.startPrank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        _fundManager.settleEpoch();
        vm.stopPrank();

        ISuperfluidPool pool = _fundManager.POOL();

        int96 flowRateBefore = pool.getTotalFlowRate();

        // Stop the flow (to simulate stream "liquidation")
        vm.prank(address(_fundManager));
        _sf.gdaV1Forwarder.distributeFlow(_usdcx, address(_fundManager), pool, 0, "");

        vm.assertEq(int256(pool.getTotalFlowRate()), 0);

        vm.prank(FUND_OPERATOR);
        _fundManager.ensureYieldFlowDuration();

        vm.assertEq(int256(pool.getTotalFlowRate()), int256(flowRateBefore));
    }

    /// @dev Empty state: no pool units, no balances, no snapshot.
    ///      Both branches collapse to zero — exercises the trivial path.
    function test_evaluateFunding_emptyState() public view {
        vm.assertEq(_fundManager.evaluateFunding(), 0);
    }

    /// @dev No pool units → requiredYieldAssetsBalance = 0 → branch 1 (yield excess).
    ///      Unutilized underlying is fully takeable, regardless of yield balance.
    function test_evaluateFunding_noUnits_unutilizedFullyTakeable(uint256 unutilized, uint256 yieldBalance) public {
        unutilized = bound(unutilized, 0, ONE_BILLION * 1e6);
        yieldBalance = bound(yieldBalance, 0, ONE_BILLION * 1 ether);

        _dealUSDC(address(_fundManager), unutilized);
        _dealUSDCx(address(_fundManager), yieldBalance);

        // Branch 1: funding = redeemingAssets(0) - (unutilized + 0) = -unutilized
        // Yield excess is intentionally NOT counted as takeable.
        vm.assertEq(_fundManager.evaluateFunding(), -int256(unutilized));
    }

    /// @dev Post-settlement steady state with extra yield buffer:
    ///      pool has units but yield balance covers the requirement → branch 1, funding = -unutilized.
    function test_evaluateFunding_postSettle_yieldExcess_isTakeable() public {
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.startPrank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        _fundManager.settleEpoch();
        vm.stopPrank();

        // Top up the buffer well past the target so we land squarely in branch 1.
        _dealUSDCx(address(_fundManager), 10 ether);

        vm.assertLe(_fundManager.evaluateYieldAssetsDeficit(), 0);
        vm.assertEq(_fundManager.evaluateFunding(), -int256(_fundManager.unutilizedAssetsBalance()));
    }

    /// @dev Post-settlement, time-warped so yield streams below the required buffer → branch 2.
    ///      Operator-takeable amount shrinks by the deficit (rescaled to underlying decimals) +1.
    function test_evaluateFunding_postSettle_yieldDeficit_branch2() public {
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.startPrank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        _fundManager.settleEpoch();
        vm.stopPrank();

        // Drain enough of the buffer to flip the deficit positive
        vm.warp(block.timestamp + 4 days);

        int256 yieldDeficit = _fundManager.evaluateYieldAssetsDeficit();
        vm.assertGt(yieldDeficit, 0);

        int256 unutilized = int256(_fundManager.unutilizedAssetsBalance());
        int256 expected = -unutilized + yieldDeficit / int256(_fundManager.SCALING_FACTOR()) + 1;

        vm.assertEq(_fundManager.evaluateFunding(), expected);
    }

    /// @dev Open snapshot with pending deposit only (no redeem).
    ///      depositingAssets is added on the "covered" side of underlyingAssetDeficit.
    function test_evaluateFunding_pendingDeposit() public {
        _seedYieldBuffer();
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);

        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);

        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();
        vm.assertEq(snap.depositingAssets, DEFAULT_DEPOSIT);
        vm.assertEq(snap.redeemingShares, 0);

        // Yield buffer was seeded generously → branch 1.
        // funding = 0 - (unutilizedFM + DEFAULT_DEPOSIT)
        int256 expected = -int256(_fundManager.unutilizedAssetsBalance() + DEFAULT_DEPOSIT);
        vm.assertEq(_fundManager.evaluateFunding(), expected);
    }

    /// @dev Open snapshot with pending redeem only (no new deposit).
    ///      redeemingShares × rate must show up as a positive funding requirement
    ///      net of whatever unutilized assets the FM already holds.
    function test_evaluateFunding_pendingRedeem() public {
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

        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);

        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();
        vm.assertEq(snap.depositingAssets, 0);
        vm.assertEq(snap.redeemingShares, aliceShares);
        uint256 redeemingAssets = snap.redeemingShares * snap.rate / 1e18;

        // Yield buffer was seeded → branch 1.
        // funding = redeemingAssets - (unutilizedFM + 0)
        int256 expected = int256(redeemingAssets) - int256(_fundManager.unutilizedAssetsBalance());
        vm.assertEq(_fundManager.evaluateFunding(), expected);
    }

    /// @dev Open snapshot, pending deposit, yield-deficit branch 2.
    ///      depositingAssets must inflate newTotalUnits → larger required buffer.
    function test_evaluateFunding_pendingDeposit_yieldDeficit_branch2() public {
        // First settle to anchor units in the pool, then drain time so yield is below target.
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.startPrank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        _fundManager.settleEpoch();
        vm.stopPrank();

        vm.warp(block.timestamp + 5 days);

        // New deposit lands in a fresh snapshot, expanding the unit base.
        _requestDeposit(BOB, DEFAULT_DEPOSIT);
        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);

        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();
        vm.assertEq(snap.depositingAssets, DEFAULT_DEPOSIT);

        // Mirror the contract's own deficit calculation (uses *new* units, not current units).
        int256 yieldDeficit = _expectedYieldDeficitWithSnapshotUnits(snap);
        vm.assertGt(yieldDeficit, 0);

        int256 unutilized = int256(_fundManager.unutilizedAssetsBalance());
        int256 expected =
            -int256(uint256(unutilized) + DEFAULT_DEPOSIT) + yieldDeficit / int256(_fundManager.SCALING_FACTOR()) + 1;

        vm.assertEq(_fundManager.evaluateFunding(), expected);
    }

    /// @dev Fuzz over post-settle branch 1 (yield excess): adding USDCx and USDC must keep us
    ///      in branch 1 and produce funding = -unutilized regardless of how much extra yield we hold.
    ///      Lower bound of 1 ether comfortably covers the GDA security deposit deducted at flow start.
    function test_evaluateFunding_fuzz_branch1_postSettle(uint256 extraYield, uint256 extraUnutilized) public {
        extraYield = bound(extraYield, 1 ether, ONE_BILLION * 1 ether);
        extraUnutilized = bound(extraUnutilized, 0, ONE_BILLION * 1e6);

        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.startPrank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        _fundManager.settleEpoch();
        vm.stopPrank();

        _dealUSDCx(address(_fundManager), extraYield);
        _dealUSDC(address(_fundManager), extraUnutilized);

        // After settle, deficit is non-positive; topping up only deepens the excess → branch 1.
        vm.assertLe(_fundManager.evaluateYieldAssetsDeficit(), 0);
        vm.assertEq(_fundManager.evaluateFunding(), -int256(_fundManager.unutilizedAssetsBalance()));
    }

    /// @dev Fuzz over post-settle branch 2 (yield deficit): warp by a bounded duration to
    ///      drain the buffer below required, vary unutilized, and assert the closed-form result.
    function test_evaluateFunding_fuzz_branch2_postSettle(uint256 timeWarp, uint256 extraUnutilized) public {
        timeWarp = bound(timeWarp, 1 days, 6 days);
        extraUnutilized = bound(extraUnutilized, 0, ONE_BILLION * 1e6);

        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.startPrank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        _fundManager.settleEpoch();
        vm.stopPrank();

        vm.warp(block.timestamp + timeWarp);
        _dealUSDC(address(_fundManager), extraUnutilized);

        int256 yieldDeficit = _fundManager.evaluateYieldAssetsDeficit();
        vm.assertGt(yieldDeficit, 0);

        int256 unutilized = int256(_fundManager.unutilizedAssetsBalance());
        int256 expected = -unutilized + yieldDeficit / int256(_fundManager.SCALING_FACTOR()) + 1;

        vm.assertEq(_fundManager.evaluateFunding(), expected);
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
        amount = bound(amount, 1, ONE_BILLION * 1e6);

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

    //    ______          __     __  __     __                   ______                 __  _
    //   /_  __/__  _____/ /_   / / / /__  / /___  ___  _____   / ____/_  ______  _____/ /_(_)___  ____  _____
    //    / / / _ \/ ___/ __/  / /_/ / _ \/ / __ \/ _ \/ ___/  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / / /  __(__  ) /_   / __  /  __/ / /_/ /  __/ /     / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /_/  \___/____/\__/  /_/ /_/\___/_/ .___/\___/_/     /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/
    //                                   /_/

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
        (TestToken underlyingToken, SuperToken superTokenToken) =
            _deployer.deployWrapperSuperToken(name, name, decimals, type(uint256).max, address(0));

        underlying = address(underlyingToken);
        superToken = address(superTokenToken);
    }

    /// @dev Seeds the FundManager with USDCx so flow recalibration / invariant checks succeed.
    ///      Called only by tests that exercise the streaming flow (keeps fuzz-balance tests unaffected).
    function _seedYieldBuffer() internal {
        _dealUSDCx(address(_fundManager), USDCX_SEED);
    }

    function _calculateExpectedFlowRate(uint128 poolUnits) internal view returns (int96 expectedFlowRate) {
        // Mirrors FundManager: SCALING_FACTOR · RAW_PER_UNIT = 10^12 for any supported decimals.
        int96 flowRatePerUnit = int96(int256(1e12 * _fundManager.stableYieldRate() / (_fundManager.YEAR() * 10_000)));

        expectedFlowRate = flowRatePerUnit * int96(int128(poolUnits));
    }

    /// @dev Mirrors the deficit calculation embedded inside `evaluateFunding`: required balance is sized
    ///      for `currentUnits + snap.depositingAssets / RAW_PER_UNIT`, not just current units.
    function _expectedYieldDeficitWithSnapshotUnits(IStableYieldAsyncVault.Snapshot memory snap)
        internal
        view
        returns (int256 deficit)
    {
        uint128 newTotalUnits =
            _fundManager.POOL().getTotalUnits() + uint128(snap.depositingAssets / _fundManager.RAW_PER_UNIT());
        int96 expectedNewFlowRate = _calculateExpectedFlowRate(newTotalUnits);
        uint256 requiredBalance = uint256(uint96(expectedNewFlowRate)) * _fundManager.guaranteedFlowDuration();
        deficit = int256(requiredBalance) - int256(_fundManager.yieldAssetsBalance());
    }

}
