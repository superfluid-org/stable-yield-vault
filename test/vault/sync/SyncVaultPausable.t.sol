// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { SyncVaultTestBase } from "./SyncVaultTestBase.t.sol";

import { IStableYieldSyncVault } from "src/interfaces/vault/sync/IStableYieldSyncVault.sol";

/**
 * @title SyncVaultPausableTest
 * @notice Admin-gated lifecycle of the sync vault: the reversible `paused` toggle (blocks both
 *         deposit and withdraw legs) and the one-way `terminate()` latch (permanently closes the
 *         deposit leg while leaving withdrawals open). State + setters live on the vault and are
 *         authorized against the FundManager's DEFAULT_ADMIN_ROLE; enforced via
 *         {whenDepositable}/{whenNotPaused} (precise revert) and by zeroing `max*` (ERC-4626 view
 *         honesty).
 */
contract SyncVaultPausableTest is SyncVaultTestBase {

    event PauseStatusChanged(bool paused);
    event Terminated();

    uint256 internal constant DEPOSIT = 1000 * 1e6; // 1000 USDC

    function _pause(bool p) internal {
        vm.prank(FUND_ADMIN);
        _vault.setPaused(p);
    }

    function _terminate() internal {
        vm.prank(FUND_ADMIN);
        _vault.terminate();
    }

    //      ___                                                  __             __
    //     /   | _____________  __________   _________  ____  / /__________  / /
    //    / /| |/ ___/ ___/ _ \/ ___/ ___/  / ___/ __ \/ __ \/ __/ ___/ __ \/ /
    //   / ___ / /__/ /__/  __(__  |__  )  / /__/ /_/ / / / / /_/ /  / /_/ / /
    //  /_/  |_\___/\___/\___/____/____/   \___/\____/_/ /_/\__/_/   \____/_/

    function test_setPaused_onlyAdmin() public {
        vm.expectRevert(IStableYieldSyncVault.NOT_ADMIN.selector);
        vm.prank(ALICE);
        _vault.setPaused(true);
    }

    function test_terminate_onlyAdmin() public {
        vm.expectRevert(IStableYieldSyncVault.NOT_ADMIN.selector);
        vm.prank(ALICE);
        _vault.terminate();
    }

    //      _____ __        __
    //     / ___// /_____ _/ /____
    //     \__ \/ __/ __ `/ __/ _ \
    //    ___/ / /_/ /_/ / /_/  __/
    //   /____/\__/\__,_/\__/\___/

    function test_initialState_active() public view {
        assertFalse(_vault.paused(), "not paused at deploy");
        assertFalse(_vault.terminated(), "not terminated at deploy");
    }

    function test_setPaused_togglesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(_vault));
        emit PauseStatusChanged(true);
        _pause(true);
        assertTrue(_vault.paused(), "paused set");

        vm.expectEmit(false, false, false, true, address(_vault));
        emit PauseStatusChanged(false);
        _pause(false);
        assertFalse(_vault.paused(), "unpaused");
    }

    function test_terminate_setsAndEmits() public {
        vm.expectEmit(false, false, false, false, address(_vault));
        emit Terminated();
        _terminate();
        assertTrue(_vault.terminated(), "terminated set");
    }

    function test_setPaused_redundantIsNoOpNoEvent() public {
        _pause(true);
        vm.recordLogs();
        _pause(true); // redundant — must not emit a second PauseStatusChanged
        assertEq(vm.getRecordedLogs().length, 0, "no event on redundant pause");
        assertTrue(_vault.paused(), "still paused");
    }

    function test_terminate_redundantIsNoOpNoEvent() public {
        _terminate();
        vm.recordLogs();
        _terminate(); // redundant — must not emit a second Terminated
        assertEq(vm.getRecordedLogs().length, 0, "no event on redundant terminate");
        assertTrue(_vault.terminated(), "still terminated");
    }

    function test_terminate_isOneWayLatch() public {
        _terminate();
        // No un-terminate exists; pausing/unpausing must not clear the latch.
        _pause(true);
        _pause(false);
        assertTrue(_vault.terminated(), "still terminated");
    }

    //      ____                            __
    //     / __ \____ ___  __________  ____/ /
    //    / /_/ / __ `/ / / / ___/ _ \/ __  /
    //   / ____/ /_/ / /_/ (__  )  __/ /_/ /
    //  /_/    \__,_/\__,_/____/\___/\__,_/

    function test_paused_blocksDeposit() public {
        _pause(true);
        uint256 gross = DEPOSIT + _vault.DEPOSIT_FEE();
        _fund(ALICE, gross);
        vm.expectRevert(IStableYieldSyncVault.VAULT_PAUSED.selector);
        vm.prank(ALICE);
        _vault.deposit(gross, ALICE);
    }

    function test_paused_blocksMint() public {
        _pause(true);
        _fund(ALICE, DEPOSIT * 2);
        vm.expectRevert(IStableYieldSyncVault.VAULT_PAUSED.selector);
        vm.prank(ALICE);
        _vault.mint(1e18, ALICE);
    }

    function test_paused_blocksWithdrawAndRedeem() public {
        uint256 shares = _deposit(ALICE, DEPOSIT);
        _pause(true);

        vm.expectRevert(IStableYieldSyncVault.VAULT_PAUSED.selector);
        vm.prank(ALICE);
        _vault.redeem(shares, ALICE, ALICE);

        vm.expectRevert(IStableYieldSyncVault.VAULT_PAUSED.selector);
        vm.prank(ALICE);
        _vault.withdraw(1e6, ALICE, ALICE);
    }

    function test_paused_zeroesAllMax() public {
        _deposit(ALICE, DEPOSIT);
        _pause(true);
        assertEq(_vault.maxDeposit(ALICE), 0, "maxDeposit");
        assertEq(_vault.maxMint(ALICE), 0, "maxMint");
        assertEq(_vault.maxWithdraw(ALICE), 0, "maxWithdraw");
        assertEq(_vault.maxRedeem(ALICE), 0, "maxRedeem");
    }

    function test_unpause_restoresBothLegs() public {
        uint256 shares = _deposit(ALICE, DEPOSIT);
        _pause(true);
        _pause(false);

        // Deposit works again.
        assertGt(_vault.maxDeposit(ALICE), 0, "maxDeposit restored");
        _deposit(BOB, DEPOSIT);

        // Withdraw works again.
        assertGt(_vault.maxRedeem(ALICE), 0, "maxRedeem restored");
        vm.prank(ALICE);
        _vault.redeem(shares, ALICE, ALICE);
    }

    //      ______                      _             __
    //     /_  __/__  _________ ___    (_)___  ____ _/ /____  ____/
    //      / / / _ \/ ___/ __ `__ \  / / __ \/ __ `/ __/ _ \/ __  /
    //     / / /  __/ /  / / / / / / / / / / / /_/ / /_/  __/ /_/ /
    //    /_/  \___/_/  /_/ /_/ /_/_/ /_/_/ /_/\__,_/\__/\___/\__,_/

    function test_terminated_blocksDepositAndMint() public {
        _terminate();
        uint256 gross = DEPOSIT + _vault.DEPOSIT_FEE();
        _fund(ALICE, gross * 2);

        vm.expectRevert(IStableYieldSyncVault.VAULT_TERMINATED.selector);
        vm.prank(ALICE);
        _vault.deposit(gross, ALICE);

        vm.expectRevert(IStableYieldSyncVault.VAULT_TERMINATED.selector);
        vm.prank(ALICE);
        _vault.mint(1e18, ALICE);
    }

    function test_terminated_allowsWithdraw() public {
        _deposit(ALICE, DEPOSIT);
        _terminate();

        // Deposit leg is shut...
        assertEq(_vault.maxDeposit(ALICE), 0, "maxDeposit zeroed");
        assertEq(_vault.maxMint(ALICE), 0, "maxMint zeroed");
        // ...but holders can still exit (redeem up to the reserve-inclusive NAV cap).
        uint256 redeemable = _vault.maxRedeem(ALICE);
        assertGt(redeemable, 0, "maxRedeem open");
        assertGt(_vault.maxWithdraw(ALICE), 0, "maxWithdraw open");

        uint256 before = _usdc.balanceOf(ALICE);
        vm.prank(ALICE);
        _vault.redeem(redeemable, ALICE, ALICE);
        assertGt(_usdc.balanceOf(ALICE), before, "alice received underlying");
    }

    function test_terminatedThenPaused_blocksWithdrawToo() public {
        uint256 shares = _deposit(ALICE, DEPOSIT);
        _terminate();
        _pause(true);

        // Pause (an emergency lever on top of termination) takes precedence: withdraw is blocked,
        // and the deposit-side revert surfaces the pause first.
        vm.expectRevert(IStableYieldSyncVault.VAULT_PAUSED.selector);
        vm.prank(ALICE);
        _vault.redeem(shares, ALICE, ALICE);

        // Unpausing while still terminated re-opens withdrawals only.
        _pause(false);
        assertEq(_vault.maxDeposit(ALICE), 0, "deposit still shut");
        uint256 redeemable = _vault.maxRedeem(ALICE);
        assertGt(redeemable, 0, "withdraw re-opened");
        vm.prank(ALICE);
        _vault.redeem(redeemable, ALICE, ALICE);
        assertLt(_vault.balanceOf(ALICE), shares, "alice exited after unpause");
    }

}
