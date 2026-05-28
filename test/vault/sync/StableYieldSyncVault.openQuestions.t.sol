// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { SyncVaultTestBase } from "./SyncVaultTestBase.t.sol";

/**
 * @title StableYieldSyncVaultOpenQuestionsTest
 * @notice TARGET-BEHAVIOUR tests for the unresolved surfaces in `docs/sync-vault/open-questions.md`.
 *
 *         ⚠️  THESE TESTS ARE EXPECTED TO FAIL on the current code. Each one encodes the behaviour
 *         the design *claims* (or wants) but the code does not yet enforce. A failure here is the
 *         signal that the corresponding open question is still open — NOT a broken test. When the
 *         code fix lands, the matching test should flip to green; until then it pins the gap.
 *
 *         Mapping to open-questions.md:
 *           - test_maxRedeem_neverBricks            → [VERIFY] "maxRedeem / maxWithdraw never-bricking"
 *           - test_withdraw_notBrickedByRedeposit   → [VERIFY] "Withdraw bricked by redeposit revert"
 *
 *         RESOLVED & moved out:
 *           - test_firstDepositInflation_victimMintsNonZero (→ StableYieldSyncVault.t.sol; the
 *             `_decimalsOffset() == 12` mitigation landed 2026-05-27).
 *           - The per-op/setter `_recalibrateFlow()` concern was resolved 2026-05-27 by treating
 *             terminal external impairment as a FULL PAUSE (`maxWithdraw(FM) == 0 ⇒ all max* = 0`)
 *             rather than by guarding the recalibrate: the hooks never run while paused, so there is
 *             nothing to brick. See the `test_terminalImpairment_*` tests in StableYieldSyncVault.t.sol.
 */
contract StableYieldSyncVaultOpenQuestionsTest is SyncVaultTestBase {

    uint256 internal constant DEFAULT_DEPOSIT = 1000 * 1e6;

    /// @dev [VERIFY] maxRedeem/maxWithdraw genuinely never-bricking. FAILS today: `maxRedeem` caps
    ///      by `totalManagedAssets()` which counts the FULL reserve, but `onWithdraw` can only
    ///      source the reserve's *freed-excess* slice (proportional to the units it removes). With
    ///      the external position impaired and the reserve large, a `redeem(s ≤ maxRedeem)` tries to
    ///      pull more from the external vault than its liquidity cap allows and reverts
    ///      (`ERC4626ExceededMaxWithdraw` from the external vault) — so the bound over-promises.
    function test_maxRedeem_neverBricks(uint256 amount, uint256 capPortion, uint256 sPortion) public {
        amount = bound(amount, 2e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        uint256 ta = _fundManager.totalManagedAssets();
        uint256 cap = bound(capPortion, 1e6, ta);
        _external.setLiquidityCap(cap);

        uint256 maxS = _vault.maxRedeem(ALICE);
        if (maxS == 0) return;
        uint256 s = bound(sPortion, 1, maxS);

        uint256 expected = _vault.previewRedeem(s);
        vm.prank(ALICE);
        uint256 assets = _vault.redeem(s, ALICE, ALICE);
        assertEq(assets, expected, "redeem(s<=maxRedeem) pays previewRedeem(s) and never bricks");
    }

    /// @dev [VERIFY] Withdraw bricked by the external vault rejecting the post-payout redeposit.
    ///      FAILS today: `onWithdraw`'s rebalance (`deficit < 0` branch) redeposits the freed reserve
    ///      excess into `EXTERNAL_VAULT.deposit`. If the external vault is paused-for-deposits but
    ///      still allows withdrawals, that redeposit reverts and bricks an otherwise-valid exit.
    ///      Target: a withdraw within liquidity succeeds regardless of the external deposit being
    ///      paused (the redeposit trim should be best-effort).
    function test_withdraw_notBrickedByRedepositRevert(uint256 amount, uint256 wPortion) public {
        amount = bound(amount, 2e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        // External vault: deposits paused, withdrawals still serviced.
        _external.setDepositReverts(true);

        uint256 wAssets = bound(wPortion, 1e6, _vault.maxWithdraw(ALICE));
        vm.prank(ALICE);
        _vault.withdraw(wAssets, ALICE, ALICE);

        assertEq(_usdc.balanceOf(ALICE), wAssets, "withdraw not bricked by paused external deposits");
    }

}
