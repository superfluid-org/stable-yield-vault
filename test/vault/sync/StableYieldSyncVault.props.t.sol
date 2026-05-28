// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { SyncVaultTestBase } from "./SyncVaultTestBase.t.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title StableYieldSyncVaultPropsTest
 * @notice Property / multi-user tests for the sync vault, mapped to `docs/sync-vault/invariants.md`.
 *         These assert settled invariants that hold today (the target-behaviour tests for the
 *         open-questions surfaces live in `StableYieldSyncVault.openQuestions.t.sol`). Everything is
 *         fuzzed over amounts + magnitudes; multi-holder where the invariant is about cross-holder
 *         isolation.
 */
contract StableYieldSyncVaultPropsTest is SyncVaultTestBase {

    using Math for uint256;

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

    //     ______   ___     __  __      _ __        ___                  __
    //    / ____/  <  /    / / / /___  (_) /______ /  _/___ _   ______ _/ /
    //   / /       / /    / / / / __ \/ / __/ ___/ / // __ \ | / / __ `/ /
    //  / /___    / /    / /_/ / / / / / /_(__  )_/ // / / / |/ / /_/ / /
    //  \____/   /_/     \____/_/ /_/_/\__/____//___/_/ /_/|___/\__,_/_/
    //
    // C.1 — Units track nominal contributed principal, NOT shares.
    // Under the floating share, `units / shares` is intentionally not a global constant. These
    // tests pin the four sub-properties: per-deposit grant equals `_toUnit(assets)`; per-holder
    // units == nominal-principal-contributed / RAW_PER_UNIT across deposits at different prices;
    // `units / share` differs across holders once NAV departs from `supply · RAW_PER_UNIT`;
    // transfer/withdraw move a share-proportional slice (ceil rounding, conservation on transfer).
    // See `docs/sync-vault/invariants.md §C.1` and `docs/sync-vault/design.md` Invariant 6.

    /// @dev Per-deposit hard equality: `Δunits == assets / RAW_PER_UNIT`, NAV-independent.
    function test_prop_unitGrantEqualsToUnitAssets(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        uint128 units = _fundManager.YIELD_POOL().getUnits(ALICE);
        assertEq(
            uint256(units),
            amount / _fundManager.RAW_PER_UNIT(),
            "deposit grants exactly _toUnit(assets) == assets / RAW_PER_UNIT units"
        );
    }

    /// @dev Across two deposits at different NAVs, each holder's units = their nominal contributed
    ///      principal / RAW_PER_UNIT. The grant base is the underlying deposited, not the shares
    ///      minted — so it does not move when the share price has departed from parity.
    function test_prop_unitsTrackPrincipalAcrossPrices(uint256 amountA, uint256 amountB, int256 pnl) public {
        amountA = bound(amountA, 1e6, ONE_BILLION * 1e6);
        amountB = bound(amountB, 1e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amountA);

        // External P&L between deposits so Bob enters at a different price than Alice.
        uint256 extBal = _usdc.balanceOf(address(_external));
        pnl = bound(pnl, -int256(extBal / 2), int256(extBal));
        if (pnl > 0) _external.simulateGain(uint256(pnl));
        else if (pnl < 0) _external.simulateLoss(uint256(-pnl));

        _deposit(BOB, amountB);

        uint256 rpu = _fundManager.RAW_PER_UNIT();
        uint128 unitsA = _fundManager.YIELD_POOL().getUnits(ALICE);
        uint128 unitsB = _fundManager.YIELD_POOL().getUnits(BOB);

        assertEq(uint256(unitsA), amountA / rpu, "ALICE: units == nominal contributed / RAW_PER_UNIT");
        assertEq(uint256(unitsB), amountB / rpu, "BOB: units == nominal contributed / RAW_PER_UNIT, NAV-independent");
        assertEq(
            uint256(_fundManager.YIELD_POOL().getTotalUnits()),
            (amountA + amountB) / rpu,
            "total units == sum of holders' nominal contributed principal / RAW_PER_UNIT"
        );
    }

    /// @dev Negative property: `units / share` is **not** a global constant once NAV ≠
    ///      `supply · RAW_PER_UNIT`. This is intentional under the floating share — the stream pays
    ///      the promised rate on **nominal contributed principal** (units track principal), while the
    ///      excess (`external − promised`) flows through the share price (shares track NAV).
    ///      A strict positive `gain` is the cleanest discriminator: it lifts NAV above the empty-vault
    ///      parity so Bob mints strictly fewer shares-per-underlying than Alice did (OZ floor),
    ///      while both still grant the same units-per-underlying. Cross-multiplied to avoid
    ///      quantization false-passes near the parity boundary.
    function test_prop_unitsPerShareNotGlobal(uint256 amountA, uint256 amountB, uint256 gain) public {
        amountA = bound(amountA, 1e6, ONE_BILLION * 1e6);
        amountB = bound(amountB, 1e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amountA);

        uint256 extBal = _usdc.balanceOf(address(_external));
        gain = bound(gain, 1, extBal); // strictly positive: parity case has equal ratios trivially
        _external.simulateGain(gain);

        _deposit(BOB, amountB);

        uint128 unitsA = _fundManager.YIELD_POOL().getUnits(ALICE);
        uint128 unitsB = _fundManager.YIELD_POOL().getUnits(BOB);
        uint256 sharesA = _vault.balanceOf(ALICE);
        uint256 sharesB = _vault.balanceOf(BOB);

        // If `units / share` were global, `unitsA · sharesB == unitsB · sharesA`. It is not.
        // Direction (informational): `unitsA · sharesB < unitsB · sharesA` — Bob inherits a higher
        // units/share than Alice because he entered at a higher price-per-share (more units per
        // share-slot for the same dollar in).
        assertNotEq(
            uint256(unitsA) * sharesB,
            uint256(unitsB) * sharesA,
            "units/share is not a global constant under the floating share (intentional, C.1)"
        );
    }

    /// @dev Total units conserved on a shareholder↔shareholder transfer; sender's decrease equals
    ///      receiver's increase equals `ceil(senderUnits · shares / vault.balanceOf(sender))` —
    ///      exactly the `onShareTransfer` formula, evaluated against the **pre-transfer** balance
    ///      (the vault's `_update` override calls the FM hook before `super._update`).
    function test_prop_transferConservesUnits(uint256 amount, uint256 transferPortion) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        uint256 sharesBefore = _vault.balanceOf(ALICE);
        uint128 unitsBefore = _fundManager.YIELD_POOL().getUnits(ALICE);
        uint128 totalUnitsBefore = _fundManager.YIELD_POOL().getTotalUnits();

        uint256 toTransfer = bound(transferPortion, 1, sharesBefore);

        vm.prank(ALICE);
        _vault.transfer(BOB, toTransfer);

        uint128 unitsAliceAfter = _fundManager.YIELD_POOL().getUnits(ALICE);
        uint128 unitsBobAfter = _fundManager.YIELD_POOL().getUnits(BOB);
        uint128 totalUnitsAfter = _fundManager.YIELD_POOL().getTotalUnits();

        uint128 expectedDelta = uint128(uint256(unitsBefore).mulDiv(toTransfer, sharesBefore, Math.Rounding.Ceil));

        assertEq(totalUnitsAfter, totalUnitsBefore, "transfer conserves total units");
        assertEq(
            uint256(unitsBefore - unitsAliceAfter),
            uint256(expectedDelta),
            "sender units decrease by ceil(senderUnits * shares / senderShares)"
        );
        assertEq(
            uint256(unitsBobAfter),
            uint256(expectedDelta),
            "receiver units increase by the same delta (BOB had zero units before)"
        );
    }

    /// @dev D.4 (weakened 2026-05-28): when the external vault won't accept the post-payout trim
    ///      (`maxDeposit(FM) == 0`), `_rebalanceYieldAssets()` skips the `deficit < 0` branch and
    ///      leaves the freed excess as above-target super-token slack in the reserve. The
    ///      load-bearing property is that this slack must NOT block subsequent ops and must NOT
    ///      violate Inv. 7 / A.2 (no raw underlying at rest). We exercise: two withdraws at
    ///      `maxDeposit == 0`, then reopening deposits + an operator rebalance — none should
    ///      revert, all should preserve `balanceOf(FM)_underlying == 0`, and the second withdraw
    ///      must pay exact. The trim's effect on the deficit value itself is subtler (sub-
    ///      `SCALING_FACTOR` super-token wei + Superfluid GDA buffer accounting) and not pinned
    ///      here — see `test_withdraw_notBrickedByRedepositCap` for the single-op variant.
    function test_prop_aboveTargetReserveDoesNotBlockWithdraw(uint256 amount, uint256 wPortion1, uint256 wPortion2)
        public
    {
        amount = bound(amount, 10e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        // Close external deposits. First withdraw should leave above-target slack but not revert.
        _external.setDepositCap(0);

        uint256 wAssets1 = bound(wPortion1, 1e6, _vault.maxWithdraw(ALICE) / 2);
        uint256 balBefore1 = _usdc.balanceOf(ALICE);
        vm.prank(ALICE);
        _vault.withdraw(wAssets1, ALICE, ALICE);
        assertEq(_usdc.balanceOf(ALICE) - balBefore1, wAssets1, "first withdraw pays exact under maxDeposit==0");
        assertEq(_usdc.balanceOf(address(_fundManager)), 0, "Inv. 7 after first withdraw");

        // A second withdraw at the same closed-deposits state must still pay exact.
        uint256 remainingMax = _vault.maxWithdraw(ALICE);
        if (remainingMax > 0) {
            uint256 wAssets2 = bound(wPortion2, 1, remainingMax);
            uint256 balBefore2 = _usdc.balanceOf(ALICE);
            vm.prank(ALICE);
            _vault.withdraw(wAssets2, ALICE, ALICE);
            assertEq(_usdc.balanceOf(ALICE) - balBefore2, wAssets2, "second withdraw pays exact under maxDeposit==0");
            assertEq(_usdc.balanceOf(address(_fundManager)), 0, "Inv. 7 after second withdraw");
        }

        // Reopening external deposits + operator rebalance must not revert.
        _external.setDepositCap(type(uint256).max);
        vm.prank(FUND_OPERATOR);
        _fundManager.ensureYieldFlowDuration();
        assertEq(_usdc.balanceOf(address(_fundManager)), 0, "Inv. 7 after operator rebalance");
    }

    /// @dev Withdraw decreases the holder's units by `ceil(holderUnits · shares / totalSharesOwned)`.
    ///      The `onWithdraw` shortcut `shares == totalSharesOwned ⇒ delta = holderUnits` is exactly
    ///      what the mulDiv-Ceil formula yields in that case, so a single assertion covers both
    ///      branches (full and partial exits).
    function test_prop_withdrawDecreasesUnitsProportional(uint256 amount, uint256 wPortion) public {
        amount = bound(amount, 2e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        uint256 sharesBefore = _vault.balanceOf(ALICE);
        uint128 unitsBefore = _fundManager.YIELD_POOL().getUnits(ALICE);

        uint256 maxS = _vault.maxRedeem(ALICE);
        if (maxS == 0) return;
        uint256 wShares = bound(wPortion, 1, maxS);

        vm.prank(ALICE);
        _vault.redeem(wShares, ALICE, ALICE);

        uint128 unitsAfter = _fundManager.YIELD_POOL().getUnits(ALICE);
        uint128 expectedDelta = uint128(uint256(unitsBefore).mulDiv(wShares, sharesBefore, Math.Rounding.Ceil));

        assertEq(
            uint256(unitsBefore - unitsAfter),
            uint256(expectedDelta),
            "withdraw decreases units by ceil(holderUnits * shares / totalSharesOwned)"
        );
    }

}
