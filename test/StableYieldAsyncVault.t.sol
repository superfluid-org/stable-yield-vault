// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { StableYieldVaultTestBase } from "./StableYieldVaultTestBase.t.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";
import { IERC7540Deposit } from "src/interfaces/vault/IERC7540Deposit.sol";
import { IERC7540Operator } from "src/interfaces/vault/IERC7540Operator.sol";
import { IERC7540Redeem } from "src/interfaces/vault/IERC7540Redeem.sol";
import { IERC7575 } from "src/interfaces/vault/IERC7575.sol";
import { IStableYieldAsyncVault } from "src/interfaces/vault/IStableYieldAsyncVault.sol";

contract StableYieldAsyncVaultTest is StableYieldVaultTestBase {

    using Math for uint256;

    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );
    event OperatorSet(address indexed controller, address indexed operator, bool approved);
    event EpochSettled(
        uint256 indexed epoch,
        uint256 totalAssets,
        uint256 assetsPerShare,
        uint256 totalDepositAssets,
        uint256 totalRedeemShares
    );
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    uint256 internal constant DEFAULT_DEPOSIT = 1000 * 1e6; // 1000 USDC
    uint256 internal constant USDCX_SEED = 100 ether; // Covers flow recalibration security deposits

    function setUp() public override {
        super.setUp();
        // Seed the FundManager with USDCx so any flow recalibration succeeds.
        // Amount kept small to minimize NAV inflation in FM-driven paths.
        _dealUSDCx(address(_fundManager), USDCX_SEED);
    }

    function _primeForDeposit(address user, uint256 amount) internal {
        _dealUSDC(user, amount);
        vm.prank(user);
        _usdc.approve(address(_vault), type(uint256).max);
    }

    function _requestDeposit(address user, uint256 amount) internal {
        vm.prank(user);
        _vault.requestDeposit(amount, user, user);
    }

    /// @dev Directly drive closeEpoch on the vault (bypasses FM totalAssets calculation).
    function _vaultCloseEpoch(uint256 totalAssetsReported) internal {
        vm.prank(address(_fundManager));
        _vault.onCloseEpoch(totalAssetsReported);
    }

    /// @dev Directly drive settleEpoch on the vault.
    function _vaultSettleEpoch() internal {
        vm.prank(address(_fundManager));
        _vault.onSettleEpoch();
    }

    /// @dev Drives settleEpoch + mimics the pool-unit grant that FM.settleEpoch would normally do.
    ///      Needed so subsequent claims (which call `onClaimDeposit` → `decreaseMemberUnits`) don't underflow.
    function _vaultSettleAndGrantUnits() internal {
        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();

        vm.prank(address(_fundManager));
        _vault.onSettleEpoch();

        if (snap.depositingAssets > 0) {
            uint256 units = snap.depositingAssets * _fundManager.UNIT_PER_ASSET_DEPOSITED();
            ISuperfluidPool pool = _fundManager.POOL(); // resolve before the prank is consumed
            vm.prank(address(_fundManager));
            pool.increaseMemberUnits(address(_fundManager), uint128(units));
        }
    }

    /// @dev Full deposit lifecycle for a single user. At rate=1e18, shares issued == assets deposited (in atoms).
    ///      Reports NAV matching current outstanding shares to keep the epoch rate at 1e18.
    function _completeDepositFlow(address user, uint256 amount) internal {
        _primeForDeposit(user, amount);
        _requestDeposit(user, amount);
        // Report NAV equal to current shares (in atoms) so rate stays 1e18;
        // for first deposit (supply=0), any non-zero value triggers the bootstrap branch.
        uint256 reported = _vault.totalSupply() == 0 ? amount : _vault.totalSupply();
        _vaultCloseEpoch(reported);
        _vaultSettleAndGrantUnits();
        vm.prank(user);
        _vault.deposit(amount, user);
    }

    function test_initialState() public view {
        vm.assertEq(address(_vault.FUND_MANAGER()), address(_fundManager));
        vm.assertEq(address(_vault.underlyingAsset()), address(_usdc));
        vm.assertEq(_vault.asset(), address(_usdc));
        vm.assertEq(_vault.share(), address(_vault));
        vm.assertEq(_vault.currentEpoch(), 1);
        vm.assertEq(_vault.totalPendingDepositAssets(), 0);
        vm.assertEq(_vault.totalPendingRedeemShares(), 0);
        vm.assertEq(_vault.totalClaimableRedeemAssets(), 0);
        vm.assertEq(_vault.totalAssets(), 0);
        vm.assertEq(_vault.totalSupply(), 0);
        vm.assertEq(_vault.name(), "Stable Yield Vault Share");
        vm.assertEq(_vault.symbol(), "SYVS");
        vm.assertEq(_vault.decimals(), 18);
    }

    function test_supportsInterface() public view {
        vm.assertTrue(_vault.supportsInterface(type(IERC7540Operator).interfaceId));
        vm.assertTrue(_vault.supportsInterface(type(IERC7575).interfaceId));
        vm.assertTrue(_vault.supportsInterface(type(IERC7540Deposit).interfaceId));
        vm.assertTrue(_vault.supportsInterface(type(IERC7540Redeem).interfaceId));
        vm.assertFalse(_vault.supportsInterface(bytes4(0xdeadbeef)));
    }

    function test_requestDeposit_happyPath() public {
        _primeForDeposit(ALICE, DEFAULT_DEPOSIT);
        uint256 aliceBalanceBefore = _usdc.balanceOf(ALICE);

        vm.expectEmit(true, true, true, true, address(_vault));
        emit DepositRequest(ALICE, ALICE, 0, ALICE, DEFAULT_DEPOSIT);

        vm.prank(ALICE);
        uint256 requestId = _vault.requestDeposit(DEFAULT_DEPOSIT, ALICE, ALICE);

        vm.assertEq(requestId, 0);
        vm.assertEq(_usdc.balanceOf(ALICE), aliceBalanceBefore - DEFAULT_DEPOSIT);
        vm.assertEq(_usdc.balanceOf(address(_vault)), DEFAULT_DEPOSIT);
        vm.assertEq(_vault.totalPendingDepositAssets(), DEFAULT_DEPOSIT);
        vm.assertEq(_vault.pendingDepositRequest(0, ALICE), DEFAULT_DEPOSIT);
        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), 0);
    }

    function test_requestDeposit_revertsOnZeroAssets() public {
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_PARAMETERS.selector);
        _vault.requestDeposit(0, ALICE, ALICE);
    }

    function test_requestDeposit_revertsOnInvalidCaller() public {
        _primeForDeposit(ALICE, DEFAULT_DEPOSIT);

        vm.prank(BOB);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_CALLER.selector);
        _vault.requestDeposit(DEFAULT_DEPOSIT, ALICE, ALICE);
    }

    function test_requestDeposit_revertsWhenEpochSettlementInProgress() public {
        _primeForDeposit(ALICE, DEFAULT_DEPOSIT);
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);

        _vaultCloseEpoch(DEFAULT_DEPOSIT); // snapshot now non-zero, not yet settled

        _primeForDeposit(BOB, DEFAULT_DEPOSIT);
        vm.prank(BOB);
        vm.expectRevert(IStableYieldAsyncVault.EPOCH_SETTLEMENT_IN_PROGRESS.selector);
        _vault.requestDeposit(DEFAULT_DEPOSIT, BOB, BOB);
    }

    function test_requestDeposit_accumulatesWithinSameEpoch() public {
        _primeForDeposit(ALICE, DEFAULT_DEPOSIT * 3);
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);

        vm.assertEq(_vault.pendingDepositRequest(0, ALICE), DEFAULT_DEPOSIT * 2);
        vm.assertEq(_vault.totalPendingDepositAssets(), DEFAULT_DEPOSIT * 2);
    }

    function test_requestDeposit_operatorCanDepositOnBehalf() public {
        _primeForDeposit(ALICE, DEFAULT_DEPOSIT);

        vm.prank(ALICE);
        _vault.setOperator(BOB, true);

        vm.prank(BOB);
        uint256 requestId = _vault.requestDeposit(DEFAULT_DEPOSIT, ALICE, ALICE);

        vm.assertEq(requestId, 0);
        vm.assertEq(_vault.pendingDepositRequest(0, ALICE), DEFAULT_DEPOSIT);
    }

    function test_requestRedeem_happyPath() public {
        _completeDepositFlow(ALICE, DEFAULT_DEPOSIT);

        uint256 aliceShares = _vault.balanceOf(ALICE);
        vm.assertEq(aliceShares, DEFAULT_DEPOSIT); // rate=1e18 => share atoms == asset atoms

        vm.expectEmit(true, true, true, true, address(_vault));
        emit RedeemRequest(ALICE, ALICE, 0, ALICE, aliceShares);

        vm.prank(ALICE);
        uint256 requestId = _vault.requestRedeem(aliceShares, ALICE, ALICE);

        vm.assertEq(requestId, 0);
        vm.assertEq(_vault.balanceOf(ALICE), 0);
        vm.assertEq(_vault.balanceOf(address(_vault)), aliceShares);
        vm.assertEq(_vault.totalPendingRedeemShares(), aliceShares);
        vm.assertEq(_vault.pendingRedeemRequest(0, ALICE), aliceShares);
    }

    function test_requestRedeem_revertsOnZeroShares() public {
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_PARAMETERS.selector);
        _vault.requestRedeem(0, ALICE, ALICE);
    }

    function test_requestRedeem_revertsOnMoreThanOwned() public {
        _completeDepositFlow(ALICE, DEFAULT_DEPOSIT);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_PARAMETERS.selector);
        _vault.requestRedeem(aliceShares + 1, ALICE, ALICE);
    }

    function test_requestRedeem_revertsOnInvalidCaller() public {
        _completeDepositFlow(ALICE, DEFAULT_DEPOSIT);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        vm.prank(BOB);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_CALLER.selector);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);
    }

    function test_requestRedeem_revertsWhenEpochSettlementInProgress() public {
        _completeDepositFlow(ALICE, DEFAULT_DEPOSIT);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        _vaultCloseEpoch(DEFAULT_DEPOSIT);

        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.EPOCH_SETTLEMENT_IN_PROGRESS.selector);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);
    }

    function test_closeEpoch_happyPath_firstEpochNoDeposits() public {
        uint256 reported = 1000e6;
        _vaultCloseEpoch(reported);

        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();
        vm.assertEq(snap.epoch, 1);
        vm.assertEq(snap.depositingAssets, 0);
        vm.assertEq(snap.redeemingShares, 0);
        vm.assertEq(snap.rate, 1e18); // zero supply => default bootstrap rate
        vm.assertEq(_vault.currentEpoch(), 2);
        vm.assertEq(_vault.totalAssets(), reported);
    }

    function test_closeEpoch_firstEpochWithDeposits() public {
        _primeForDeposit(ALICE, DEFAULT_DEPOSIT);
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        _vaultCloseEpoch(DEFAULT_DEPOSIT);

        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();
        vm.assertEq(snap.depositingAssets, DEFAULT_DEPOSIT);
        vm.assertEq(snap.rate, 1e18);
        vm.assertEq(_vault.totalPendingDepositAssets(), 0, "totalPending reset at close");
        vm.assertEq(_vault.currentEpoch(), 2);
    }

    function test_closeEpoch_computesRateFromEffectiveSupply() public {
        // Bootstrap: Alice holds DEFAULT_DEPOSIT shares at rate=1e18
        _completeDepositFlow(ALICE, DEFAULT_DEPOSIT);

        // NAV doubled -> rate should be 2e18
        _vaultCloseEpoch(2 * DEFAULT_DEPOSIT);
        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();
        vm.assertEq(snap.rate, 2e18);
    }

    function test_closeEpoch_revertsIfPreviousNotSettled() public {
        _vaultCloseEpoch(1000e6);

        vm.prank(address(_fundManager));
        vm.expectRevert(IStableYieldAsyncVault.PREVIOUS_EPOCH_NOT_SETTLED.selector);
        _vault.onCloseEpoch(1000e6);
    }

    function test_closeEpoch_revertsIfNotFundManager() public {
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_CALLER.selector);
        _vault.onCloseEpoch(1000e6);
    }

    function test_settleEpoch_revertsWhenNoEpochClosed() public {
        vm.prank(address(_fundManager));
        vm.expectRevert(IStableYieldAsyncVault.NO_EPOCH_TO_SETTLE.selector);
        _vault.onSettleEpoch();
    }

    function test_settleEpoch_revertsIfNotFundManager() public {
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_CALLER.selector);
        _vault.onSettleEpoch();
    }

    function test_settleEpoch_surplusPushedToFundManager() public {
        _primeForDeposit(ALICE, DEFAULT_DEPOSIT);
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        _vaultCloseEpoch(0);

        uint256 fmBalanceBefore = _usdc.balanceOf(address(_fundManager));

        vm.expectEmit(true, false, false, true, address(_vault));
        emit EpochSettled(1, DEFAULT_DEPOSIT, 1e18, DEFAULT_DEPOSIT, 0);

        _vaultSettleEpoch();

        vm.assertEq(_usdc.balanceOf(address(_fundManager)), fmBalanceBefore + DEFAULT_DEPOSIT);
        vm.assertEq(_usdc.balanceOf(address(_vault)), 0);
        vm.assertEq(_vault.totalClaimableRedeemAssets(), 0);
        vm.assertTrue(_vault.isEpochSettled(1));

        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();
        vm.assertEq(snap.epoch, 0, "snapshot cleared");
    }

    function test_settleEpoch_deficitPulledFromFundManager() public {
        // First cycle: Alice deposits and claims shares
        _completeDepositFlow(ALICE, DEFAULT_DEPOSIT);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        // Second cycle: Alice redeems; no new deposits
        vm.prank(ALICE);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);

        uint256 fmStart = _usdc.balanceOf(address(_fundManager));
        vm.assertGe(fmStart, DEFAULT_DEPOSIT, "FM holds surplus from prior flow");

        _vaultCloseEpoch(DEFAULT_DEPOSIT);
        _vaultSettleEpoch();

        vm.assertEq(_vault.totalClaimableRedeemAssets(), DEFAULT_DEPOSIT);
        vm.assertEq(_usdc.balanceOf(address(_vault)), DEFAULT_DEPOSIT);
        vm.assertEq(_usdc.balanceOf(address(_fundManager)), fmStart - DEFAULT_DEPOSIT);
    }

    function test_settleEpoch_unclaimedDepositShares_updatedForEffectiveSupply() public {
        // First deposit and settle but don't claim
        _primeForDeposit(ALICE, DEFAULT_DEPOSIT);
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        _vaultCloseEpoch(_vault.totalSupply() == 0 ? DEFAULT_DEPOSIT : _vault.totalSupply());
        _vaultSettleAndGrantUnits();

        // Alice has claimable shares but not yet claimed; totalSupply is still 0
        vm.assertEq(_vault.totalSupply(), 0);
        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), DEFAULT_DEPOSIT);

        // Close a new epoch; effective supply should treat Alice's un-minted shares as owed,
        // so rate at same reported NAV should match
        _vaultCloseEpoch(DEFAULT_DEPOSIT);
        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();
        // effectiveSupply = 0 (ts) + DEFAULT_DEPOSIT (unclaimedDeposit) - 0 = DEFAULT_DEPOSIT
        // rate = DEFAULT_DEPOSIT * 1e18 / DEFAULT_DEPOSIT = 1e18
        vm.assertEq(snap.rate, 1e18);
    }

    function test_claimDeposit_happyPath() public {
        _primeForDeposit(ALICE, DEFAULT_DEPOSIT);
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        _vaultCloseEpoch(_vault.totalSupply() == 0 ? DEFAULT_DEPOSIT : _vault.totalSupply());
        _vaultSettleAndGrantUnits();

        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), DEFAULT_DEPOSIT);
        vm.assertEq(_vault.maxDeposit(ALICE), DEFAULT_DEPOSIT);
        vm.assertEq(_vault.maxMint(ALICE), DEFAULT_DEPOSIT);

        vm.prank(ALICE);
        uint256 shares = _vault.deposit(DEFAULT_DEPOSIT, ALICE);

        vm.assertEq(shares, DEFAULT_DEPOSIT); // rate=1e18
        vm.assertEq(_vault.balanceOf(ALICE), DEFAULT_DEPOSIT);
        vm.assertEq(_vault.totalSupply(), DEFAULT_DEPOSIT);
        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), 0);
    }

    function test_claimDeposit_partial() public {
        _primeForDeposit(ALICE, DEFAULT_DEPOSIT);
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        _vaultCloseEpoch(_vault.totalSupply() == 0 ? DEFAULT_DEPOSIT : _vault.totalSupply());
        _vaultSettleAndGrantUnits();

        uint256 half = DEFAULT_DEPOSIT / 2;
        vm.prank(ALICE);
        uint256 shares = _vault.deposit(half, ALICE);

        vm.assertEq(shares, half);
        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), DEFAULT_DEPOSIT - half);
        vm.assertEq(_vault.balanceOf(ALICE), half);
    }

    function test_claimDeposit_revertsWithNothingToClaim() public {
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.NOTHING_TO_CLAIM.selector);
        _vault.deposit(1, ALICE);
    }

    function test_claimDeposit_revertsOnInvalidController() public {
        _primeForDeposit(ALICE, DEFAULT_DEPOSIT);
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        _vaultCloseEpoch(_vault.totalSupply() == 0 ? DEFAULT_DEPOSIT : _vault.totalSupply());
        _vaultSettleAndGrantUnits();

        vm.prank(BOB);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_CALLER.selector);
        _vault.deposit(DEFAULT_DEPOSIT, BOB, ALICE);
    }

    function test_mint_happyPath() public {
        _primeForDeposit(ALICE, DEFAULT_DEPOSIT);
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);
        _vaultCloseEpoch(_vault.totalSupply() == 0 ? DEFAULT_DEPOSIT : _vault.totalSupply());
        _vaultSettleAndGrantUnits();

        vm.prank(ALICE);
        uint256 assets = _vault.mint(DEFAULT_DEPOSIT, ALICE);

        vm.assertEq(assets, DEFAULT_DEPOSIT);
        vm.assertEq(_vault.balanceOf(ALICE), DEFAULT_DEPOSIT);
    }

    function test_mint_revertsOnZero() public {
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_PARAMETERS.selector);
        _vault.mint(0, ALICE);
    }

    function test_redeem_happyPath() public {
        _completeDepositFlow(ALICE, DEFAULT_DEPOSIT);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        vm.prank(ALICE);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);
        _vaultCloseEpoch(_vault.totalSupply() == 0 ? DEFAULT_DEPOSIT : _vault.totalSupply());
        _vaultSettleAndGrantUnits();

        vm.assertEq(_vault.claimableRedeemRequest(0, ALICE), aliceShares);
        vm.assertEq(_vault.maxRedeem(ALICE), aliceShares);
        vm.assertEq(_vault.maxWithdraw(ALICE), DEFAULT_DEPOSIT);

        vm.prank(ALICE);
        uint256 assets = _vault.redeem(aliceShares, ALICE, ALICE);

        vm.assertEq(assets, DEFAULT_DEPOSIT);
        vm.assertEq(_usdc.balanceOf(ALICE), DEFAULT_DEPOSIT);
        vm.assertEq(_vault.balanceOf(address(_vault)), 0, "held shares burned");
        vm.assertEq(_vault.totalClaimableRedeemAssets(), 0);
    }

    function test_withdraw_happyPath() public {
        _completeDepositFlow(ALICE, DEFAULT_DEPOSIT);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        vm.prank(ALICE);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);
        _vaultCloseEpoch(_vault.totalSupply() == 0 ? DEFAULT_DEPOSIT : _vault.totalSupply());
        _vaultSettleAndGrantUnits();

        vm.prank(ALICE);
        uint256 shares = _vault.withdraw(DEFAULT_DEPOSIT, ALICE, ALICE);

        vm.assertEq(shares, aliceShares);
        vm.assertEq(_usdc.balanceOf(ALICE), DEFAULT_DEPOSIT);
    }

    function test_redeem_revertsOnInvalidController() public {
        _completeDepositFlow(ALICE, DEFAULT_DEPOSIT);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        vm.prank(ALICE);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);
        _vaultCloseEpoch(_vault.totalSupply() == 0 ? DEFAULT_DEPOSIT : _vault.totalSupply());
        _vaultSettleAndGrantUnits();

        vm.prank(BOB);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_CALLER.selector);
        _vault.redeem(aliceShares, BOB, ALICE);
    }

    function test_redeem_revertsWithNothingToClaim() public {
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.NOTHING_TO_CLAIM.selector);
        _vault.redeem(1, ALICE, ALICE);
    }

    function test_redeem_revertsOnZero() public {
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_PARAMETERS.selector);
        _vault.redeem(0, ALICE, ALICE);
    }

    function test_setOperator() public {
        vm.assertFalse(_vault.isOperator(ALICE, BOB));

        vm.expectEmit(true, true, false, true, address(_vault));
        emit OperatorSet(ALICE, BOB, true);

        vm.prank(ALICE);
        bool ok = _vault.setOperator(BOB, true);
        vm.assertTrue(ok);
        vm.assertTrue(_vault.isOperator(ALICE, BOB));

        vm.prank(ALICE);
        _vault.setOperator(BOB, false);
        vm.assertFalse(_vault.isOperator(ALICE, BOB));
    }

    function test_transfer_reverts() public {
        vm.expectRevert(IStableYieldAsyncVault.SHARES_NON_TRANSFERABLE.selector);
        _vault.transfer(BOB, 1);
    }

    function test_transferFrom_reverts() public {
        vm.expectRevert(IStableYieldAsyncVault.SHARES_NON_TRANSFERABLE.selector);
        _vault.transferFrom(ALICE, BOB, 1);
    }

    function test_previewDeposit_reverts() public {
        vm.expectRevert(IStableYieldAsyncVault.NOT_SUPPORTED_BY_ASYNC_VAULT.selector);
        _vault.previewDeposit(1);
    }

    function test_previewMint_reverts() public {
        vm.expectRevert(IStableYieldAsyncVault.NOT_SUPPORTED_BY_ASYNC_VAULT.selector);
        _vault.previewMint(1);
    }

    function test_previewRedeem_reverts() public {
        vm.expectRevert(IStableYieldAsyncVault.NOT_SUPPORTED_BY_ASYNC_VAULT.selector);
        _vault.previewRedeem(1);
    }

    function test_previewWithdraw_reverts() public {
        vm.expectRevert(IStableYieldAsyncVault.NOT_SUPPORTED_BY_ASYNC_VAULT.selector);
        _vault.previewWithdraw(1);
    }

    function test_pendingAndClaimable_viewsFlipOnSettlement() public {
        _primeForDeposit(ALICE, DEFAULT_DEPOSIT);
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);

        // Before settlement: pending > 0, claimable = 0
        vm.assertEq(_vault.pendingDepositRequest(0, ALICE), DEFAULT_DEPOSIT);
        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), 0);

        _vaultCloseEpoch(_vault.totalSupply() == 0 ? DEFAULT_DEPOSIT : _vault.totalSupply());
        _vaultSettleAndGrantUnits();

        // After settlement: the view mapping flips (even without interaction)
        vm.assertEq(_vault.pendingDepositRequest(0, ALICE), 0);
        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), DEFAULT_DEPOSIT);
    }

    function test_convertToShares_bootstrap() public view {
        vm.assertEq(_vault.convertToShares(1e6), 1e6); // rate=1e18
    }

    function test_convertToAssets_bootstrap() public view {
        vm.assertEq(_vault.convertToAssets(1e18), 1e18);
    }

    function test_convertToShares_afterSettledEpoch() public {
        _completeDepositFlow(ALICE, DEFAULT_DEPOSIT);
        // Close/settle a second epoch reporting NAV == outstanding shares so rate stays 1e18
        _vaultCloseEpoch(_vault.totalSupply());
        _vaultSettleEpoch();

        vm.assertEq(_vault.convertToShares(1e6), 1e6);
    }

    function test_endToEnd_twoUsers_depositAndRedeem() public {
        _completeDepositFlow(ALICE, DEFAULT_DEPOSIT);
        _completeDepositFlow(BOB, DEFAULT_DEPOSIT * 2);

        uint256 aliceShares = _vault.balanceOf(ALICE);
        uint256 bobShares = _vault.balanceOf(BOB);
        vm.assertEq(aliceShares * 2, bobShares, "Bob has 2x Alice's shares");

        // Both request redeem in the same epoch
        vm.prank(ALICE);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);
        vm.prank(BOB);
        _vault.requestRedeem(bobShares, BOB, BOB);

        _vaultCloseEpoch(_vault.totalSupply() == 0 ? DEFAULT_DEPOSIT : _vault.totalSupply());
        _vaultSettleAndGrantUnits();

        vm.prank(ALICE);
        _vault.redeem(aliceShares, ALICE, ALICE);
        vm.prank(BOB);
        _vault.redeem(bobShares, BOB, BOB);

        vm.assertEq(_usdc.balanceOf(ALICE), DEFAULT_DEPOSIT);
        vm.assertEq(_usdc.balanceOf(BOB), DEFAULT_DEPOSIT * 2);
        vm.assertEq(_vault.totalSupply(), 0);
        vm.assertEq(_vault.totalClaimableRedeemAssets(), 0);
    }

}
