// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { SyncVaultTestBase } from "./SyncVaultTestBase.t.sol";

import { IStableYieldSyncVault } from "src/interfaces/vault/sync/IStableYieldSyncVault.sol";

/**
 * @title SyncVaultTerminableTest
 * @notice Admin-gated lifecycle of the sync vault: the one-way `terminate()` latch permanently
 *         closes the deposit leg while leaving withdrawals open (holders can always exit). There is
 *         no admin pause — the withdraw leg is only ever gated by the external pause. State + setter
 *         live on the vault and are authorized against the FundManager's DEFAULT_ADMIN_ROLE;
 *         enforced via {whenDepositable} (precise revert) and by zeroing the deposit-side `max*`.
 */
contract SyncVaultTerminableTest is SyncVaultTestBase {

    event Terminated();

    uint256 internal constant DEPOSIT = 1000 * 1e6; // 1000 USDC

    function _terminate() internal {
        vm.prank(FUND_ADMIN);
        _vault.terminate();
    }

    //      ___                                                  __             __
    //     /   | _____________  __________   _________  ____  / /__________  / /
    //    / /| |/ ___/ ___/ _ \/ ___/ ___/  / ___/ __ \/ __ \/ __/ ___/ __ \/ /
    //   / ___ / /__/ /__/  __(__  |__  )  / /__/ /_/ / / / / /_/ /  / /_/ / /
    //  /_/  |_\___/\___/\___/____/____/   \___/\____/_/ /_/\__/_/   \____/_/

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
        assertFalse(_vault.terminated(), "not terminated at deploy");
    }

    function test_terminate_setsAndEmits() public {
        vm.expectEmit(false, false, false, false, address(_vault));
        emit Terminated();
        _terminate();
        assertTrue(_vault.terminated(), "terminated set");
    }

    function test_terminate_redundantIsNoOpNoEvent() public {
        _terminate();
        vm.recordLogs();
        _terminate(); // redundant — must not emit a second Terminated
        assertEq(vm.getRecordedLogs().length, 0, "no event on redundant terminate");
        assertTrue(_vault.terminated(), "still terminated");
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

    function test_terminated_zeroesDepositMax() public {
        _deposit(ALICE, DEPOSIT);
        _terminate();
        assertEq(_vault.maxDeposit(ALICE), 0, "maxDeposit zeroed");
        assertEq(_vault.maxMint(ALICE), 0, "maxMint zeroed");
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

}
