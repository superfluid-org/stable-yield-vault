// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { SyncVaultTestBase } from "./SyncVaultTestBase.t.sol";

/**
 * @title StableYieldSyncVaultPropsTest
 * @notice Property / multi-user tests for the sync vault, mapped to `docs/sync-vault/invariants.md`.
 *         These assert settled invariants that hold today (the target-behaviour tests for the
 *         open-questions surfaces live in `StableYieldSyncVault.openQuestions.t.sol`). Everything is
 *         fuzzed over amounts + magnitudes; multi-holder where the invariant is about cross-holder
 *         isolation.
 */
contract StableYieldSyncVaultPropsTest is SyncVaultTestBase {

    /// @dev Few-bp tolerance for the GDA deposit-buffer lockup / recalibrate tick (see vault suite).
    uint256 internal constant NAV_REL_TOL = 0.001e18; // 0.1%

    //     ____     ___      ____     _   _____ _    __   ___                            __  _
    //    / __ )   |__ \    / __ \   / | / / __ \ |  / /  / _ \_   _____  _____   _____________  / / / /__
    //   / __  |   __/ /   / / / /  /  |/ / / / / | / /  / // / | / / _ \/ ___/  / ___/ ___/ / / / / / _ \
    //  / /_/ /   / __/   / /_/ /  / /|  / /_/ /| |/ /  / // /| |/ /  __/ /     (__  |__  ) /_/ / /_/  __/
    // /_____/   /____/   \____/  /_/ |_/\____/ |___/   \___/ |___/\___/_/     /____/____/\__,_/\__/\___/

    /// @dev B.2 — no share over-issuance: the total claim priced at NAV never exceeds the
    ///      recoverable value, across deposits, a withdraw, and external gain/loss.
    function test_prop_noOverIssuance(uint256 amountA, uint256 amountB, int256 pnl, uint256 wPortion) public {
        amountA = bound(amountA, 1e6, ONE_BILLION * 1e6);
        amountB = bound(amountB, 1e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amountA);
        _deposit(BOB, amountB);

        // Apply external P&L (gain or loss) within the external position's bounds.
        uint256 extBal = _usdc.balanceOf(address(_external));
        pnl = bound(pnl, -int256(extBal / 2), int256(extBal));
        if (pnl > 0) _external.simulateGain(uint256(pnl));
        else if (pnl < 0) _external.simulateLoss(uint256(-pnl));

        // BOB exits a fuzzed portion.
        uint256 wAssets = bound(wPortion, 0, _vault.maxWithdraw(BOB));
        if (wAssets > 0) {
            vm.prank(BOB);
            _vault.withdraw(wAssets, BOB, BOB);
        }

        // B.2: convertToAssets(totalSupply) <= totalManagedAssets() (strict-≤ with virtual shares).
        assertLe(
            _vault.convertToAssets(_vault.totalSupply()),
            _fundManager.totalManagedAssets(),
            "no over-issuance: total claim <= recoverable"
        );
    }

    //     ____     __ __      _____ __                                          __        ___ __      __         __
    //    / __ )   / // /     / ___// /_____ ___  _____  __________   ____  ____  / /_   ____/ (_) /_  __/ /____  ____/
    // /
    //   / __  |  / // /_     \__ \/ __/ __ `/ / / / _ \/ ___/ ___/  / __ \/ __ \/ __/  / __  / / / / / / __/ _ \/ __  /
    //  / /_/ /  /__  __/    ___/ / /_/ /_/ / /_/ /  __/ /  (__  )  / / / / /_/ / /_   / /_/ / / / /_/ / /_/  __/ /_/ /
    // /_____/     /_/      /____/\__/\__,_/\__, /\___/_/  /____/  /_/ /_/\____/\__/   \__,_/_/\__/\__/\__/\___/\__,_/
    //                                     /____/

    /// @dev B.4 — a stayer is not diluted by another holder's deposit+withdraw, holding external
    ///      NAV and the reserve fixed (no warp, no external P&L). ALICE's redeemable value must not
    ///      fall (beyond the few-bp recalibrate tick) when BOB churns.
    function test_prop_stayerNotDiluted(uint256 amountA, uint256 amountB, uint256 wPortion) public {
        amountA = bound(amountA, 1e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amountA);
        uint256 valA0 = _vault.convertToAssets(_vault.balanceOf(ALICE));

        amountB = bound(amountB, 1e6, ONE_BILLION * 1e6);
        _deposit(BOB, amountB);
        uint256 wAssets = bound(wPortion, 0, _vault.maxWithdraw(BOB));
        if (wAssets > 0) {
            vm.prank(BOB);
            _vault.withdraw(wAssets, BOB, BOB);
        }

        // ALICE's value must not have dropped below valA0 (modulo the few-bp buffer tick). Floor
        // pricing of BOB's exit, if anything, leaves residual value with ALICE.
        uint256 valA1 = _vault.convertToAssets(_vault.balanceOf(ALICE));
        uint256 floorVal = valA0 - (valA0 * NAV_REL_TOL / 1e18);
        assertGe(valA1, floorVal, "stayer not diluted by another holder's churn");
    }

    //     ____      ____      _       ___ __  __    __                                                __
    //    / __ )    / __/     | |     / (_) /_/ /_  / /_______ __      __   ____  ____ ___  _______   / /
    //   / __  |   / /_       | | /| / / / __/ __ \/ / / ___/ __ \ |/| / /  / __ \/ __ `/ / / / ___/  / /
    //  / /_/ /   / __/       | |/ |/ / / /_/ / / / / / /  / /_/ / /| / /  / /_/ / /_/ / /_/ (__  )  /_/
    // /_____/   /_/          |__/|__/_/\__/_/ /_/_/_/_/   \__,_/_/ |_/  / .___/\__,_/\__, /____/  (_)
    //                                                                  /_/         /____/

    /// @dev B.6 — a withdrawal pays the receiver exactly the requested underlying, including from
    ///      an off-par (gained/impaired) state where the reserve + external legs split the payout.
    function test_prop_withdrawPaysExact(uint256 amount, int256 pnl, uint256 wPortion) public {
        amount = bound(amount, 2e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        uint256 extBal = _usdc.balanceOf(address(_external));
        pnl = bound(pnl, -int256(extBal / 2), int256(extBal));
        if (pnl > 0) _external.simulateGain(uint256(pnl));
        else if (pnl < 0) _external.simulateLoss(uint256(-pnl));

        uint256 wAssets = bound(wPortion, 1, _vault.maxWithdraw(ALICE));
        uint256 balBefore = _usdc.balanceOf(BOB); // pay to a fresh receiver

        vm.prank(ALICE);
        _vault.withdraw(wAssets, BOB, ALICE);

        assertEq(_usdc.balanceOf(BOB) - balBefore, wAssets, "receiver got exactly the requested assets");
    }

}
