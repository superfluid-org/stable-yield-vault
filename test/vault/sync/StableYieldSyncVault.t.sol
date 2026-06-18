// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { SyncVaultTestBase } from "./SyncVaultTestBase.t.sol";
import { MockMorphoVaultV2 } from "test/mocks/MockMorphoVaultV2.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";
import { IFundManagerBase } from "src/interfaces/common/IFundManagerBase.sol";

import { IStableYieldSyncVault } from "src/interfaces/vault/sync/IStableYieldSyncVault.sol";
import { ISyncFundManager } from "src/interfaces/vault/sync/ISyncFundManager.sol";
import { StableYieldSyncVault } from "src/vault/sync/StableYieldSyncVault.sol";

/**
 * @title StableYieldSyncVaultTest
 * @notice Sync-vault suite for the floating-share model: the FM is the sole custodian, the
 *         stream is pre-funded from each deposit, and NAV is the reserve-inclusive plain sum of
 *         the FM's recoverable balances (no clamp), so the external surplus accrues to holders as
 *         share appreciation and losses reflect immediately. Withdraw pays a shares-proportional
 *         reserve slice plus the external vault; exits are OZ pro-rata. See
 *         `docs/sync-vault/design.md`.
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

    /// @dev The shared base constructor rejects an initial `rate * duration` that exceeds
    ///      `YEAR * BP_DENOMINATOR` (would pre-fund > 100% of the streamed notional). 100% rate for
    ///      2 years breaches it; the FM constructor reverts and propagates through the vault ctor.
    function test_constructor_revertsOnUnsustainableRateDuration() public {
        vm.expectRevert(IFundManagerBase.INVALID_YIELD_DURATION_COMBINATION.selector);
        new StableYieldSyncVault(
            TREASURY,
            address(_usdc),
            address(_usdcx),
            address(_external),
            FUND_OPERATOR,
            FUND_ADMIN,
            10_000, // 100% annual rate
            730 days, // 2 years > 1-year max at 100% ⇒ rate * duration > YEAR * BP_DENOMINATOR
            SHARE_NAME,
            SHARE_SYMBOL
        );
    }

    function test_constructor_revertsOnExternalAssetMismatch() public {
        // External vault over a *different* asset.
        MockMorphoVaultV2 wrongExternal = new MockMorphoVaultV2(IERC20(address(_usdcx)), "Wrong", "WRG");

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

        uint256 fee = _vault.DEPOSIT_FEE();
        vm.prank(ALICE);
        uint256 assets = _vault.mintWithFee{ value: fee }(shares, ALICE);

        assertEq(assets, amount, "first mint pulls assets == shares / 10**offset");
        assertEq(_vault.balanceOf(ALICE), shares, "shares minted");
    }

    /// @dev The plain ERC-4626 `deposit`/`mint` are disabled: state mutability forbids re-adding
    ///      `payable` on an override, so the fee-bearing flow lives on `depositWithFee`/`mintWithFee`
    ///      and the canonical entrypoints hard-revert with `INVALID_CALL` (before any max/balance
    ///      check) to force callers through the fee path.
    function test_deposit_disabled_reverts() public {
        _fund(ALICE, DEFAULT_DEPOSIT);
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldSyncVault.INVALID_CALL.selector);
        _vault.deposit(DEFAULT_DEPOSIT, ALICE);
    }

    function test_mint_disabled_reverts() public {
        _fund(ALICE, DEFAULT_DEPOSIT);
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldSyncVault.INVALID_CALL.selector);
        _vault.mint(DEFAULT_DEPOSIT * 1e12, ALICE);
    }

    /// @dev The disabled overrides revert even on an empty vault with open gates — the revert is
    ///      unconditional, not a consequence of a `max*` check.
    function test_deposit_disabled_revertsEvenWhenDepositable() public {
        assertEq(_vault.maxDeposit(ALICE), type(uint256).max, "sanity: deposits otherwise open");
        _fund(ALICE, DEFAULT_DEPOSIT);
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldSyncVault.INVALID_CALL.selector);
        _vault.deposit(DEFAULT_DEPOSIT, ALICE);
    }

    /// @dev `depositWithFee` collects exactly `DEPOSIT_FEE` in ETH and forwards it to the treasury,
    ///      then performs the underlying deposit.
    function test_depositWithFee_forwardsFeeToTreasury(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        uint256 fee = _vault.DEPOSIT_FEE();
        _fund(ALICE, amount);

        uint256 treasuryBefore = TREASURY.balance;
        vm.prank(ALICE);
        uint256 shares = _vault.depositWithFee{ value: fee }(amount, ALICE);

        assertEq(shares, amount * 1e12, "deposit went through");
        assertEq(TREASURY.balance - treasuryBefore, fee, "fee forwarded to treasury");
    }

    /// @dev `mintWithFee` likewise forwards the fee to the treasury.
    function test_mintWithFee_forwardsFeeToTreasury(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        uint256 fee = _vault.DEPOSIT_FEE();
        _fund(ALICE, amount);

        uint256 treasuryBefore = TREASURY.balance;
        vm.prank(ALICE);
        uint256 assets = _vault.mintWithFee{ value: fee }(amount * 1e12, ALICE);

        assertEq(assets, amount, "mint pulled the assets");
        assertEq(TREASURY.balance - treasuryBefore, fee, "fee forwarded to treasury");
    }

    /// @dev Wrong `msg.value` (too little or too much) reverts `INVALID_DEPOSIT_FEE` on both
    ///      fee-bearing entrypoints — the fee is an exact-match toll, not a minimum.
    function test_depositWithFee_revertsOnWrongFee(uint256 wrongFee) public {
        uint256 fee = _vault.DEPOSIT_FEE();
        wrongFee = bound(wrongFee, 0, 1 ether);
        vm.assume(wrongFee != fee);
        _fund(ALICE, DEFAULT_DEPOSIT);

        vm.prank(ALICE);
        vm.expectRevert(IStableYieldSyncVault.INVALID_DEPOSIT_FEE.selector);
        _vault.depositWithFee{ value: wrongFee }(DEFAULT_DEPOSIT, ALICE);
    }

    function test_mintWithFee_revertsOnWrongFee(uint256 wrongFee) public {
        uint256 fee = _vault.DEPOSIT_FEE();
        wrongFee = bound(wrongFee, 0, 1 ether);
        vm.assume(wrongFee != fee);
        _fund(ALICE, DEFAULT_DEPOSIT);

        vm.prank(ALICE);
        vm.expectRevert(IStableYieldSyncVault.INVALID_DEPOSIT_FEE.selector);
        _vault.mintWithFee{ value: wrongFee }(DEFAULT_DEPOSIT * 1e12, ALICE);
    }

    /// @dev If the treasury rejects the ETH transfer, the fee collection reverts `FEE_TRANSFER_FAILED`
    ///      (and the whole deposit rolls back). Simulated by etching a stub that reverts on receive
    ///      at the treasury address.
    function test_depositWithFee_revertsWhenTreasuryRejects() public {
        // Runtime bytecode `PUSH1 0 PUSH1 0 REVERT` — reverts on any (value) call.
        _fund(ALICE, DEFAULT_DEPOSIT);
        uint256 fee = _vault.DEPOSIT_FEE();
        vm.etch(TREASURY, hex"60006000fd");

        vm.prank(ALICE);
        vm.expectRevert(IStableYieldSyncVault.FEE_TRANSFER_FAILED.selector);
        _vault.depositWithFee{ value: fee }(DEFAULT_DEPOSIT, ALICE);
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
        uint256 fee = _vault.DEPOSIT_FEE();
        vm.prank(ALICE);
        uint256 shares = _vault.depositWithFee{ value: fee }(amount, ALICE);
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

    /// @dev `maxDeposit`/`maxMint` are binary under Morpho V2: the external has no amount-based
    ///      deposit cap (its own `maxDeposit` is hardcoded 0 and never consulted), so the vault
    ///      advertises unlimited while the FM's deposit-side gates clear and 0 when either blocks.
    function test_maxDepositMint_followExternalGates() public {
        assertEq(_vault.maxDeposit(ALICE), type(uint256).max, "open gates => unbounded deposit");
        assertEq(_vault.maxMint(ALICE), type(uint256).max, "open gates => unbounded mint");

        _external.setCanSendAssets(false);
        assertEq(_vault.maxDeposit(ALICE), 0, "blocked send-assets gate zeroes maxDeposit");
        assertEq(_vault.maxMint(ALICE), 0, "blocked send-assets gate zeroes maxMint");
        _external.setCanSendAssets(true);

        _external.setCanReceiveShares(false);
        assertEq(_vault.maxDeposit(ALICE), 0, "blocked receive-shares gate zeroes maxDeposit");
        assertEq(_vault.maxMint(ALICE), 0, "blocked receive-shares gate zeroes maxMint");
        _external.setCanReceiveShares(true);

        assertEq(_vault.maxDeposit(ALICE), type(uint256).max, "reopens once both gates clear");
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
        uint256 recoverable = _external.previewRedeem(_external.balanceOf(address(_fundManager)))
            + _fundManager.scaledYieldAssetsBalance() + _usdc.balanceOf(address(_fundManager));
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

    /// @dev ACCEPTED `max*` DEVIATION: Morpho V2 exposes no liquidity view, so `maxWithdraw` caps
    ///      by the external position's *value*, not its instant liquidity — a request within
    ///      `maxWithdraw` can therefore revert at the external leg on a liquidity shortfall
    ///      (Morpho's permissionless `forceDeallocate` is the unstick path). Within the available
    ///      liquidity, withdrawals keep working.
    function test_externalIlliquidity_withdrawWithinMaxCanRevert(uint256 amount, uint256 cap) public {
        amount = bound(amount, 4e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        // Clear the standing GDA-buffer deficit while liquidity is still unlimited (operator
        // diligence): the post-deposit reserve sits one stream-buffer below target, and the next
        // rebalance pull (~buffer-sized) would itself trip the cap — masking the payout path this
        // test isolates.
        vm.prank(FUND_OPERATOR);
        _fundManager.ensureYieldFlowDuration();

        // External can only move `cap` underlying per call — far below a full exit.
        cap = bound(cap, 1e6, amount / 4);
        _external.setLiquidityCap(cap);

        // maxWithdraw does NOT see the liquidity cap: still ~ the full position value.
        uint256 maxW = _vault.maxWithdraw(ALICE);
        assertGt(maxW, cap, "maxWithdraw ignores external instant liquidity (accepted overestimate)");

        // A near-full request within maxW reverts at the external leg (not an OZ max* revert).
        vm.prank(ALICE);
        vm.expectRevert(bytes("MockMorphoVaultV2: insufficient liquidity"));
        _vault.withdraw(maxW, ALICE, ALICE);

        // Within the available liquidity it still works (the external leg <= the request < cap).
        uint256 wAssets = cap / 2;
        vm.prank(ALICE);
        uint256 burned = _vault.withdraw(wAssets, ALICE, ALICE);
        assertGt(burned, 0, "within-liquidity withdrawal succeeds");
        assertEq(_usdc.balanceOf(ALICE), wAssets, "received the requested amount");
    }

    /// @dev `maxRedeem` is capped by the reserve-inclusive NAV, NOT by the external vault's
    ///      instant liquidity (no liquidity view on Morpho V2 — same accepted overestimate as
    ///      `test_externalIlliquidity_withdrawWithinMaxCanRevert`).
    function test_maxRedeem_ignoresExternalLiquidity(uint256 amount, uint256 cap) public {
        uint256 shares = _deposit(ALICE, bound(amount, 4e6, ONE_BILLION * 1e6));
        // In the healthy state the only gap between maxRedeem and balanceOf is the tiny
        // GDA-buffer-induced NAV tick — within NAV_REL_TOL.
        assertApproxEqRel(_vault.maxRedeem(ALICE), shares, NAV_REL_TOL, "open state ~ balance");
        uint256 maxRBefore = _vault.maxRedeem(ALICE);

        // An external liquidity crunch does not move maxRedeem (the position value is unchanged).
        cap = bound(cap, 0, _vault.totalAssets() / 2);
        _external.setLiquidityCap(cap);
        assertEq(_vault.maxRedeem(ALICE), maxRBefore, "maxRedeem unchanged by external illiquidity");
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

    /// @dev Terminal external impairment ⇒ FULL PAUSE. When the FM's external position is
    ///      worthless (`externalPositionValue() == 0` — share price driven to 0 here; an external
    ///      share burn reads identically through `previewRedeem(balanceOf)`), the deployed
    ///      principal is unrecoverable, so the vault zeroes all four `max*` and OZ reverts every
    ///      entrypoint: we never route a user into a vault they cannot exit, and existing holders
    ///      keep receiving the stream from the reserve rather than racing to withdraw it. (This is
    ///      why the per-op `_recalibrateFlow()` needs no impairment guard — the hooks simply never
    ///      run while paused.)
    function test_terminalImpairment_pausesAllEntrypoints(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);
        _fund(BOB, DEFAULT_DEPOSIT);

        // External goes terminal: a total loss wipes the position's value.
        _external.simulateLoss(_usdc.balanceOf(address(_external)));
        assertEq(_fundManager.externalPositionValue(), 0, "terminal: external position worth 0");

        // All four max* are zeroed.
        assertEq(_vault.maxDeposit(BOB), 0, "maxDeposit paused");
        assertEq(_vault.maxMint(BOB), 0, "maxMint paused");
        assertEq(_vault.maxWithdraw(ALICE), 0, "maxWithdraw paused");
        assertEq(_vault.maxRedeem(ALICE), 0, "maxRedeem paused");

        // Every entrypoint reverts with the corresponding OZ max-exceeded error (max == 0). The
        // fee-bearing entrypoints collect the fee first, then revert at the OZ max check (rolling
        // the fee transfer back), so the surfaced error is still `ERC4626ExceededMax*`.
        uint256 fee = _vault.DEPOSIT_FEE();
        vm.startPrank(BOB);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, BOB, 1e6, 0));
        _vault.depositWithFee{ value: fee }(1e6, BOB);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, BOB, 1e6, 0));
        _vault.mintWithFee{ value: fee }(1e6, BOB);
        vm.stopPrank();

        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, ALICE, 1e6, 0));
        _vault.withdraw(1e6, ALICE, ALICE);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, ALICE, 1e6, 0));
        _vault.redeem(1e6, ALICE, ALICE);
        vm.stopPrank();
    }

    /// @dev The pause's second trigger: Morpho's exit gates blocking the FM
    ///      (`canWithdrawExternal() == false`). The position has value but the FM cannot pull it,
    ///      so routing money in (or letting holders race the reserve) is equally wrong. Either
    ///      exit-side gate suffices, and the pause lifts when the gate reopens (a gate block is
    ///      curator action, not a loss — NAV is unchanged across the block).
    function test_pause_onBlockedExitGates_resumesAfterUnblock() public {
        _deposit(ALICE, DEFAULT_DEPOSIT);

        _external.setCanSendShares(false);
        assertEq(_vault.maxDeposit(ALICE), 0, "deposit paused under blocked send-shares gate");
        assertEq(_vault.maxWithdraw(ALICE), 0, "withdraw paused under blocked send-shares gate");
        _external.setCanSendShares(true);

        _external.setCanReceiveAssets(false);
        assertEq(_vault.maxWithdraw(ALICE), 0, "withdraw paused under blocked receive-assets gate");
        _external.setCanReceiveAssets(true);

        // Gates reopened: a withdrawal now succeeds at the unchanged NAV.
        assertGt(_vault.maxWithdraw(ALICE), 0, "unpaused once gates clear");
        uint256 wAssets = _vault.maxWithdraw(ALICE) / 2;
        vm.prank(ALICE);
        _vault.withdraw(wAssets, ALICE, ALICE);
        assertEq(_usdc.balanceOf(ALICE), wAssets, "withdraw works after the gate unblocks");
    }

    /// @dev The operator's bleed-stopping lever survives terminal impairment WITHOUT any guard:
    ///      `setStableYieldRate(0)` recalibrates the flow to zero, which is a flow *close* (needs no
    ///      GDA buffer) and so cannot revert even from a drained reserve. Other operator calls are
    ///      deliberately allowed to revert under terminal impairment — accepted, the operator
    ///      understands the state.
    function test_terminalImpairment_operatorCanZeroRate() public {
        _deposit(ALICE, DEFAULT_DEPOSIT);
        _external.simulateLoss(_usdc.balanceOf(address(_external)));

        vm.prank(FUND_OPERATOR);
        _fundManager.setStableYieldRate(0);
        assertEq(_fundManager.stableYieldRate(), 0, "operator zeroed the rate under terminal impairment");
    }

    /// @dev The pause must NOT trigger on the empty-vault bootstrap. A fresh FM holds no external
    ///      position, so `externalPositionValue() == 0` even though it is perfectly healthy —
    ///      the `totalSupply() == 0` gate in `_isExternallyPaused()` keeps the first deposit from
    ///      being bricked (there are no depositors to protect).
    function test_bootstrap_notPausedWhenEmpty(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);

        // Empty vault: the external position is worth 0 (nothing deployed) but this is NOT impairment.
        assertEq(_fundManager.externalPositionValue(), 0, "empty: external position worth 0");
        assertEq(_vault.totalSupply(), 0, "bootstrap: no shares");
        assertGt(_vault.maxDeposit(ALICE), 0, "deposit NOT paused on the empty bootstrap");

        // The first deposit succeeds and mints shares.
        uint256 shares = _deposit(ALICE, amount);
        assertGt(shares, 0, "first deposit mints shares despite empty external position");
    }

    /// @dev A dust external-*share* donation must not pause the bootstrap. Dust shares floor to
    ///      `previewRedeem(balanceOf) == 0` (here via a sub-1 external PPS; equivalently, for a
    ///      decimals-offset external, at any PPS), so a gate keyed on `balanceOf(FM) > 0 &&
    ///      externalPositionValue() == 0` would flip all four `max*` to 0 and brick the bootstrap.
    ///      The `totalSupply() == 0` gate removes the lever: with no depositors there is nothing to
    ///      protect, so the donation cannot pause the vault.
    function test_bootstrap_notBrickedByDustExternalShareDonation(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);

        // Push the external into a sub-1 PPS state, then donate a single dust share to the FM so the
        // FM holds external shares worth 0 recoverable assets — the exact state a balance-keyed gate
        // would pause on.
        _dealUSDC(address(this), 2e6);
        _usdc.approve(address(_external), type(uint256).max);
        _external.deposit(2e6, address(this));
        _external.simulateLoss(2e6 - 1); // totalAssets → 1, totalSupply → 2e6 ⇒ convertToAssets(1) == 0
        _external.transfer(address(_fundManager), 1);

        // A balance-keyed gate would trigger here …
        assertGt(_external.balanceOf(address(_fundManager)), 0, "FM holds donated dust external shares");
        assertEq(_fundManager.externalPositionValue(), 0, "dust shares recover 0 assets");
        // … but with no supply the vault is NOT paused.
        assertEq(_vault.totalSupply(), 0, "still bootstrap");
        assertGt(_vault.maxDeposit(ALICE), 0, "bootstrap NOT bricked by the dust donation");

        uint256 shares = _deposit(ALICE, amount);
        assertGt(shares, 0, "first deposit succeeds despite the dust donation");
    }

    /// @dev External *illiquidity* never pauses — Morpho V2 has no liquidity view, so the pause
    ///      cannot key on it (the accepted blind spot: an over-liquidity request reverts at the
    ///      external leg instead, see `test_externalIlliquidity_withdrawWithinMaxCanRevert`).
    ///      Deposits and within-liquidity withdrawals keep working.
    function test_externalIlliquidity_doesNotPause(uint256 amount, uint256 capPortion) public {
        amount = bound(amount, 2e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        // Clear the standing GDA-buffer deficit while liquidity is still unlimited (see
        // `test_externalIlliquidity_withdrawWithinMaxCanRevert`), so the within-liquidity
        // withdrawal below exercises the payout path rather than a buffer-sized rebalance pull.
        vm.prank(FUND_OPERATOR);
        _fundManager.ensureYieldFlowDuration();

        // Cap external per-call liquidity to a positive fraction of the position.
        uint256 ta = _fundManager.totalManagedAssets();
        uint256 cap = bound(capPortion, 1e6, ta);
        _external.setLiquidityCap(cap);

        // Not paused: deposit and withdraw remain available.
        assertGt(_vault.maxDeposit(ALICE), 0, "deposit open under external illiquidity");
        uint256 maxW = _vault.maxWithdraw(ALICE);
        assertGt(maxW, 0, "withdraw open under external illiquidity");

        // A withdrawal within the external's serviceable liquidity (≤ cap) succeeds.
        uint256 wAssets = cap < maxW ? cap : maxW;
        vm.prank(ALICE);
        _vault.withdraw(wAssets, ALICE, ALICE);
        assertEq(_usdc.balanceOf(ALICE), wAssets, "withdraw within external liquidity succeeds");
    }

    /// @dev Share transfers are NOT gated by the pause: `_update` → `onShareTransfer` only moves GDA
    ///      units (no `_recalibrateFlow`), so a holder can still move shares while the vault is
    ///      paused for deposits/withdrawals.
    function test_terminalImpairment_transfersStillWork() public {
        _deposit(ALICE, DEFAULT_DEPOSIT);
        _external.setCanSendShares(false);
        assertEq(_vault.maxWithdraw(ALICE), 0, "paused");

        uint256 half = _vault.balanceOf(ALICE) / 2;
        vm.prank(ALICE);
        _vault.transfer(BOB, half);

        assertEq(_vault.balanceOf(BOB), half, "transfer succeeds while paused");
        assertGt(_fundManager.YIELD_POOL().getUnits(BOB), 0, "units followed the transfer");
    }

    /// @dev The `Ceil`-rounded unit decrease in `onWithdraw` can zero a holder's GDA units while
    ///      leaving a dust share residual (a near-full redeem rounds `delta` up to the holder's
    ///      entire unit balance). `onShareTransfer` skips the (no-op) unit move when the sender has
    ///      zero units, so that residual stays transferable (it must not revert).
    function test_residualSharesTransferableAfterUnitZeroingRedeem() public {
        // 1 USDC → 1e6 units, 1e18 shares (offset 12). Smallest position where a near-full redeem
        // Ceil-rounds the unit decrease up to the full 1e6, zeroing units ahead of the last shares.
        _deposit(ALICE, 1e6);
        assertEq(_fundManager.YIELD_POOL().getUnits(ALICE), 1e6, "precondition: ALICE has units");

        // Redeem the maximum (NAV sits a hair below the 1e6 deposit due to the GDA buffer lockup,
        // so maxRedeem < total shares — leaving a residual). delta = ceil(1e6 * maxR / 1e18) = 1e6.
        uint256 maxR = _vault.maxRedeem(ALICE);
        vm.prank(ALICE);
        _vault.redeem(maxR, ALICE, ALICE);

        uint256 residual = _vault.balanceOf(ALICE);
        assertGt(residual, 0, "dust share residual remains");
        assertEq(_fundManager.YIELD_POOL().getUnits(ALICE), 0, "units Ceil-zeroed ahead of the residual");

        // The residual must remain transferable.
        vm.prank(ALICE);
        _vault.transfer(BOB, residual);

        assertEq(_vault.balanceOf(ALICE), 0, "residual moved out");
        assertEq(_vault.balanceOf(BOB), residual, "BOB received the residual shares");
        assertEq(_fundManager.YIELD_POOL().getUnits(BOB), 0, "no units moved (sender had none)");
    }

    /// @dev A super-token donation to the FM is not absorbed: it raises NAV and the share price for
    ///      EXISTING holders. This is an irrational gift, not an attack — the donor mints no shares
    ///      and cannot extract the donation. (The genuine residual surface is the classic
    ///      first-deposit inflation attack; see `test_firstDepositInflation_victimMintsNonZero`.)
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

    /// @dev A deposit must not be bricked by an above-target reserve. The `_rebalanceYieldAssets()`
    ///      trim downgrades + redeposits **exactly** `underlyingNeeded`, not `balanceOf(this)` — the
    ///      latter would sweep the user's just-arrived `assets` (which live in the FM as raw
    ///      underlying during `onDeposit`), so the explicit `EXTERNAL_VAULT.deposit(toExternal, …)`
    ///      later in `onDeposit` would revert against an empty FM.
    ///
    ///      Trigger: any persistent reserve > target state at deposit time. Cheapest is a
    ///      super-token donation directly to the FM (donor loses the donation; without the fix every
    ///      subsequent `deposit` would brick — a low-cost DoS).
    function test_deposit_notBrickedAfterSuperTokenDonation() public {
        _deposit(ALICE, DEFAULT_DEPOSIT);

        // Attacker donates super-token directly to the FM, bloating the reserve above target.
        // 500 ether USDCx ≈ 500 USDC equivalent — many orders of magnitude above the ~bp-scale
        // forward-solvency target, so `_rebalanceYieldAssets()` reads deficit < 0 going forward.
        _dealUSDCx(address(_fundManager), 500 ether);

        // Bob's deposit must succeed: the trim branch in onDeposit must not sweep Bob's raw
        // underlying.
        uint256 bobShares = _deposit(BOB, DEFAULT_DEPOSIT);

        assertGt(bobShares, 0, "Bob's deposit mints shares (not bricked)");
        assertEq(_usdc.balanceOf(address(_fundManager)), 0, "FM holds 0 raw underlying after deposit (A.2)");
        // Bob's units track his nominal contributed principal (C.1).
        assertEq(
            _fundManager.YIELD_POOL().getUnits(BOB), DEFAULT_DEPOSIT, "Bob units == _toUnit(assets) regardless of NAV"
        );
    }

    /// @dev Non-malicious trigger of the same above-target-reserve state: the operator drops the
    ///      rate while the external's deposit-side gate is blocked (the best-effort trim is
    ///      skipped, leaving the reserve above the new target as super-token slack), then the gate
    ///      reopens, then a user deposits. The trim, now reachable, must run cleanly and the
    ///      deposit must succeed.
    function test_deposit_notBrickedAfterRateDropWithClosedExternal() public {
        _deposit(ALICE, DEFAULT_DEPOSIT);

        // Block the deposit-side gate, then operator drops the rate. `setStableYieldRate` runs
        // `_rebalanceYieldAssets()`; the trim branch sees `canDepositExternal() == false` and
        // skips, leaving the reserve as above-target super-token slack.
        _external.setCanSendAssets(false);
        vm.prank(FUND_OPERATOR);
        _fundManager.setStableYieldRate(INITIAL_ERA_STABLE_YIELD_RATE / 10);

        // The gate reopens. The above-target slack is now redeposit-able.
        _external.setCanSendAssets(true);

        // Bob's deposit must succeed: the trim, now reachable, must not sweep Bob's raw underlying.
        uint256 bobShares = _deposit(BOB, DEFAULT_DEPOSIT);

        assertGt(bobShares, 0, "Bob's deposit mints shares (not bricked)");
        assertEq(_usdc.balanceOf(address(_fundManager)), 0, "FM holds 0 raw underlying after deposit (A.2)");
    }

    /// @dev A raw-underlying donation to the FM is counted in NAV (`totalManagedAssets` sums
    ///      `UNDERLYING_ASSET.balanceOf(FM)`) and so lifts the advertised `max*`. `onWithdraw`
    ///      realizes the resting raw first (capped at the external slice), keeping
    ///      `fromExternal ≤` the external position's value. Without this, a full redeem would compute
    ///      `fromExternal = E + D >` the position value `E` and the external withdraw would revert,
    ///      bricking the redemption (F.2 break) and stranding the donation `D`. Realizing it routes
    ///      the donation to the holder (the "irrational gift", delivered rather than stranded).
    function test_redeem_notBrickedByRawUnderlyingDonation() public {
        uint256 shares = _deposit(ALICE, DEFAULT_DEPOSIT);
        uint256 navBefore = _fundManager.totalManagedAssets(); // < deposit: GDA stream buffer is locked out

        // Griefer transfers raw USDC straight to the FM (cost = the donation; pure griefing).
        uint256 donation = 500 * 1e6;
        _dealUSDC(address(_fundManager), donation);

        // The raw term lifts NAV (and hence the advertised max*) by exactly the donation.
        uint256 navAfter = _fundManager.totalManagedAssets();
        assertEq(navAfter, navBefore + donation, "raw donation counted in NAV");

        // Sole holder redeems everything within maxRedeem: must NOT revert (F.2). Without realizing
        // the raw, this would revert in EXTERNAL_VAULT.withdraw (fromExternal = E + D > maxWithdraw = E).
        uint256 maxR = _vault.maxRedeem(ALICE);
        assertEq(maxR, shares, "all shares redeemable (request == max*)");

        uint256 aliceBefore = _usdc.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 assetsOut = _vault.redeem(shares, ALICE, ALICE);

        // The donation accrued to the holder (sole holder realizes ~full NAV, incl. the donation),
        // and nothing is left resting in the FM as raw — it was realized, not stranded.
        assertEq(_usdc.balanceOf(ALICE) - aliceBefore, assetsOut, "receiver got the full payout");
        assertApproxEqAbs(assetsOut, navAfter, 2, "holder realizes ~full NAV including the donation");
        assertEq(_usdc.balanceOf(address(_fundManager)), 0, "donation fully realized; no raw stranded in FM");
    }

    /// @dev Covers the `fromDonation > fromExternal` cap in `onWithdraw`: when the resting raw
    ///      donation exceeds the external slice of *this* withdrawal, only the slice's worth is spent
    ///      and the remainder stays resting (realized by later withdrawals). Triggered by a donation
    ///      large relative to a *partial* redeem (the full sole-holder redeem in the test above takes
    ///      the `<=` branch: the slice = external + donation > donation). The redeem must still
    ///      succeed and `fromExternal` must stay 0 (the slice is fully covered by the capped donation).
    function test_redeem_rawDonationCappedAtExternalSlice() public {
        uint256 shares = _deposit(ALICE, DEFAULT_DEPOSIT);

        // A raw donation far larger than the external slice of a small partial redeem.
        uint256 donation = 3000 * 1e6;
        _dealUSDC(address(_fundManager), donation);

        // Redeem only 10% of the position. fromExternal (pre-cap) = redeemingAssets - fromYieldAssets
        // ≈ 10% of (external + donation), which is well below the full `donation` resting in the FM,
        // so the cap on line `if (fromDonation > fromExternal) fromDonation = fromExternal;` fires.
        uint256 sharesToRedeem = shares / 10;
        uint256 supply = _vault.totalSupply();
        uint256 redeemingAssets = _vault.previewRedeem(sharesToRedeem);
        uint256 fromYieldAssets = Math.min(
            Math.mulDiv(_fundManager.scaledYieldAssetsBalance(), sharesToRedeem, supply, Math.Rounding.Ceil),
            redeemingAssets
        );
        uint256 fromExternalSlice = redeemingAssets - fromYieldAssets;
        assertGt(donation, fromExternalSlice, "donation exceeds the external slice: cap branch is exercised");

        uint256 aliceBefore = _usdc.balanceOf(ALICE);

        vm.prank(ALICE);
        uint256 assetsOut = _vault.redeem(sharesToRedeem, ALICE, ALICE);

        assertEq(_usdc.balanceOf(ALICE) - aliceBefore, assetsOut, "receiver got the full payout");
        assertEq(assetsOut, redeemingAssets, "payout == previewed redeem");
        // The cap left a remainder of the donation resting in the FM (only the external slice's worth
        // was spent), to be realized by later withdrawals — the defining effect of the `true` branch.
        assertApproxEqAbs(
            _usdc.balanceOf(address(_fundManager)),
            donation - fromExternalSlice,
            2,
            "uncapped donation remainder still rests in the FM"
        );
    }

    /// @dev First-deposit inflation resistance under the floating share.
    ///      An attacker seeds the empty vault with 1 share then donates super-token to the FM to
    ///      inflate price-per-share, aiming to round the victim's deposit to 0 shares. The
    ///      `_decimalsOffset() == 12` override (10**12 virtual shares) makes this infeasible: even a
    ///      donation ~10x the victim's deposit cannot push the previewed share count to 0. Asserted
    ///      at the `previewDeposit` level to isolate the rounding from the rebalance behaviour of
    ///      executing a deposit against a massively-inflated reserve.
    function test_firstDepositInflation_victimMintsNonZero(uint256 victimAmount) public {
        victimAmount = bound(victimAmount, 1e6, ONE_BILLION * 1e6);

        // Attacker seeds the empty vault with the smallest viable position: MIN_EXTERNAL_PULL
        // atoms (a smaller deposit cannot pre-fund the stream's GDA buffer on an empty reserve).
        _deposit(ALICE, _fundManager.MIN_EXTERNAL_PULL());

        // Attacker donates super-token to the FM, inflating NAV ~10x above the victim's deposit
        // (donation in 18-dec super-token terms; /SCALING_FACTOR=1e12 gives the underlying value).
        _dealUSDCx(address(_fundManager), (victimAmount + 1) * 1e12 * 10);

        // With the virtual-share offset the victim's deposit still previews to a non-zero amount.
        assertGt(_vault.previewDeposit(victimAmount), 0, "victim mints non-zero shares (virtual-share offset)");
    }

    /// @dev Custody hazard invariant (invariants.md A.2): the FM holds 0 underlying at rest
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

    /// @dev Withdraw is NOT bricked when the external's deposit-side gate is blocked
    ///      (`canDepositExternal() == false`) while withdrawals still work. The
    ///      `_rebalanceYieldAssets()` `deficit < 0` branch's pre-check skips the post-payout trim,
    ///      leaving the freed excess as above-target super-token slack in the reserve (D.3:
    ///      best-effort, gated on the deposit-side gate views).
    function test_withdraw_notBrickedByClosedDepositGate(uint256 amount, uint256 wPortion) public {
        amount = bound(amount, 2e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        // External: deposits gate-blocked for the FM; withdrawals continue. The trim's pre-check
        // honours this.
        _external.setCanReceiveShares(false);

        uint256 wAssets = bound(wPortion, 1e6, _vault.maxWithdraw(ALICE));
        vm.prank(ALICE);
        _vault.withdraw(wAssets, ALICE, ALICE);

        assertEq(_usdc.balanceOf(ALICE), wAssets, "withdraw not bricked by a closed deposit gate");
    }

    /// @dev F.2 under loss: for any holder and any `s <= maxRedeem(holder)`, `redeem` succeeds
    ///      and pays `previewRedeem(s)`. `simulateLoss` models the external position losing
    ///      principal.
    function test_redeem_serviceableUnderLoss(uint256 amount, uint256 lossPortion, uint256 sPortion) public {
        amount = bound(amount, 2e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        // External loses a fraction of its principal; strictly < extBal so the FM's position keeps
        // a positive value (loss regime, not the D.2 terminal-impairment pause).
        uint256 extBal = _usdc.balanceOf(address(_external));
        uint256 loss = bound(lossPortion, 1, extBal - 1);
        _external.simulateLoss(loss);

        uint256 maxR = _vault.maxRedeem(ALICE);
        if (maxR == 0) return;
        uint256 s = bound(sPortion, 1, maxR);

        uint256 expected = _vault.previewRedeem(s);
        uint256 balBefore = _usdc.balanceOf(ALICE);

        vm.prank(ALICE);
        uint256 assets = _vault.redeem(s, ALICE, ALICE);

        assertEq(assets, expected, "redeem(s<=maxR) pays previewRedeem(s)");
        assertEq(_usdc.balanceOf(ALICE) - balBefore, expected, "receiver got exactly previewRedeem");
        // A.2 preserved.
        assertEq(_usdc.balanceOf(address(_fundManager)), 0, "FM holds no idle underlying");
    }

    /// @dev F.2 under loss, withdraw leg: `a <= maxWithdraw(holder)` always pays exactly `a`.
    function test_withdraw_serviceableUnderLoss(uint256 amount, uint256 lossPortion, uint256 wPortion) public {
        amount = bound(amount, 2e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        uint256 extBal = _usdc.balanceOf(address(_external));
        uint256 loss = bound(lossPortion, 1, extBal - 1);
        _external.simulateLoss(loss);

        uint256 maxW = _vault.maxWithdraw(ALICE);
        if (maxW == 0) return;
        uint256 a = bound(wPortion, 1, maxW);

        uint256 balBefore = _usdc.balanceOf(ALICE);
        vm.prank(ALICE);
        _vault.withdraw(a, ALICE, ALICE);

        assertEq(_usdc.balanceOf(ALICE) - balBefore, a, "withdraw(a<=maxW) pays exactly a");
        assertEq(_usdc.balanceOf(address(_fundManager)), 0, "FM holds no idle underlying");
    }

    /// @dev The load-bearing case: redeem `maxR` under loss.
    ///      `redeem(maxR)` must succeed and pay `previewRedeem(maxR)`. The reserve slice
    ///      `scaledReserve * maxR / supply` bridges precisely the gap between `previewRedeem(maxR)`
    ///      (= NAV-ish) and the external position value (= NAV - scaledReserve - raw). Note `maxR` may
    ///      be a hair below `balanceOf` under loss because the NAV-share cap binds, so this is
    ///      not necessarily a *full* unit exit — the assertions reflect that.
    function test_redeem_atMaxRedeemUnderLoss(uint256 amount, uint256 lossPortion) public {
        amount = bound(amount, 2e6, ONE_BILLION * 1e6);
        _deposit(ALICE, amount);

        uint256 extBal = _usdc.balanceOf(address(_external));
        uint256 loss = bound(lossPortion, 1, extBal - 1);
        _external.simulateLoss(loss);

        uint256 maxR = _vault.maxRedeem(ALICE);
        if (maxR == 0) return;
        uint256 expected = _vault.previewRedeem(maxR);

        vm.prank(ALICE);
        uint256 assets = _vault.redeem(maxR, ALICE, ALICE);

        assertEq(assets, expected, "redeem(maxR) pays previewRedeem(maxR)");
        // A.2 preserved even at the cap.
        assertEq(_usdc.balanceOf(address(_fundManager)), 0, "FM holds no idle underlying");
    }

    /// @dev Positive characterisation of shares-proportional reserve sourcing (paired with the
    ///      known-limitation test `test_withdraw_lateEntrantAfterGain_brickedByNonCompliantExternal`).
    ///      A single-holder full exit under a non-compliant external has share fraction == unit
    ///      fraction == 1 (sole holder), so the post-payout deficit is ~0 and `_rebalanceYieldAssets()`
    ///      does not attempt the trim that would reach `EXTERNAL_VAULT.deposit`. The withdraw succeeds.
    function test_withdraw_singleHolderFullExit_notBrickedByNonCompliantExternal() public {
        _deposit(ALICE, DEFAULT_DEPOSIT);
        _external.setDepositReverts(true);

        uint256 wAssets = _vault.maxWithdraw(ALICE);
        uint256 balBefore = _usdc.balanceOf(ALICE);
        vm.prank(ALICE);
        _vault.withdraw(wAssets, ALICE, ALICE);

        assertEq(_usdc.balanceOf(ALICE) - balBefore, wAssets, "single-holder full exit not bricked");
        assertEq(_usdc.balanceOf(address(_fundManager)), 0, "FM holds no idle underlying");
    }

    /// @dev KNOWN LIMITATION: the best-effort trim trusts ERC-4626 compliance. A single-holder full
    ///      exit no longer reaches the trim path (paired positive test above), but a multi-holder
    ///      exit where the holder has a *higher* `units / share` than the global average leaves a
    ///      post-payout surplus, so the `_rebalanceYieldAssets()` `deficit < 0` branch tries to
    ///      redeposit. A non-compliant external that reverts `deposit` despite `maxDeposit > 0`
    ///      bricks the withdraw. Accepted; design.md security considerations require standard,
    ///      audited externals.
    ///
    ///      Setup: external gains after Alice's deposit, so Bob enters at a higher
    ///      price-per-share and ends up with a *higher* `units / share` than Alice (his shares
    ///      are "expensive", same units packed into fewer shares). Bob then partial-exits — the
    ///      surplus appears, the trim attempts `EXTERNAL_VAULT.deposit`, and the non-compliant
    ///      external reverts.
    function test_withdraw_lateEntrantAfterGain_brickedByNonCompliantExternal() public {
        // Alice deposits first into the empty vault.
        _deposit(ALICE, DEFAULT_DEPOSIT);

        // External gains so NAV drifts up; Bob then enters at a higher price-per-share, so he
        // receives fewer shares per underlying than Alice and ends up with a *higher* `units /
        // share` than her (units track principal, shares track NAV under the floating share).
        _external.simulateGain(DEFAULT_DEPOSIT / 2);
        _deposit(BOB, DEFAULT_DEPOSIT);

        // Non-compliant external: `deposit` reverts unconditionally while the gates still read
        // open, so the trim's pre-check does not skip it. Withdrawals from external still work.
        _external.setDepositReverts(true);

        // Bob partial-exits half his shares. His `units / share` exceeds the global average
        // (Alice drags it down), so his removal leaves a post-payout surplus (deficit < 0)
        // → trim → `EXTERNAL_VAULT.deposit` reverts → the redeem bricks.
        uint256 half = _vault.balanceOf(BOB) / 2;
        vm.prank(BOB);
        vm.expectRevert(bytes("MockMorphoVaultV2: deposit paused"));
        _vault.redeem(half, BOB, BOB);
    }

}
