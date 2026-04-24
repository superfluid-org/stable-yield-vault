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

    event AnnualRateChanged(uint256 oldRate, uint256 newRate);
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

    function test_upgrade_accessControl(address nonFundOperator, uint256 amount) public {
        vm.assume(_fundManager.hasRole(_fundManager.FUND_OPERATOR_ROLE(), nonFundOperator) == false);
        amount = bound(amount, 1, 100e9 * 1e6);

        _dealUSDC(address(_fundManager), amount);

        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.upgrade(amount);
    }

    function test_downgrade_accessControl(address nonFundOperator, uint256 amount) public {
        vm.assume(_fundManager.hasRole(_fundManager.FUND_OPERATOR_ROLE(), nonFundOperator) == false);
        amount = bound(amount, 1, 100e9 ether);

        _dealUSDCx(address(_fundManager), amount);

        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.downgrade(amount);
    }

    function test_setAnnualRate_accessControl(address nonFundOperator, uint256 newRate) public {
        vm.assume(_fundManager.hasRole(_fundManager.FUND_OPERATOR_ROLE(), nonFundOperator) == false);
        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.setAnnualRate(newRate);
    }

    function test_setGuaranteedFlowDuration_accessControl(address nonFundOperator, uint256 newDuration) public {
        vm.assume(_fundManager.hasRole(_fundManager.FUND_OPERATOR_ROLE(), nonFundOperator) == false);
        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.setGuaranteedFlowDuration(newDuration);
    }

    function test_setVault_accessControl(address nonAdmin, address newVault) public {
        vm.assume(_fundManager.hasRole(_fundManager.DEFAULT_ADMIN_ROLE(), nonAdmin) == false);
        vm.prank(nonAdmin);
        vm.expectRevert();

        _fundManager.setVault(newVault);
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

    function test_move_accessControl(address nonVault, address recipient, uint256 amount) public {
        vm.assume(_fundManager.hasRole(_fundManager.VAULT_ROLE(), nonVault) == false);

        vm.prank(nonVault);
        vm.expectRevert();

        _fundManager.move(recipient, amount);
    }

    function test_constructor_initialState() public view {
        vm.assertEq(address(_fundManager.ASSET()), address(_usdc));
        vm.assertEq(address(_fundManager.SUPER_TOKEN()), address(_usdcx));
        vm.assertEq(_fundManager.SUPER_TOKEN_SCALE(), 1e12);
        vm.assertEq(_fundManager.annualRate(), INITIAL_ANNUAL_RATE);
        vm.assertEq(_fundManager.guaranteedFlowDuration(), GUARANTEED_FLOW_DURATION);
        vm.assertTrue(_fundManager.hasRole(_fundManager.FUND_OPERATOR_ROLE(), FUND_OPERATOR));
        vm.assertTrue(_fundManager.hasRole(_fundManager.DEFAULT_ADMIN_ROLE(), DEPLOYER));
        vm.assertTrue(_fundManager.hasRole(_fundManager.VAULT_ROLE(), address(_vault)));
        vm.assertEq(address(_fundManager.vault()), address(_vault));
        vm.assertNotEq(address(_fundManager.POOL()), address(0));
    }

    function test_constructor_revertsOnMismatchedSuperToken() public {
        (, address otherUsdcx) = _deployFreshWrapper("XYZ", 6);

        vm.expectRevert(IFundManager.NOT_INITIALIZED.selector);
        new FundManager(address(_usdc), otherUsdcx, FUND_OPERATOR, INITIAL_ANNUAL_RATE, GUARANTEED_FLOW_DURATION);
    }

    function test_constructor_revertsOnDurationBelowFloor() public {
        uint256 belowFloor = _fundManager.MIN_GUARANTEED_FLOW_DURATION() - 1;

        vm.expectRevert(IFundManager.DURATION_BELOW_FLOOR.selector);
        new FundManager(address(_usdc), address(_usdcx), FUND_OPERATOR, INITIAL_ANNUAL_RATE, belowFloor);
    }

    function test_closeEpoch_forwardsTotalFundAssetsToVault() public {
        // Seed FM with some unutilized USDC and USDCx
        _dealUSDC(address(_fundManager), 500e6);
        uint256 expectedScaledYield = _fundManager.yieldAssetsBalance() / _fundManager.SUPER_TOKEN_SCALE();
        uint256 workingAssets = 300e6;

        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(workingAssets);

        // Vault captures the reported total in totalAssets()
        vm.assertEq(_vault.totalAssets(), workingAssets + 500e6 + expectedScaledYield);
    }

    function test_settleEpoch_revertsIfNoEpochClosed() public {
        vm.prank(FUND_OPERATOR);
        vm.expectRevert(IFundManager.SETTLEMENT_PRECONDITIONS_NOT_MET.selector);
        _fundManager.settleEpoch();
    }

    function test_settleEpoch_grantsUnitsToFundManager_andRecalibratesFlow() public {
        _seedYieldBuffer();
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);

        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);

        ISuperfluidPool pool = _fundManager.POOL();
        uint128 unitsBefore = pool.getTotalUnits();

        vm.prank(FUND_OPERATOR);
        _fundManager.settleEpoch();

        uint128 expectedAdded = uint128(DEFAULT_DEPOSIT * _fundManager.UNIT_PER_ASSET_DEPOSITED());
        vm.assertEq(pool.getTotalUnits(), unitsBefore + expectedAdded);
        vm.assertEq(pool.getUnits(address(_fundManager)), expectedAdded);
    }

    function test_canSettleEpoch_returnsFalseBeforeClose() public view {
        vm.assertFalse(_fundManager.canSettleEpoch());
    }

    function test_canSettleEpoch_returnsFalseWhenInsufficientYield() public {
        // Leave FM with 0 USDCx so the post-settle yield buffer can't be met.
        // Pass a non-zero workingAssets so vault.closeEpoch's total-assets check doesn't revert.
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(1);

        vm.assertFalse(_fundManager.canSettleEpoch());

        vm.prank(FUND_OPERATOR);
        vm.expectRevert(IFundManager.SETTLEMENT_PRECONDITIONS_NOT_MET.selector);
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

        // Drain FM's unutilized USDC so it can't cover the redeem deficit
        uint256 fmUsdc = _usdc.balanceOf(address(_fundManager));
        vm.prank(address(_fundManager));
        _usdc.transfer(address(0xdead), fmUsdc);

        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);

        vm.assertFalse(_fundManager.canSettleEpoch());
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

    function test_take_revertsIfInvariantWouldBeViolated() public {
        _seedYieldBuffer();
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        vm.prank(FUND_OPERATOR);
        _fundManager.settleEpoch();

        // Inflate pool units to push required balance above actual → invariant violated
        _inflateUnitsToBreakInvariant();

        vm.prank(FUND_OPERATOR);
        vm.expectRevert(IFundManager.INVARIANT_VIOLATED.selector);
        _fundManager.take(1);
    }

    function test_upgrade_convertsUsdcToUsdcx() public {
        _dealUSDC(address(_fundManager), DEFAULT_DEPOSIT);
        uint256 yieldBefore = _fundManager.yieldAssetsBalance();

        vm.prank(FUND_OPERATOR);
        _fundManager.upgrade(DEFAULT_DEPOSIT);

        vm.assertEq(_fundManager.yieldAssetsBalance(), yieldBefore + DEFAULT_DEPOSIT * _fundManager.SUPER_TOKEN_SCALE());
    }

    function test_downgrade_convertsUsdcxToUsdc() public {
        _seedYieldBuffer();
        uint256 unutilizedBefore = _fundManager.unutilizedAssetsBalance();
        uint256 downgradeAmount = 1 ether; // 1 USDCx

        vm.prank(FUND_OPERATOR);
        _fundManager.downgrade(downgradeAmount);

        vm.assertEq(
            _fundManager.unutilizedAssetsBalance(),
            unutilizedBefore + downgradeAmount / _fundManager.SUPER_TOKEN_SCALE()
        );
    }

    function test_downgrade_revertsIfInvariantWouldBeViolated() public {
        _seedYieldBuffer();
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        vm.prank(FUND_OPERATOR);
        _fundManager.closeEpoch(0);
        vm.prank(FUND_OPERATOR);
        _fundManager.settleEpoch();

        // Attempt to downgrade most of the yield buffer — would leave < required
        uint256 bal = _fundManager.yieldAssetsBalance();
        // Leave just 1 wei of USDCx — guaranteed to be below required
        uint256 downgradeAmount = bal - 1;

        vm.prank(FUND_OPERATOR);
        vm.expectRevert(IFundManager.INVARIANT_VIOLATED.selector);
        _fundManager.downgrade(downgradeAmount);
    }

    function test_setAnnualRate_updatesAndEmits() public {
        uint256 newRate = 2000; // 20%

        vm.expectEmit(false, false, false, true, address(_fundManager));
        emit AnnualRateChanged(INITIAL_ANNUAL_RATE, newRate);

        vm.prank(FUND_OPERATOR);
        _fundManager.setAnnualRate(newRate);

        vm.assertEq(_fundManager.annualRate(), newRate);
    }

    function test_setAnnualRate_revertsIfInvariantWouldBeViolated() public {
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
        _fundManager.setAnnualRate(INITIAL_ANNUAL_RATE * 500);
    }

    function test_setGuaranteedFlowDuration_updatesAndEmits() public {
        uint256 newDuration = 30 days;

        vm.expectEmit(false, false, false, true, address(_fundManager));
        emit GuaranteedFlowDurationChanged(GUARANTEED_FLOW_DURATION, newDuration);

        vm.prank(FUND_OPERATOR);
        _fundManager.setGuaranteedFlowDuration(newDuration);

        vm.assertEq(_fundManager.guaranteedFlowDuration(), newDuration);
    }

    function test_setGuaranteedFlowDuration_revertsBelowFloor() public {
        uint256 below = _fundManager.MIN_GUARANTEED_FLOW_DURATION() - 1;

        vm.prank(FUND_OPERATOR);
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
        vm.prank(FUND_OPERATOR);
        vm.expectRevert(IFundManager.INVARIANT_VIOLATED.selector);
        _fundManager.setGuaranteedFlowDuration(365 days * 1000);
    }

    function test_setVault_revertsOnZeroAddress() public {
        // Deploy a fresh FM to exercise setVault end-to-end
        vm.prank(DEPLOYER);
        FundManager freshFM = new FundManager(
            address(_usdc), address(_usdcx), FUND_OPERATOR, INITIAL_ANNUAL_RATE, GUARANTEED_FLOW_DURATION
        );

        vm.prank(DEPLOYER);
        vm.expectRevert(IFundManager.ZERO_ADDRESS.selector);
        freshFM.setVault(address(0));
    }

    function test_setVault_revertsWhenAlreadySet() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(IFundManager.VAULT_ALREADY_SET.selector);
        _fundManager.setVault(address(_vault));
    }

    function test_setVault_revertsOnAssetMismatch() public {
        vm.prank(DEPLOYER);
        FundManager freshFM = new FundManager(
            address(_usdc), address(_usdcx), FUND_OPERATOR, INITIAL_ANNUAL_RATE, GUARANTEED_FLOW_DURATION
        );

        // Deploy a vault whose underlying != FM's asset
        (address dai,) = _deployFreshWrapper("DAI", 18);
        StableYieldAsyncVault wrongVault = new StableYieldAsyncVault(dai, address(freshFM), "Wrong", "WRG");

        vm.prank(DEPLOYER);
        vm.expectRevert(IFundManager.ASSET_MISMATCH.selector);
        freshFM.setVault(address(wrongVault));
    }

    function test_setVault_happyPath_wiresStorageAndRole() public {
        vm.prank(DEPLOYER);
        FundManager freshFM = new FundManager(
            address(_usdc), address(_usdcx), FUND_OPERATOR, INITIAL_ANNUAL_RATE, GUARANTEED_FLOW_DURATION
        );
        StableYieldAsyncVault freshVault = new StableYieldAsyncVault(address(_usdc), address(freshFM), "Fresh", "FRSH");

        vm.prank(DEPLOYER);
        freshFM.setVault(address(freshVault));

        vm.assertEq(address(freshFM.vault()), address(freshVault));
        vm.assertTrue(freshFM.hasRole(freshFM.VAULT_ROLE(), address(freshVault)));
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

    function test_onRequestRedeem_returnsEarlyWhenNoUnits() public {
        // ALICE has zero pool units — the hook should be a no-op
        ISuperfluidPool pool = _fundManager.POOL();
        uint128 totalUnitsBefore = pool.getTotalUnits();

        vm.prank(address(_vault));
        _fundManager.onRequestRedeem(ALICE, 100, 100);

        vm.assertEq(pool.getTotalUnits(), totalUnitsBefore);
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

    function test_move_transfersToRecipient() public {
        _dealUSDC(address(_fundManager), DEFAULT_DEPOSIT);

        vm.prank(address(_vault));
        _fundManager.move(KAREN, DEFAULT_DEPOSIT);

        vm.assertEq(_usdc.balanceOf(KAREN), DEFAULT_DEPOSIT);
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

        uint256 expectedScaled = expectedBalance / _fundManager.SUPER_TOKEN_SCALE();
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

}
