// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { StableYieldVaultTestBase } from "./StableYieldVaultTestBase.t.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { FundManager } from "src/FundManager.sol";

contract FundManagerTest is StableYieldVaultTestBase {

    function setUp() public override {
        super.setUp();
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
        amount = bound(amount, 1, 100e9 * 1e6); // Bound the amount to a reasonable range

        // Note: `take` function has a pre-requisite check for sufficient unutilized assets balance, so we need to
        // ensure that the test doesn't fail due to that. We can do this by minting some assets to the FundManager
        // before calling `take`.
        _dealUSDC(address(_fundManager), amount);

        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.take(amount);
    }

    function test_upgrade_accessControl(address nonFundOperator, uint256 amount) public {
        vm.assume(_fundManager.hasRole(_fundManager.FUND_OPERATOR_ROLE(), nonFundOperator) == false);
        amount = bound(amount, 1, 100e9 * 1e6); // Bound the amount to a reasonable range

        _dealUSDC(address(_fundManager), amount);

        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.upgrade(amount);
    }

    function test_downgrade_accessControl(address nonFundOperator, uint256 amount) public {
        vm.assume(_fundManager.hasRole(_fundManager.FUND_OPERATOR_ROLE(), nonFundOperator) == false);
        amount = bound(amount, 1, 100e9 ether); // Bound the amount to a reasonable range

        // Note: `take` function has a pre-requisite check for sufficient unutilized assets balance, so we need to
        // ensure that the test doesn't fail due to that. We can do this by minting some assets to the FundManager
        // before calling `take`.
        _dealUSDCx(address(_fundManager), amount);

        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.downgrade(amount);
    }

    function test_setGuaranteedFlowDuration_accessControl(address nonFundOperator, uint256 newDuration) public {
        vm.assume(_fundManager.hasRole(_fundManager.FUND_OPERATOR_ROLE(), nonFundOperator) == false);
        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.setGuaranteedFlowDuration(newDuration);
    }

    function test_setVault_accessControl(address nonFundOperator, address newVault) public {
        vm.assume(_fundManager.hasRole(_fundManager.FUND_OPERATOR_ROLE(), nonFundOperator) == false);
        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.setVault(newVault);
    }

    function test_onRequestRedeem_accessControl(address nonFundOperator, address redeemer, uint256 shareAmount)
        public
    {
        vm.assume(_fundManager.hasRole(_fundManager.VAULT_ROLE(), nonFundOperator) == false);

        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.onRequestRedeem(redeemer, shareAmount, shareAmount);
    }

    function test_onClaimDeposit_accessControl(address nonFundOperator, address depositor, uint256 depositAmount)
        public
    {
        vm.assume(_fundManager.hasRole(_fundManager.VAULT_ROLE(), nonFundOperator) == false);

        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.onClaimDeposit(depositor, depositAmount);
    }

    function test_move_accessControl(address nonFundOperator, address recipient, uint256 amount) public {
        vm.assume(_fundManager.hasRole(_fundManager.VAULT_ROLE(), nonFundOperator) == false);

        vm.prank(nonFundOperator);
        vm.expectRevert();

        _fundManager.move(recipient, amount);
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

        uint256 expectedScaledBalance = expectedBalance / _fundManager.SUPER_TOKEN_SCALE();
        vm.assertEq(_fundManager.scaledYieldAssetsBalance(), expectedScaledBalance);
    }

}
