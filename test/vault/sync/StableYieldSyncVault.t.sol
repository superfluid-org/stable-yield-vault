// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { SyncVaultTestBase } from "./SyncVaultTestBase.t.sol";
import { MockERC4626 } from "test/mocks/MockERC4626.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";
import { IFundManagerBase } from "src/interfaces/common/IFundManagerBase.sol";

import { IStableYieldSyncVault } from "src/interfaces/vault/sync/IStableYieldSyncVault.sol";
import { ISyncFundManager } from "src/interfaces/vault/sync/ISyncFundManager.sol";
import { StableYieldSyncVault } from "src/vault/sync/StableYieldSyncVault.sol";

/**
 * @title StableYieldSyncVaultTest
 * @notice Sync-vault suite for the floating-share model (revision 2026-05-26): FM is sole
 *         custodian, stream pre-funded from each deposit (no `_seedReserve` needed for the
 *         baseline), reserve-inclusive NAV with NO clamp — `totalAssets` is the plain sum of the
 *         FM's recoverable balances, so the external surplus accrues to holders as share
 *         appreciation and losses reflect immediately. Withdraw pays the reserve slice from the
 *         recalibration-freed excess; exits are OZ pro-rata. See `docs/sync-vault/design.md`.
 */
contract StableYieldSyncVaultTest is SyncVaultTestBase {

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    uint256 internal constant DEFAULT_DEPOSIT = 1000 * 1e6; // 1000 USDC

    /// @dev Relative tolerance for share-price drift caused by the GDA "deposit buffer"
    ///      lockup (returned on flow termination) and decimals-clipping in `_upgrade(+1)`.
    ///      Bounded by `flowRate * liquidationPeriod / scaledPrincipal` ≈ a few bp at our
    ///      10% APR / 7-day-horizon test sizes; 0.1% is comfortably above.
    uint256 internal constant NAV_REL_TOL = 0.001e18; // 0.1%

    //    ______                 __                  __
    //   / ____/___  ____  _____/ /________  _______/ /_____  _____
    //  / /   / __ \/ __ \/ ___/ __/ ___/ / / / ___/ __/ __ \/ ___/
    // / /___/ /_/ / / / (__  ) /_/ /  / /_/ / /__/ /_/ /_/ / /
    // \____/\____/_/ /_/____/\__/_/   \__,_/\___/\__/\____/_/

    function test_constructor_initialState() public view {
        assertEq(_vault.asset(), address(_usdc), "asset");
        assertEq(address(_vault.FUND_MANAGER()), address(_fundManager), "fund manager");
        assertEq(_vault.totalAssets(), 0, "totalAssets starts at 0");
        // FM pinned to the vault + holds custody role.
        assertEq(address(_fundManager.VAULT()), address(_vault), "FM.VAULT pinned");
        assertTrue(_fundManager.hasRole(_fundManager.VAULT_ROLE(), address(_vault)), "VAULT_ROLE");
        assertTrue(_fundManager.hasRole(_fundManager.FUND_OPERATOR_ROLE(), FUND_OPERATOR), "operator role");
        // FM is the sole custodian; the vault holds no assets at rest.
        assertEq(_usdc.balanceOf(address(_vault)), 0, "vault holds no underlying");
        assertEq(_external.balanceOf(address(_vault)), 0, "vault holds no external shares");
        assertEq(address(_fundManager.EXTERNAL_VAULT()), address(_external), "FM owns EXTERNAL_VAULT");
    }

    function test_constructor_revertsOnExternalAssetMismatch() public {
        // External vault over a *different* asset.
        MockERC4626 wrongExternal = new MockERC4626(IERC20(address(_usdcx)), "Wrong", "WRG");

        vm.expectRevert(IStableYieldSyncVault.EXTERNAL_ASSET_MISMATCH.selector);
        new StableYieldSyncVault(
            TREASURY,
            address(_usdc),
            address(_usdcx),
            address(wrongExternal),
            FUND_OPERATOR,
            FUND_ADMIN,
            INITIAL_ERA_STABLE_YIELD_RATE,
            GUARANTEED_FLOW_DURATION,
            "x",
            "x"
        );
    }

    //     __  __      _ __     ____                        _ __
    //    / / / /___  (_) /_   / __ \___  ____  ____  _____(_) /______
    //   / / / / __ \/ / __/  / / / / _ \/ __ \/ __ \/ ___/ / __/ ___/
    //  / /_/ / / / / / /_   / /_/ /  __/ /_/ / /_/ (__  ) / /_(__  )
    //  \____/_/ /_/_/\__/  /_____/\___/ .___/\____/____/_/\__/____/
    //                                /_/

    /// @dev The deposit splits `assets` into the external slice (most of it) and the pre-fund
    ///      reserve slice (a few-bp tail). The first deposit mints `assets * 10**offset` shares
    ///      (offset 12 → 18-dec shares); `totalAssets` is NAV-neutral (~ assets, a hair below par
    ///      by the GDA deposit-buffer lockup — no clamp).
    function test_deposit_mintsSharesNavNeutral(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);

        uint256 shares = _deposit(ALICE, amount);

        // First deposit on an empty vault: shares == assets * 10**_decimalsOffset() (offset 12).
        assertEq(shares, amount * 1e12, "first deposit mints assets * 10**offset shares");
        assertEq(_vault.balanceOf(ALICE), amount * 1e12, "share balance");
        // NAV-neutral: total managed assets ~ amount, off only by the GDA deposit-buffer slice
        // locked inside the agreement at distributeFlow time (no clamp — just the lockup gap).
        assertApproxEqRel(_vault.totalAssets(), amount, NAV_REL_TOL, "totalAssets ~ deposit (NAV-neutral)");
        assertLe(_vault.totalAssets(), amount, "GDA deposit-buffer lockup keeps NAV a hair below par");
        // The pre-fund carved a slice into the reserve; the rest went to the external vault.
        assertLt(_usdc.balanceOf(address(_external)), amount, "external holds deposit minus pre-fund");
        assertGt(_fundManager.yieldAssetsBalance(), 0, "reserve pre-funded from the deposit");
        // Custody hazard invariant: FM holds 0 underlying at rest.
        assertEq(_usdc.balanceOf(address(_fundManager)), 0, "FM holds no idle underlying");
        assertEq(_usdc.balanceOf(address(_vault)), 0, "vault holds no idle underlying");
    }

    function test_mint_pullsAssets(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        // Offset 12: the first mint of `amount * 10**offset` shares pulls exactly `amount` assets.
        uint256 shares = amount * 1e12;
        _fund(ALICE, amount);

        vm.prank(ALICE);
        uint256 assets = _vault.mint(shares, ALICE);

        assertEq(assets, amount, "first mint pulls assets == shares / 10**offset");
        assertEq(_vault.balanceOf(ALICE), shares, "shares minted");
    }

    function test_withdraw_returnsUnderlying_proportional(uint256 amount, uint256 wPortion) public {
        amount = bound(amount, 2e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        uint256 wAssets = bound(wPortion, 1e6, _vault.maxWithdraw(ALICE));
        uint256 sharesBefore = _vault.balanceOf(ALICE);

        vm.prank(ALICE);
        uint256 burned = _vault.withdraw(wAssets, ALICE, ALICE);

        // Receiver gets exactly the requested underlying (sourced from freed reserve + external).
        assertEq(_usdc.balanceOf(ALICE), wAssets, "received underlying");
        // OZ pro-rata burn (no `trackedPrincipal` decrement — stayers stay whole automatically).
        assertGt(burned, 0, "shares burned for a non-zero withdrawal");
        assertEq(_vault.balanceOf(ALICE), sharesBefore - burned, "shares burned");
        // No idle assets after the call.
        assertEq(_usdc.balanceOf(address(_fundManager)), 0, "FM holds no idle underlying");
    }

    function test_redeem_returnsUnderlying(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        uint256 sharesAtDeposit = _deposit(ALICE, amount);

        // `maxRedeem` may be a hair below `balanceOf` because NAV ticks slightly below par
        // until the GDA buffer is fully released on the recalibrate-to-zero. Single-tx full
        // exit therefore redeems `maxRedeem` (≈ all shares within the relative tolerance).
        uint256 maxShares = _vault.maxRedeem(ALICE);
        assertApproxEqRel(maxShares, sharesAtDeposit, NAV_REL_TOL, "maxRedeem ~ balanceOf");

        vm.prank(ALICE);
        uint256 assets = _vault.redeem(maxShares, ALICE, ALICE);

        assertApproxEqRel(assets, amount, NAV_REL_TOL, "near-full redeem ~ principal");
    }

    function test_preview_convert_areSynchronousAndCorrect(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);

        // Unlike the async sibling, preview* do not revert.
        uint256 pd = _vault.previewDeposit(amount);
        _fund(ALICE, amount);
        vm.prank(ALICE);
        uint256 shares = _vault.deposit(amount, ALICE);
        assertEq(pd, shares, "previewDeposit == actual");

        // Redeem within `maxRedeem` (the GDA-buffer slice keeps maxRedeem a hair below balance).
        uint256 maxShares = _vault.maxRedeem(ALICE);
        uint256 pr = _vault.previewRedeem(maxShares);
        vm.prank(ALICE);
        uint256 assets = _vault.redeem(maxShares, ALICE, ALICE);
        assertEq(pr, assets, "previewRedeem == actual");
    }

    function test_withdraw_revertsOnUnauthorizedSpender() public {
        _deposit(ALICE, DEFAULT_DEPOSIT);
        vm.prank(BOB);
        vm.expectRevert();
        _vault.withdraw(DEFAULT_DEPOSIT / 2, BOB, ALICE);
    }

    /// @dev `maxDeposit` proxies the external vault's deposit limit. The default MockERC4626 is
    ///      uncapped, so it reports `type(uint256).max`; cap the external vault and it follows.
    function test_maxDeposit_capsAtExternalDeposit(uint256 cap) public {
        assertEq(_vault.maxDeposit(ALICE), type(uint256).max, "uncapped external => unbounded deposit");

        cap = bound(cap, 0, ONE_BILLION * 1e6);
        _external.setDepositCap(cap);
        assertEq(_vault.maxDeposit(ALICE), cap, "maxDeposit follows external deposit cap");
    }

    /// @dev `maxMint` short-circuits to `type(uint256).max` when the external vault is uncapped,
    ///      and otherwise converts the external deposit cap into shares (both branches).
    function test_maxMint_uncappedAndCapped(uint256 cap) public {
        // Uncapped branch: short-circuit (StableYieldSyncVault.sol:154).
        assertEq(_vault.maxMint(ALICE), type(uint256).max, "uncapped external => unbounded mint");

        // Capped branch: convert the deposit cap into shares (StableYieldSyncVault.sol:155).
        cap = bound(cap, 1e6, ONE_BILLION * 1e6);
        _external.setDepositCap(cap);
        assertEq(_vault.maxMint(ALICE), _vault.convertToShares(cap), "maxMint == convertToShares(cap)");
    }

    //     ____      __                       __  _
    //    /  _/___  / /____  ____ __________ _/ /_(_)___  ____
    //    / // __ \/ __/ _ \/ __ `/ ___/ __ `/ __/ / __ \/ __ \
    //  _/ // / / / /_/  __/ /_/ / /  / /_/ / /_/ / /_/ / / / /
    // /___/_/ /_/\__/\___/\__, /_/   \__,_/\__/_/\____/_/ /_/
    //                    /____/

    /// @dev The headline new behaviour: the stream starts on the FIRST deposit, with NO
    ///      pre-seeded reserve (pre-funded out of the deposit itself).
    function test_streamStartsAtFirstDeposit_noSeedNeeded() public {
        ISuperfluidPool pool = _fundManager.YIELD_POOL();
        assertEq(pool.getUnits(ALICE), 0, "no units pre-deposit");
        assertEq(pool.getTotalFlowRate(), 0, "no stream pre-deposit");
        // No `_seedReserve`: the deposit pre-funds the reserve out of its own incoming
        // underlying and the stream starts at deposit time.

        _deposit(ALICE, DEFAULT_DEPOSIT);

        assertGt(pool.getUnits(ALICE), 0, "units granted at deposit");
        assertGt(pool.getTotalFlowRate(), 0, "stream started at FIRST deposit (pre-funded)");
        assertGt(pool.getMemberFlowRate(ALICE), 0, "ALICE receiving stream");
    }

    function test_unitsFollowShareTransfer(uint256 amount, uint256 transferShares) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);
        ISuperfluidPool pool = _fundManager.YIELD_POOL();

        uint128 aliceUnits0 = pool.getUnits(ALICE);
        // Transfer any non-zero, non-full slice of ALICE's shares.
        transferShares = bound(transferShares, 1, _vault.balanceOf(ALICE) - 1);

        vm.prank(ALICE);
        _vault.transfer(BOB, transferShares);

        assertGt(pool.getUnits(BOB), 0, "BOB gained units");
        assertLt(pool.getUnits(ALICE), aliceUnits0, "ALICE units decreased");
        // Conservation: total units unchanged by a shareholder->shareholder transfer.
        assertEq(pool.getUnits(ALICE) + pool.getUnits(BOB), aliceUnits0, "units conserved");
    }

    function test_externalSurplus_accruesToSharePrice(uint256 amount, uint256 gain) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        // Price probe = value of ONE whole share. Shares are 18-dec (offset 12), so the probe is
        // 1e18 share-atoms (≈ 1e6 underlying atoms = par at entry), not 1e6.
        uint256 pxBefore = _vault.convertToAssets(1e18);
        uint256 taBefore = _vault.totalAssets();

        // External alpha above the promised rate (the retired "buffer"). Under the floating
        // share there is no protocol-owned cushion held aside — it accrues to holders. Size the
        // gain ≥ 1 share-atom of NAV so the price strictly ticks up past rounding.
        gain = bound(gain, amount / 100 + 1, amount);
        _external.simulateGain(gain);

        // No clamp: the surplus is INCLUDED in NAV and appreciates the share price.
        assertGt(_vault.totalAssets(), taBefore, "external surplus raises NAV (no clamp)");
        assertGt(_vault.convertToAssets(1e18), pxBefore, "share price appreciates with external surplus");
    }

    //     __                    ____  _____
    //    / /   ____  __________/ __ \/ ___/
    //   / /   / __ \/ ___/ ___/ /_/ /\__ \
    //  / /___/ /_/ (__  |__  ) ____/___/ /
    // /_____/\____/____/____/_/    /____/

    function test_loss_reflectsImmediatelyInSharePrice(uint256 amount, uint256 gain, uint256 loss) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        // A meaningful surplus (≥ 2% of principal) so the net surplus after the loss dominates
        // the few-bp GDA-buffer gap that keeps the entry price a hair below par.
        gain = bound(gain, amount / 50 + 1, amount);
        _external.simulateGain(gain);
        uint256 pxAfterGain = _vault.convertToAssets(1e18);

        // Loss strictly below the gain (at most half) so net stays above par, and large enough to
        // move the whole-share price probe by ≥1 atom (Δpx = 1e18·loss/supply ≥ 1 ⇒ loss ≥
        // supply/1e18) so it is observable rather than rounding away on a large position.
        loss = bound(loss, _vault.totalSupply() / 1e18 + 1, gain / 2);
        _external.simulateLoss(loss);

        // No accumulated cushion (the buffer is retired): the loss reflects IMMEDIATELY in the
        // share price — it drops vs. the post-gain price rather than being absorbed.
        assertLt(_vault.convertToAssets(1e18), pxAfterGain, "loss reflects immediately (no buffer)");
        // Net position is still above par (gain > loss): one whole share worth > 1 USDC (1e6 atoms).
        assertGt(_vault.convertToAssets(1e18), 1e6, "net surplus keeps share above par");
    }

    function test_largeLoss_passesThrough_noInterHolderTransfer(uint256 amount, uint256 lossBps) public {
        amount = bound(amount, 2e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);
        _deposit(BOB, amount);

        // Loss as a fraction of the external position so it always passes through honestly while
        // leaving the external vault able to service partial exits. 10%–90% of the external bal.
        uint256 extBal = _usdc.balanceOf(address(_external));
        lossBps = bound(lossBps, 1000, 9000);
        _external.simulateLoss(extBal * lossBps / 10_000);

        // NAV honest: the plain sum of recoverable balances (no clamp).
        uint256 recoverable = _external.maxWithdraw(address(_fundManager)) + _fundManager.scaledYieldAssetsBalance()
            + _usdc.balanceOf(address(_fundManager));
        assertEq(_vault.totalAssets(), recoverable, "totalAssets == recoverable (honest impairment)");
        assertLt(_vault.totalAssets(), 2 * amount, "impaired below total deposits");

        // ALICE exits at the impaired price.
        uint256 aliceShares = _vault.maxRedeem(ALICE);
        vm.prank(ALICE);
        uint256 alicePayout = _vault.redeem(aliceShares, ALICE, ALICE);
        assertLt(alicePayout, amount, "ALICE takes pro-rata impaired payout");

        // BOB's per-share value (in assets) is unchanged by ALICE's impaired exit — OZ pro-rata
        // exits transfer no value between holders. BOB's redemption value should be ~ ALICE's
        // (both bought in at the same price and ALICE exited pro-rata).
        uint256 bobValue = _vault.convertToAssets(_vault.balanceOf(BOB));
        assertApproxEqRel(bobValue, alicePayout, 0.01e18, "no inter-holder value transfer across impaired exit");
    }

    //     __    _             _     ___ __
    //    / /   (_)___ ___  __(_)___/ (_) /___  __
    //   / /   / / __ `/ / / / / __  / / __/ / / /
    //  / /___/ / /_/ / /_/ / / /_/ / / /_/ /_/ /
    // /_____/_/\__, /\__,_/_/\__,_/_/\__/\__, /
    //            /_/                     /____/

    function test_externalIlliquidity_withdrawReverts_maxReflectsIt(uint256 amount, uint256 cap) public {
        amount = bound(amount, 4e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        // External vault can only service `cap` underlying — bounded strictly below a full exit so
        // there is always an over-cap request that must revert. Above 1 USDC so the within-cap leg
        // moves a non-dust amount.
        cap = bound(cap, 1e6, amount / 2);
        _external.setLiquidityCap(cap);

        // maxWithdraw is capped by (ext.maxWithdraw + scaledReserve): at least the external cap,
        // at most the cap plus the pre-fund reserve slice still held.
        uint256 maxW = _vault.maxWithdraw(ALICE);
        assertGe(maxW, cap, "maxWithdraw >= external cap (reserve adds to it)");
        assertLe(maxW, cap + _fundManager.scaledYieldAssetsBalance(), "maxWithdraw <= cap + scaledReserve");

        // A full-principal request (> maxWithdraw) reverts up-front with ERC4626ExceededMaxWithdraw.
        vm.prank(ALICE);
        vm.expectRevert();
        _vault.withdraw(amount, ALICE, ALICE);

        // Within the cap it still works.
        vm.prank(ALICE);
        uint256 burned = _vault.withdraw(cap, ALICE, ALICE);
        assertGt(burned, 0, "capped withdrawal succeeds");
        assertEq(_usdc.balanceOf(ALICE), cap, "received capped amount");
    }

    function test_maxRedeem_reflectsExternalLiquidity(uint256 amount, uint256 cap) public {
        uint256 shares = _deposit(ALICE, bound(amount, 4e6, ONE_BILLION * 1e6));
        // In the healthy state the only gap between maxRedeem and balanceOf is the tiny
        // GDA-buffer-induced NAV tick — within NAV_REL_TOL.
        assertApproxEqRel(_vault.maxRedeem(ALICE), shares, NAV_REL_TOL, "uncapped ~ balance");

        // Cap external liquidity strictly below the recoverable value so the redeem is bound by it.
        cap = bound(cap, 1e6, _vault.totalAssets() / 2);
        _external.setLiquidityCap(cap);
        assertLt(_vault.maxRedeem(ALICE), shares, "redeem capped by external liquidity");
    }

    //    _____       __
    //   / ___/____  / /   _____  ____  _______  __
    //   \__ \/ __ \/ / | / / _ \/ __ \/ ___/ / / /
    //  ___/ / /_/ / /| |/ /  __/ / / / /__/ /_/ /
    // /____/\____/_/ |___/\___/_/ /_/\___/\__, /
    //                                    /____/

    /// @dev Self-funded stream: when external earnings do not cover the promised rate, the
    ///      per-op + `ensureYieldFlowDuration` rebalance pulls from the external position to keep
    ///      the reserve funded; the stream KEEPS FLOWING and the drain reflects honestly in the
    ///      floating NAV (share price ticks below par). No operator injection path is required —
    ///      the sync vault is its own backstop via programmatic `EXTERNAL_VAULT` access.
    function test_impairment_streamKeepsFlowing(uint256 amount, uint256 elapsed) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);
        ISuperfluidPool pool = _fundManager.YIELD_POOL();
        assertGt(pool.getTotalFlowRate(), 0, "stream live");
        uint256 ta0 = _vault.totalAssets();
        uint256 px0 = _vault.convertToAssets(1e18);

        // Time passes without external yield. The reserve drains as the stream pays out; the
        // operator's ensureYieldFlowDuration rebalance pulls from the external position to refund
        // it (no surplus → the pull eats into the deposited principal).
        elapsed = bound(elapsed, 1 days, 365 days);
        vm.warp(block.timestamp + elapsed);
        vm.prank(FUND_OPERATOR);
        _fundManager.ensureYieldFlowDuration();

        // Stream did NOT stall.
        assertGt(pool.getTotalFlowRate(), 0, "stream kept flowing under impairment");
        // The streamed value left the FM's custody → recoverable NAV fell, and the floating
        // share price ticks below par (honest impairment — no clamp, no protocol cushion).
        assertLt(_vault.totalAssets(), ta0, "NAV fell (stream funded out of principal)");
        assertLt(_vault.convertToAssets(1e18), px0, "share price ticked below par (honest impairment)");
    }

    /// @dev [Revision 2026-05-27] Terminal external impairment ⇒ FULL PAUSE. When
    ///      `EXTERNAL_VAULT.maxWithdraw(FM) == 0` the deployed principal is unrecoverable through the
    ///      external vault, so the vault zeroes all four `max*` and OZ reverts every entrypoint: we
    ///      never route a user into a vault they cannot exit, and existing holders keep receiving the
    ///      stream from the reserve rather than racing to withdraw it. (This is why the per-op
    ///      `_recalibrateFlow()` needs no impairment guard — the hooks simply never run while paused.)
    function test_terminalImpairment_pausesAllEntrypoints(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);
        _fund(BOB, DEFAULT_DEPOSIT);

        // External goes terminal: it can no longer service any withdrawal.
        _external.setLiquidityCap(0);
        assertEq(_fundManager.maxExternalVaultWithdraw(), 0, "terminal: external maxWithdraw == 0");

        // All four max* are zeroed.
        assertEq(_vault.maxDeposit(BOB), 0, "maxDeposit paused");
        assertEq(_vault.maxMint(BOB), 0, "maxMint paused");
        assertEq(_vault.maxWithdraw(ALICE), 0, "maxWithdraw paused");
        assertEq(_vault.maxRedeem(ALICE), 0, "maxRedeem paused");

        // Every entrypoint reverts with the corresponding OZ max-exceeded error (max == 0).
        vm.startPrank(BOB);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, BOB, 1e6, 0));
        _vault.deposit(1e6, BOB);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, BOB, 1e6, 0));
        _vault.mint(1e6, BOB);
        vm.stopPrank();

        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, ALICE, 1e6, 0));
        _vault.withdraw(1e6, ALICE, ALICE);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, ALICE, 1e6, 0));
        _vault.redeem(1e6, ALICE, ALICE);
        vm.stopPrank();
    }

    /// @dev The pause lifts when the external position unfreezes (a temporary liquidity freeze, not
    ///      a permanent loss — `maxWithdraw(FM) == 0` does not distinguish the two, both pause).
    ///      Deposits and withdrawals work again at the recovered NAV.
    function test_terminalImpairment_resumesAfterUnfreeze() public {
        _deposit(ALICE, DEFAULT_DEPOSIT);

        _external.setLiquidityCap(0);
        assertEq(_vault.maxWithdraw(ALICE), 0, "paused while frozen");

        // External unfreezes.
        _external.setLiquidityCap(type(uint256).max);
        assertGt(_vault.maxWithdraw(ALICE), 0, "unpaused after unfreeze");

        // A withdrawal now succeeds.
        uint256 wAssets = _vault.maxWithdraw(ALICE) / 2;
        vm.prank(ALICE);
        _vault.withdraw(wAssets, ALICE, ALICE);
        assertEq(_usdc.balanceOf(ALICE), wAssets, "withdraw works after unfreeze");
    }

    /// @dev The operator's bleed-stopping lever survives terminal impairment WITHOUT any guard:
    ///      `setStableYieldRate(0)` recalibrates the flow to zero, which is a flow *close* (needs no
    ///      GDA buffer) and so cannot revert even from a drained reserve. Other operator calls are
    ///      deliberately allowed to revert under terminal impairment — accepted, the operator
    ///      understands the state.
    function test_terminalImpairment_operatorCanZeroRate() public {
        _deposit(ALICE, DEFAULT_DEPOSIT);
        _external.setLiquidityCap(0);

        vm.prank(FUND_OPERATOR);
        _fundManager.setStableYieldRate(0);
        assertEq(_fundManager.stableYieldRate(), 0, "operator zeroed the rate under terminal impairment");
    }

    /// @dev The pause must NOT trigger on the empty-vault bootstrap. A fresh FM holds no external
    ///      position, so `maxExternalVaultWithdraw() == 0` even though it is perfectly healthy —
    ///      the position gate in `_isExternallyPaused()` keeps the first deposit from being bricked.
    function test_bootstrap_notPausedWhenEmpty(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);

        // Empty vault: external maxWithdraw is 0 (nothing deployed) but this is NOT impairment.
        assertEq(_fundManager.maxExternalVaultWithdraw(), 0, "empty: external maxWithdraw == 0");
        assertGt(_vault.maxDeposit(ALICE), 0, "deposit NOT paused on the empty bootstrap");

        // The first deposit succeeds and mints shares.
        uint256 shares = _deposit(ALICE, amount);
        assertGt(shares, 0, "first deposit mints shares despite empty external position");
    }

    /// @dev Boundary: the pause triggers only at `maxWithdraw(FM) == 0`. A *partial* external
    ///      illiquidity (cap > 0) leaves the vault open — deposits and withdrawals still work,
    ///      subject to the usual NAV/liquidity caps.
    function test_partialImpairment_doesNotPause(uint256 amount, uint256 capPortion) public {
        amount = bound(amount, 2e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        // Cap external withdrawals to a positive fraction of the position — partial, not terminal.
        uint256 ta = _fundManager.totalManagedAssets();
        uint256 cap = bound(capPortion, 1e6, ta);
        _external.setLiquidityCap(cap);

        // Not paused: deposit and withdraw remain available.
        assertGt(_vault.maxDeposit(ALICE), 0, "deposit open under partial impairment");
        uint256 maxW = _vault.maxWithdraw(ALICE);
        assertGt(maxW, 0, "withdraw open under partial impairment");

        // A withdrawal within the external's serviceable liquidity (≤ cap) succeeds. (Withdrawing
        // the full `maxWithdraw` here is the separate, still-open OQ #3 over-promise — not tested.)
        uint256 wAssets = cap < maxW ? cap : maxW;
        vm.prank(ALICE);
        _vault.withdraw(wAssets, ALICE, ALICE);
        assertEq(_usdc.balanceOf(ALICE), wAssets, "partial-impairment withdraw within liquidity succeeds");
    }

    /// @dev The pause also triggers on a genuine total loss (external underlying drained to 0), not
    ///      only on a liquidity freeze: `maxWithdraw(FM)` then reads 0 because the position is worth
    ///      nothing, while the FM still holds (now worthless) external shares.
    function test_terminalImpairment_viaTotalLoss() public {
        _deposit(ALICE, DEFAULT_DEPOSIT);

        // Wipe the external vault's underlying — the FM's shares are now worth ~0.
        _external.simulateLoss(_usdc.balanceOf(address(_external)));
        assertEq(_fundManager.maxExternalVaultWithdraw(), 0, "total loss: external maxWithdraw == 0");

        // Fully paused, exactly as under a liquidity freeze.
        assertEq(_vault.maxDeposit(ALICE), 0, "deposit paused after total loss");
        assertEq(_vault.maxWithdraw(ALICE), 0, "withdraw paused after total loss");
    }

    /// @dev Share transfers are NOT gated by the pause: `_update` → `onShareTransfer` only moves GDA
    ///      units (no `_recalibrateFlow`), so a holder can still move shares while the vault is
    ///      paused for deposits/withdrawals.
    function test_terminalImpairment_transfersStillWork() public {
        _deposit(ALICE, DEFAULT_DEPOSIT);
        _external.setLiquidityCap(0);
        assertEq(_vault.maxWithdraw(ALICE), 0, "paused");

        uint256 half = _vault.balanceOf(ALICE) / 2;
        vm.prank(ALICE);
        _vault.transfer(BOB, half);

        assertEq(_vault.balanceOf(BOB), half, "transfer succeeds while paused");
        assertGt(_fundManager.YIELD_POOL().getUnits(BOB), 0, "units followed the transfer");
    }

    //     ____  _            __     ______
    //    / __ \(_)   _____  / /_   /_  __/__  _____/ /______
    //   / /_/ / / | / / _ \/ __/    / / / _ \/ ___/ __/ ___/
    //  / ____/ /| |/ /  __/ /_     / / /  __(__  ) /_(__  )
    // /_/   /_/ |___/\___/\__/    /_/  \___/____/\__/____/
    //
    // Phase-4 pivot-specific risk characterisations + custody hazard.

    /// @dev With the clamp gone a super-token donation to the FM is no longer absorbed: it
    ///      raises NAV and the share price for EXISTING holders. This is an irrational gift, not
    ///      an attack — the donor mints no shares and cannot extract the donation. (The genuine
    ///      residual surface is the classic first-deposit inflation attack; see §Security.)
    function test_donation_superTokenToFM_accruesToHolders() public {
        _deposit(ALICE, DEFAULT_DEPOSIT);
        uint256 sharesUnit = 1e18; // one whole 18-dec share (offset 12)
        uint256 taBefore = _vault.totalAssets();
        uint256 pxBefore = _vault.convertToAssets(sharesUnit);

        // A massive super-token donation directly to the FM.
        _dealUSDCx(address(_fundManager), 500 ether);

        // No clamp: the donation lands in the reserve (counted by scaledYieldAssetsBalance) and
        // raises NAV → raises the share price for the existing holder (ALICE).
        assertGt(_vault.totalAssets(), taBefore, "donation raises NAV (no clamp)");
        assertGt(_vault.convertToAssets(sharesUnit), pxBefore, "share price rises for existing holders");
    }

    /// @dev First-deposit inflation resistance (the clamp's replacement under the floating share).
    ///      An attacker seeds the empty vault with 1 share then donates super-token to the FM to
    ///      inflate price-per-share, aiming to round the victim's deposit to 0 shares. The
    ///      `_decimalsOffset() == 12` override (10**12 virtual shares) makes this infeasible: even a
    ///      donation ~10x the victim's deposit cannot push the previewed share count to 0. Asserted
    ///      at the `previewDeposit` level to isolate the rounding from the rebalance behaviour of
    ///      executing a deposit against a massively-inflated reserve.
    function test_firstDepositInflation_victimMintsNonZero(uint256 victimAmount) public {
        victimAmount = bound(victimAmount, 1e6, ONE_BILLION * 1e6);

        // Attacker seeds the empty vault with the smallest possible position (1 share).
        _deposit(ALICE, 1);

        // Attacker donates super-token to the FM, inflating NAV ~10x above the victim's deposit
        // (donation in 18-dec super-token terms; /SCALING_FACTOR=1e12 gives the underlying value).
        _dealUSDCx(address(_fundManager), (victimAmount + 1) * 1e12 * 10);

        // With the virtual-share offset the victim's deposit still previews to a non-zero amount.
        assertGt(_vault.previewDeposit(victimAmount), 0, "victim mints non-zero shares (virtual-share offset)");
    }

    /// @dev Custody hazard invariant (design.md Inv. 7): the FM holds 0 underlying at rest
    ///      after every entrypoint. Principal in transit must never linger as raw underlying,
    ///      or the rebalance trim branch would treat it as excess to redeposit.
    function test_custodyHazard_fmHoldsNoIdleUnderlying() public {
        _deposit(ALICE, DEFAULT_DEPOSIT);
        assertEq(_usdc.balanceOf(address(_fundManager)), 0, "post-deposit: 0 underlying in FM");

        vm.prank(ALICE);
        _vault.withdraw(DEFAULT_DEPOSIT / 2, ALICE, ALICE);
        assertEq(_usdc.balanceOf(address(_fundManager)), 0, "post-withdraw: 0 underlying in FM");

        _external.simulateGain(50 * 1e6);
        vm.prank(FUND_OPERATOR);
        _fundManager.ensureYieldFlowDuration();
        assertEq(_usdc.balanceOf(address(_fundManager)), 0, "post-rebalance: 0 underlying in FM");
    }

    /// @dev Withdraw is NOT bricked when the external vault signals "deposits closed" via the
    ///      standard ERC-4626 channel (`maxDeposit == 0`) while still servicing withdrawals.
    ///      The `_rebalanceYieldAssets()` `deficit < 0` branch's pre-check skips the post-payout
    ///      trim, leaving the freed excess as above-target super-token slack in the reserve
    ///      (D.4 weakened to "best-effort, gated on external maxDeposit"). Pinned by this test
    ///      (resolution of `[VERIFY]` redeposit-revert, 2026-05-28).
    function test_withdraw_notBrickedByRedepositCap(uint256 amount, uint256 wPortion) public {
        amount = bound(amount, 2e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        // External: standards-compliant "deposits closed" signal (maxDeposit returns 0); withdrawals
        // continue. The α fix's pre-check honours this.
        _external.setDepositCap(0);

        uint256 wAssets = bound(wPortion, 1e6, _vault.maxWithdraw(ALICE));
        vm.prank(ALICE);
        _vault.withdraw(wAssets, ALICE, ALICE);

        assertEq(_usdc.balanceOf(ALICE), wAssets, "withdraw not bricked by external maxDeposit == 0");
    }

    /// @dev KNOWN LIMITATION: the best-effort trim trusts ERC-4626 compliance. If the external
    ///      vault reverts `deposit` despite reporting `maxDeposit > 0`, the pre-check waves the
    ///      call through and the revert propagates, bricking the withdraw. Accepted; design.md
    ///      §Security already requires standard, audited externals. This test pins the boundary
    ///      so an audit cannot mistake it for a regression.
    function test_withdraw_brickedByNonCompliantExternal() public {
        _deposit(ALICE, DEFAULT_DEPOSIT);

        // Non-compliant: deposit reverts unconditionally, maxDeposit still returns uint256.max.
        _external.setDepositReverts(true);

        // A withdrawal that needs the post-payout trim will brick. We confirm the cause is the
        // mock's revert string (not e.g. a different error), so the test is pinning the right thing.
        uint256 wAssets = _vault.maxWithdraw(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(bytes("MockERC4626: deposit paused"));
        _vault.withdraw(wAssets, ALICE, ALICE);
    }

}
