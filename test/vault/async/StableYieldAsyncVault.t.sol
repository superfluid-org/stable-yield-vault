// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { AsyncVaultTestBase } from "./AsyncVaultTestBase.t.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";
import { IERC7540Deposit } from "src/interfaces/vault/async/IERC7540Deposit.sol";
import { IERC7540Operator } from "src/interfaces/vault/async/IERC7540Operator.sol";
import { IERC7540Redeem } from "src/interfaces/vault/async/IERC7540Redeem.sol";
import { IERC7575 } from "src/interfaces/vault/async/IERC7575.sol";
import { IStableYieldAsyncVault } from "src/interfaces/vault/async/IStableYieldAsyncVault.sol";

contract StableYieldAsyncVaultTest is AsyncVaultTestBase {

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

    /// @dev Mirrors StableYieldAsyncVault.VIRTUAL_SHARES (virtual supply offset in the epoch rate).
    uint256 internal constant VIRTUAL_SHARES = 1e12;
    /// @dev Share atoms minted per asset atom at the bootstrap rate (18-dec shares on a 6-dec asset).
    uint256 internal constant SHARE_SCALE = 1e12;
    /// @dev Empty-vault epoch rate: (0 + 1) * 1e18 / (0 + VIRTUAL_SHARES).
    uint256 internal constant BOOTSTRAP_RATE = 1e6;

    function setUp() public override {
        super.setUp();
        // Seed the FundManager with USDCx so any flow recalibration succeeds.
        // Amount kept small to minimize NAV inflation in FM-driven paths.
        _dealUSDCx(address(_fundManager), USDCX_SEED);
    }

    function _prepareForDeposit(address user, uint256 amount) internal {
        _dealUSDC(user, amount);
        vm.prank(user);
        _usdc.approve(address(_vault), type(uint256).max);
    }

    function _requestDeposit(address user, uint256 amount) internal {
        vm.prank(user);
        _vault.requestDeposit(amount, user, user);
    }

    // NOTE: `_vaultCloseEpoch`, `_vaultSettleEpoch` and `_vaultSettleAndGrantUnits` live in
    // {AsyncVaultTestBase} (shared with the EIP-2771 / Permit2 / macro suites).

    /// @dev Full deposit lifecycle for a single user. At the bootstrap rate, shares == assets * SHARE_SCALE.
    ///      Reports NAV = totalSupply / SHARE_SCALE — the assets backing the outstanding shares — which
    ///      keeps the epoch rate at exactly BOOTSTRAP_RATE: the +1 virtual asset and the +VIRTUAL_SHARES
    ///      virtual supply cancel ((nav + 1) * 1e18 / (nav * SHARE_SCALE + VIRTUAL_SHARES) = BOOTSTRAP_RATE).
    function _completeDepositFlow(address user, uint256 amount) internal {
        _prepareForDeposit(user, amount);
        _requestDeposit(user, amount);
        _vaultCloseEpoch(_vault.totalSupply() / SHARE_SCALE);
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
        vm.assertEq(_vault.name(), SHARE_NAME);
        vm.assertEq(_vault.symbol(), SHARE_SYMBOL);
        vm.assertEq(_vault.decimals(), 18);
    }

    function test_supportsInterface() public view {
        vm.assertTrue(_vault.supportsInterface(type(IERC7540Operator).interfaceId));
        vm.assertTrue(_vault.supportsInterface(type(IERC7575).interfaceId));
        vm.assertTrue(_vault.supportsInterface(type(IERC7540Deposit).interfaceId));
        vm.assertTrue(_vault.supportsInterface(type(IERC7540Redeem).interfaceId));
        vm.assertFalse(_vault.supportsInterface(bytes4(0xdeadbeef)));
    }

    //      ____                        _ __          ______          __
    //     / __ \___  ____  ____  _____(_) /______   /_  __/__  _____/ /______
    //    / / / / _ \/ __ \/ __ \/ ___/ / __/ ___/    / / / _ \/ ___/ __/ ___/
    //   / /_/ /  __/ /_/ / /_/ (__  ) / /_(__  )    / / /  __(__  ) /_(__  )
    //  /_____/\___/ .___/\____/____/_/\__/____/    /_/  \___/____/\__/____/
    //            /_/

    function test_requestDeposit(uint256 assetAmount) public {
        assetAmount = bound(assetAmount, 1, ONE_BILLION * 1e6);

        _prepareForDeposit(ALICE, assetAmount);
        uint256 aliceBalanceBefore = _usdc.balanceOf(ALICE);

        vm.expectEmit(true, true, true, true, address(_vault));
        emit DepositRequest(ALICE, ALICE, 0, ALICE, assetAmount);

        vm.prank(ALICE);
        uint256 requestId = _vault.requestDeposit(assetAmount, ALICE, ALICE);

        vm.assertEq(requestId, 0);
        vm.assertEq(_usdc.balanceOf(ALICE), aliceBalanceBefore - assetAmount);
        vm.assertEq(_usdc.balanceOf(address(_vault)), assetAmount);
        vm.assertEq(_vault.totalPendingDepositAssets(), assetAmount);
        vm.assertEq(_vault.pendingDepositRequest(0, ALICE), assetAmount);
        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), 0);
    }

    function test_requestDeposit_revertsOnZeroAssets() public {
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_PARAMETERS.selector);
        _vault.requestDeposit(0, ALICE, ALICE);
    }

    function test_requestDeposit_revertsOnInvalidCaller() public {
        _prepareForDeposit(ALICE, DEFAULT_DEPOSIT);

        vm.prank(BOB);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_CALLER.selector);
        _vault.requestDeposit(DEFAULT_DEPOSIT, ALICE, ALICE);
    }

    function test_requestDeposit_revertsWhenEpochSettlementInProgress() public {
        _prepareForDeposit(ALICE, DEFAULT_DEPOSIT);
        _requestDeposit(ALICE, DEFAULT_DEPOSIT);

        _vaultCloseEpoch(DEFAULT_DEPOSIT); // snapshot now non-zero, not yet settled

        _prepareForDeposit(BOB, DEFAULT_DEPOSIT);
        vm.prank(BOB);
        vm.expectRevert(IStableYieldAsyncVault.EPOCH_SETTLEMENT_IN_PROGRESS.selector);
        _vault.requestDeposit(DEFAULT_DEPOSIT, BOB, BOB);
    }

    function test_requestDeposit_accumulatesWithinSameEpoch(uint256 assetAmount1, uint256 assetAmount2) public {
        assetAmount1 = bound(assetAmount1, 1, ONE_BILLION * 1e6);
        assetAmount2 = bound(assetAmount2, 1, ONE_BILLION * 1e6);

        _prepareForDeposit(ALICE, assetAmount1 + assetAmount2);
        _requestDeposit(ALICE, assetAmount1);
        _requestDeposit(ALICE, assetAmount2);

        vm.assertEq(_vault.pendingDepositRequest(0, ALICE), assetAmount1 + assetAmount2);
        vm.assertEq(_vault.totalPendingDepositAssets(), assetAmount1 + assetAmount2);
    }

    function test_requestDeposit_operatorCanRequestDepositOnBehalf(uint256 assetAmount) public {
        assetAmount = bound(assetAmount, 1, ONE_BILLION * 1e6);

        _prepareForDeposit(ALICE, assetAmount);

        vm.prank(ALICE);
        _vault.setOperator(BOB, true);

        vm.prank(BOB);
        uint256 requestId = _vault.requestDeposit(assetAmount, ALICE, ALICE);

        vm.assertEq(requestId, 0);
        vm.assertEq(_vault.pendingDepositRequest(0, ALICE), assetAmount);
    }

    //      ____           __                            ______          __
    //     / __ \___  ____/ /__  ___  ____ ___  _____   /_  __/__  _____/ /______
    //    / /_/ / _ \/ __  / _ \/ _ \/ __ `__ \/ ___/    / / / _ \/ ___/ __/ ___/
    //   / _, _/  __/ /_/ /  __/  __/ / / / / (__  )    / / /  __(__  ) /_(__  )
    //  /_/ |_|\___/\__,_/\___/\___/_/ /_/ /_/____/    /_/  \___/____/\__/____/

    function test_requestRedeem(uint256 assetAmount) public {
        assetAmount = bound(assetAmount, 1, ONE_BILLION * 1e6);

        _completeDepositFlow(ALICE, assetAmount);

        uint256 aliceShares = _vault.balanceOf(ALICE);
        vm.assertEq(aliceShares, assetAmount * SHARE_SCALE); // bootstrap rate => SHARE_SCALE share atoms per asset atom

        vm.expectEmit(true, true, true, true, address(_vault));
        emit RedeemRequest(ALICE, ALICE, 0, ALICE, aliceShares);

        vm.prank(ALICE);
        uint256 requestId = _vault.requestRedeem(aliceShares, ALICE, ALICE);

        vm.assertEq(requestId, 0);
        vm.assertEq(_vault.balanceOf(ALICE), 0);
        vm.assertEq(_vault.balanceOf(address(_vault)), aliceShares);
        vm.assertEq(_vault.totalPendingRedeemShares(), aliceShares);
        vm.assertEq(_vault.pendingRedeemRequest(0, ALICE), aliceShares);
        vm.assertEq(_vault.claimableRedeemRequest(0, ALICE), 0);
    }

    function test_requestRedeem_revertsOnZeroShares() public {
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_PARAMETERS.selector);
        _vault.requestRedeem(0, ALICE, ALICE);
    }

    function test_requestRedeem_revertsOnMoreThanOwned(uint256 assetAmount, uint256 excessShares) public {
        assetAmount = bound(assetAmount, 1, ONE_BILLION * 1e6);
        excessShares = bound(excessShares, 1, ONE_BILLION * 1e6);

        _completeDepositFlow(ALICE, assetAmount);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_PARAMETERS.selector);
        _vault.requestRedeem(aliceShares + excessShares, ALICE, ALICE);
    }

    function test_requestRedeem_revertsOnInvalidCaller(uint256 assetAmount, address invalidCaller) public {
        assetAmount = bound(assetAmount, 1, ONE_BILLION * 1e6);
        vm.assume(invalidCaller != ALICE);

        _completeDepositFlow(ALICE, assetAmount);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        vm.prank(invalidCaller);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_CALLER.selector);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);
    }

    function test_requestRedeem_revertsWhenEpochSettlementInProgress(uint256 assetAmount) public {
        assetAmount = bound(assetAmount, 1, ONE_BILLION * 1e6);

        _completeDepositFlow(ALICE, assetAmount);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        _vaultCloseEpoch(0);

        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.EPOCH_SETTLEMENT_IN_PROGRESS.selector);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);
    }

    //      ______                 __       _____      __  __  __                          __
    //     / ____/___  ____  _____/ /_     / ___/___  / /_/ /_/ /__  ____ ___  ___  ____  / /_
    //    / __/ / __ \/ __ \/ ___/ __ \    \__ \/ _ \/ __/ __/ / _ \/ __ `__ \/ _ \/ __ \/ __/
    //   / /___/ /_/ / /_/ / /__/ / / /   ___/ /  __/ /_/ /_/ /  __/ / / / / /  __/ / / / /_
    //  /_____/ .___/\____/\___/_/ /_/   /____/\___/\__/\__/_/\___/_/ /_/ /_/\___/_/ /_/\__/
    //       /_/

    function test_onCloseEpoch_firstEpochNoDeposits() public {
        uint256 reported = 0;
        _vaultCloseEpoch(reported);

        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();
        vm.assertEq(snap.epoch, 1);
        vm.assertEq(snap.depositingAssets, 0);
        vm.assertEq(snap.redeemingShares, 0);
        vm.assertEq(snap.rate, BOOTSTRAP_RATE); // zero supply => virtual-shares bootstrap rate
        vm.assertEq(_vault.currentEpoch(), 2);
        vm.assertEq(_vault.totalAssets(), reported);
    }

    function test_onCloseEpoch_firstEpochWithDeposits(uint256 assetAmount) public {
        assetAmount = bound(assetAmount, 1, ONE_BILLION * 1e6);

        _prepareForDeposit(ALICE, assetAmount);
        _requestDeposit(ALICE, assetAmount);
        _vaultCloseEpoch(0);

        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();
        vm.assertEq(snap.depositingAssets, assetAmount);
        vm.assertEq(snap.rate, BOOTSTRAP_RATE);
        vm.assertEq(_vault.totalPendingDepositAssets(), 0, "totalPending reset at close");
        vm.assertEq(_vault.currentEpoch(), 2);
    }

    function test_onCloseEpoch_computesRateFromEffectiveSupply(uint256 assetAmount) public {
        assetAmount = bound(assetAmount, 1, ONE_BILLION * 1e6);

        // Bootstrap: Alice holds assetAmount * SHARE_SCALE shares at the bootstrap rate
        _completeDepositFlow(ALICE, assetAmount);

        // NAV doubled -> rate doubles, modulo the virtual offsets (+1 asset, +VIRTUAL_SHARES supply)
        _vaultCloseEpoch(2 * assetAmount);
        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();
        uint256 expectedRate = (2 * assetAmount + 1).mulDiv(1e18, assetAmount * SHARE_SCALE + VIRTUAL_SHARES);
        vm.assertEq(snap.rate, expectedRate);
        // For a supply of 1 USDC or more the virtual dilution is negligible: rate ~= 2x bootstrap
        if (assetAmount >= 1e6) {
            vm.assertApproxEqRel(snap.rate, 2 * BOOTSTRAP_RATE, 0.0001e18);
        }
    }

    function test_onCloseEpoch_revertsIfPreviousNotSettled(uint256 reportedNAV1, uint256 reportedNAV2) public {
        reportedNAV1 = bound(reportedNAV1, 1, ONE_BILLION * 1e6);
        reportedNAV2 = bound(reportedNAV2, 1, ONE_BILLION * 1e6);

        _vaultCloseEpoch(reportedNAV1);

        vm.prank(address(_fundManager));
        vm.expectRevert(IStableYieldAsyncVault.PREVIOUS_EPOCH_NOT_SETTLED.selector);
        _vault.onCloseEpoch(reportedNAV2);
    }

    function test_onCloseEpoch_revertsIfNotFundManager(uint256 reportedNAV, address nonFundManager) public {
        reportedNAV = bound(reportedNAV, 1, ONE_BILLION * 1e6);
        vm.assume(nonFundManager != address(_fundManager));

        vm.prank(nonFundManager);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_CALLER.selector);
        _vault.onCloseEpoch(reportedNAV);
    }

    function test_onSettleEpoch_revertsWhenNoEpochClosed() public {
        vm.prank(address(_fundManager));
        vm.expectRevert(IStableYieldAsyncVault.NO_EPOCH_TO_SETTLE.selector);
        _vault.onSettleEpoch();
    }

    function test_onSettleEpoch_revertsIfNotFundManager(address nonFundManager) public {
        vm.assume(nonFundManager != address(_fundManager));

        vm.prank(nonFundManager);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_CALLER.selector);
        _vault.onSettleEpoch();
    }

    function test_onSettleEpoch_surplusPushedToFundManager(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, ONE_BILLION * 1e6);

        _prepareForDeposit(ALICE, depositAmount);
        _requestDeposit(ALICE, depositAmount);
        _vaultCloseEpoch(0);

        uint256 fmBalanceBefore = _usdc.balanceOf(address(_fundManager));

        vm.expectEmit(true, false, false, true, address(_vault));
        emit EpochSettled(1, depositAmount, BOOTSTRAP_RATE, depositAmount, 0);

        _vaultSettleEpoch();

        vm.assertEq(_usdc.balanceOf(address(_fundManager)), fmBalanceBefore + depositAmount);
        vm.assertEq(_usdc.balanceOf(address(_vault)), 0);
        vm.assertEq(_vault.totalClaimableRedeemAssets(), 0);
        vm.assertTrue(_vault.isEpochSettled(1));

        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();
        vm.assertEq(snap.epoch, 0, "snapshot cleared");
    }

    function test_onSettleEpoch_deficitPulledFromFundManager(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, ONE_BILLION * 1e6);

        // First cycle: Alice deposits and claims shares
        _completeDepositFlow(ALICE, depositAmount);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        // Second cycle: Alice redeems; no new deposits
        vm.prank(ALICE);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);

        uint256 fmStart = _usdc.balanceOf(address(_fundManager));
        vm.assertGe(fmStart, depositAmount, "FM holds surplus from prior flow");

        _vaultCloseEpoch(depositAmount);
        _vaultSettleEpoch();

        vm.assertEq(_vault.totalClaimableRedeemAssets(), depositAmount);
        vm.assertEq(_usdc.balanceOf(address(_vault)), depositAmount);
        vm.assertEq(_usdc.balanceOf(address(_fundManager)), fmStart - depositAmount);
    }

    function test_onSettleEpoch_unclaimedDepositShares_updatedForEffectiveSupply(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, ONE_BILLION * 1e6);

        // First deposit and settle but don't claim
        _prepareForDeposit(ALICE, depositAmount);
        _requestDeposit(ALICE, depositAmount);
        _vaultCloseEpoch(0);
        _vaultSettleAndGrantUnits();

        // Alice has claimable shares but not yet claimed; totalSupply is still 0
        vm.assertEq(_vault.totalSupply(), 0);
        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), depositAmount);

        // Close a new epoch; effective supply should treat Alice's un-minted shares as owed,
        // so rate at same reported NAV should match
        _vaultCloseEpoch(depositAmount);
        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();
        // effectiveSupply = 0 (ts) + depositAmount * SHARE_SCALE (unclaimedDeposit) - 0
        // rate = (depositAmount + 1) * 1e18 / (depositAmount * SHARE_SCALE + VIRTUAL_SHARES)
        //      = BOOTSTRAP_RATE exactly (the +1 and +VIRTUAL_SHARES cancel)
        vm.assertEq(snap.rate, BOOTSTRAP_RATE);
    }

    //     ________      _              ____                        _ __     ______          __
    //    / ____/ /___ _(_)___ ___     / __ \___  ____  ____  _____(_) /_   /_  __/__  _____/ /______
    //   / /   / / __ `/ / __ `__ \   / / / / _ \/ __ \/ __ \/ ___/ / __/    / / / _ \/ ___/ __/ ___/
    //  / /___/ / /_/ / / / / / / /  / /_/ /  __/ /_/ / /_/ (__  ) / /_     / / /  __(__  ) /_(__  )
    //  \____/_/\__,_/_/_/ /_/ /_/  /_____/\___/ .___/\____/____/_/\__/    /_/  \___/____/\__/____/
    //                                        /_/

    function test_claimDeposit(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, ONE_BILLION * 1e6);

        _prepareForDeposit(ALICE, depositAmount);
        _requestDeposit(ALICE, depositAmount);
        _vaultCloseEpoch(0);
        _vaultSettleAndGrantUnits();

        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), depositAmount);
        vm.assertEq(_vault.maxDeposit(ALICE), depositAmount);
        vm.assertEq(_vault.maxMint(ALICE), depositAmount * SHARE_SCALE);

        vm.prank(ALICE);
        uint256 shares = _vault.deposit(depositAmount, ALICE);

        vm.assertEq(shares, depositAmount * SHARE_SCALE); // bootstrap rate
        vm.assertEq(_vault.balanceOf(ALICE), depositAmount * SHARE_SCALE);
        vm.assertEq(_vault.totalSupply(), depositAmount * SHARE_SCALE);
        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), 0);
    }

    function test_claimDeposit_partial(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 2, ONE_BILLION * 1e6);

        _prepareForDeposit(ALICE, depositAmount);
        _requestDeposit(ALICE, depositAmount);
        _vaultCloseEpoch(0);
        _vaultSettleAndGrantUnits();

        uint256 half = depositAmount / 2;
        vm.prank(ALICE);
        uint256 shares = _vault.deposit(half, ALICE);

        vm.assertEq(shares, half * SHARE_SCALE);
        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), depositAmount - half);
        vm.assertEq(_vault.balanceOf(ALICE), half * SHARE_SCALE);
    }

    function test_claimDeposit_revertsWithNothingToClaim(uint256 claimAmount) public {
        claimAmount = bound(claimAmount, 2, ONE_BILLION * 1e6);

        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.NOTHING_TO_CLAIM.selector);
        _vault.deposit(claimAmount, ALICE);
    }

    function test_claimDeposit_revertsOnInvalidController(uint256 depositAmount, address invalidController) public {
        depositAmount = bound(depositAmount, 2, ONE_BILLION * 1e6);
        vm.assume(invalidController != ALICE);

        _prepareForDeposit(ALICE, depositAmount);
        _requestDeposit(ALICE, depositAmount);
        _vaultCloseEpoch(0);
        _vaultSettleAndGrantUnits();

        vm.prank(invalidController);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_CALLER.selector);
        _vault.deposit(depositAmount, invalidController, ALICE);
    }

    function test_mint(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 2, ONE_BILLION * 1e6);

        _prepareForDeposit(ALICE, depositAmount);
        _requestDeposit(ALICE, depositAmount);
        _vaultCloseEpoch(0);
        _vaultSettleAndGrantUnits();

        uint256 sharesToMint = depositAmount * SHARE_SCALE;
        vm.prank(ALICE);
        uint256 assets = _vault.mint(sharesToMint, ALICE);

        vm.assertEq(assets, depositAmount);
        vm.assertEq(_vault.balanceOf(ALICE), sharesToMint);
    }

    function test_mint_revertsOnZero() public {
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_PARAMETERS.selector);
        _vault.mint(0, ALICE);
    }

    function test_deposit_revertsOnZeroAssets() public {
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_PARAMETERS.selector);
        _vault.deposit(0, ALICE);
    }

    function test_deposit_operatorClaimsOnBehalf(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, ONE_BILLION * 1e6);

        _prepareForDeposit(ALICE, depositAmount);
        _requestDeposit(ALICE, depositAmount);
        _vaultCloseEpoch(0);
        _vaultSettleAndGrantUnits();

        vm.prank(ALICE);
        _vault.setOperator(BOB, true);

        vm.prank(BOB);
        uint256 shares = _vault.deposit(depositAmount, ALICE, ALICE);

        vm.assertEq(shares, depositAmount * SHARE_SCALE); // bootstrap rate
        vm.assertEq(_vault.balanceOf(ALICE), depositAmount * SHARE_SCALE);
        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), 0);
    }

    function test_mint_operatorMintsOnBehalf(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, ONE_BILLION * 1e6);

        _prepareForDeposit(ALICE, depositAmount);
        _requestDeposit(ALICE, depositAmount);
        _vaultCloseEpoch(0);
        _vaultSettleAndGrantUnits();

        vm.prank(ALICE);
        _vault.setOperator(BOB, true);

        uint256 sharesToMint = depositAmount * SHARE_SCALE;
        vm.prank(BOB);
        uint256 assets = _vault.mint(sharesToMint, ALICE, ALICE);

        vm.assertEq(assets, depositAmount); // bootstrap rate
        vm.assertEq(_vault.balanceOf(ALICE), sharesToMint);
    }

    function test_mint_revertsOnInvalidController(uint256 depositAmount, address invalidController) public {
        depositAmount = bound(depositAmount, 1, ONE_BILLION * 1e6);
        vm.assume(invalidController != ALICE);

        _prepareForDeposit(ALICE, depositAmount);
        _requestDeposit(ALICE, depositAmount);
        _vaultCloseEpoch(0);
        _vaultSettleAndGrantUnits();

        vm.prank(invalidController);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_CALLER.selector);
        _vault.mint(depositAmount, invalidController, ALICE);
    }

    /// @dev Inflated NAV in cycle 2 → settled `claimableShares` round to 0; any deposit claim
    ///      for the dust pending balance must revert at the `shares == 0` guard in `_deposit`.
    ///      With virtual shares, zeroing a victim requires rate > bobDeposit * 1e18, i.e. a reported
    ///      NAV of ~2 * bobDeposit * (supply + VIRTUAL_SHARES) atoms (~2e23 here, 2e17 USDC) — no
    ///      longer reachable by donation-scale inflation (pre-fix, 1000x supply sufficed). The guard
    ///      remains as defense-in-depth against a pathological operator NAV report.
    function test_deposit_revertsOnDustShares_afterRateInflation(uint256 partialAssets) public {
        // Cycle 1: Alice claims at the bootstrap rate so totalSupply > 0 going into cycle 2
        _completeDepositFlow(ALICE, DEFAULT_DEPOSIT);

        // Bob requests a tiny pending deposit
        uint256 bobDeposit = 100;
        _prepareForDeposit(BOB, bobDeposit);
        _requestDeposit(BOB, bobDeposit);

        // rate = (nav + 1) * 1e18 / (supply + VIRTUAL_SHARES) = 2 * bobDeposit * 1e18, so
        // bobDeposit * 1e18 / rate floors to 0.
        uint256 inflatedNAV = 2 * bobDeposit * (_vault.totalSupply() + VIRTUAL_SHARES);
        _vaultCloseEpoch(inflatedNAV);
        _vaultSettleAndGrantUnits();

        // Any non-zero claim against Bob's dust pending balance reverts
        partialAssets = bound(partialAssets, 1, bobDeposit);
        vm.prank(BOB);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_PARAMETERS.selector);
        _vault.deposit(partialAssets, BOB);
    }

    //     ________      _              ____           __                       ______          __
    //    / ____/ /___ _(_)___ ___     / __ \___  ____/ /__  ___  ____ ___     /_  __/__  _____/ /______
    //   / /   / / __ `/ / __ `__ \   / /_/ / _ \/ __  / _ \/ _ \/ __ `__ \     / / / _ \/ ___/ __/ ___/
    //  / /___/ / /_/ / / / / / / /  / _, _/  __/ /_/ /  __/  __/ / / / / /    / / /  __(__  ) /_(__  )
    //  \____/_/\__,_/_/_/ /_/ /_/  /_/ |_|\___/\__,_/\___/\___/_/ /_/ /_/    /_/  \___/____/\__/____/

    function test_redeem(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, ONE_BILLION * 1e6);

        _completeDepositFlow(ALICE, depositAmount);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        vm.prank(ALICE);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);
        _vaultCloseEpoch(_vault.totalSupply() / SHARE_SCALE);
        _vaultSettleAndGrantUnits();

        vm.assertEq(_vault.claimableRedeemRequest(0, ALICE), aliceShares);
        vm.assertEq(_vault.maxRedeem(ALICE), aliceShares);
        vm.assertEq(_vault.maxWithdraw(ALICE), depositAmount);

        vm.prank(ALICE);
        uint256 assets = _vault.redeem(aliceShares, ALICE, ALICE);

        vm.assertEq(assets, depositAmount);
        vm.assertEq(_usdc.balanceOf(ALICE), depositAmount);
        vm.assertEq(_vault.balanceOf(address(_vault)), 0, "held shares burned");
        vm.assertEq(_vault.totalClaimableRedeemAssets(), 0);
    }

    function test_withdraw(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, ONE_BILLION * 1e6);

        _completeDepositFlow(ALICE, depositAmount);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        vm.prank(ALICE);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);
        _vaultCloseEpoch(_vault.totalSupply() / SHARE_SCALE);
        _vaultSettleAndGrantUnits();

        vm.prank(ALICE);
        uint256 shares = _vault.withdraw(depositAmount, ALICE, ALICE);

        vm.assertEq(shares, aliceShares);
        vm.assertEq(_usdc.balanceOf(ALICE), depositAmount);
    }

    function test_redeem_revertsOnInvalidController(uint256 depositAmount, address invalidController) public {
        depositAmount = bound(depositAmount, 1, ONE_BILLION * 1e6);
        vm.assume(invalidController != ALICE);

        _completeDepositFlow(ALICE, depositAmount);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        vm.prank(ALICE);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);
        _vaultCloseEpoch(_vault.totalSupply() / SHARE_SCALE);
        _vaultSettleAndGrantUnits();

        vm.prank(invalidController);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_CALLER.selector);
        _vault.redeem(aliceShares, invalidController, ALICE);
    }

    function test_redeem_revertsWithNothingToClaim(uint256 redeemAmount) public {
        redeemAmount = bound(redeemAmount, 1, ONE_BILLION * 1e6);

        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.NOTHING_TO_CLAIM.selector);
        _vault.redeem(redeemAmount, ALICE, ALICE);
    }

    function test_redeem_revertsOnZero() public {
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_PARAMETERS.selector);
        _vault.redeem(0, ALICE, ALICE);
    }

    function test_withdraw_revertsOnInvalidController(uint256 depositAmount, address invalidController) public {
        depositAmount = bound(depositAmount, 1, ONE_BILLION * 1e6);
        vm.assume(invalidController != ALICE);

        _completeDepositFlow(ALICE, depositAmount);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        vm.prank(ALICE);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);
        _vaultCloseEpoch(_vault.totalSupply() / SHARE_SCALE);
        _vaultSettleAndGrantUnits();

        vm.prank(invalidController);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_CALLER.selector);
        _vault.withdraw(depositAmount, invalidController, ALICE);
    }

    function test_withdraw_revertsOnZeroAssets() public {
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_PARAMETERS.selector);
        _vault.withdraw(0, ALICE, ALICE);
    }

    /// @dev Deflated NAV in cycle 2 → tiny `claimableAssets`; partial redeems below the
    ///      shares-per-asset threshold round to 0 assets and must revert in `_redeem`.
    function test_redeem_revertsOnDustAssets_afterRateDeflation(uint256 partialShares) public {
        // Large deposit so the deflated rate is still non-zero.
        uint256 depositAmount = ONE_BILLION * 1e6;
        _completeDepositFlow(ALICE, depositAmount);
        uint256 aliceShares = _vault.balanceOf(ALICE); // 1e27 share atoms

        vm.prank(ALICE);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);

        // Close at NAV = 1e9 (1000 USDC against a 1B USDC supply): rate floors to 1, the minimum
        // non-zero rate. claimableAssets = aliceShares * 1 / 1e18 = 1e9, and any partial claim of
        // fewer than claimableShares / claimableAssets = 1e18 share atoms rounds assets to 0.
        _vaultCloseEpoch(1e9);
        _vaultSettleAndGrantUnits();

        partialShares = bound(partialShares, 1, 1e18 - 1);
        vm.prank(ALICE);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_PARAMETERS.selector);
        _vault.redeem(partialShares, ALICE, ALICE);
    }

    function test_setOperator(address operator) public {
        vm.assertFalse(_vault.isOperator(ALICE, operator));

        vm.expectEmit(true, true, false, true, address(_vault));
        emit OperatorSet(ALICE, operator, true);

        vm.prank(ALICE);
        bool ok = _vault.setOperator(operator, true);
        vm.assertTrue(ok);
        vm.assertTrue(_vault.isOperator(ALICE, operator));

        vm.prank(ALICE);
        _vault.setOperator(operator, false);
        vm.assertFalse(_vault.isOperator(ALICE, operator));
    }

    function test_transfer_full(uint256 depositAmount, address receiver) public {
        depositAmount = bound(depositAmount, 1, ONE_BILLION * 1e6);
        vm.assume(receiver != address(0) && receiver != ALICE && receiver != address(_vault));

        _completeDepositFlow(ALICE, depositAmount);
        uint256 aliceSharesBefore = _vault.balanceOf(ALICE);
        uint128 aliceUnitsBefore = _fundManager.YIELD_POOL().getUnits(ALICE);
        uint256 receiverSharesBefore = _vault.balanceOf(receiver);
        uint128 receiverUnitsBefore = _fundManager.YIELD_POOL().getUnits(receiver);

        vm.prank(ALICE);
        _vault.transfer(receiver, aliceSharesBefore);

        vm.assertEq(_vault.balanceOf(ALICE), 0, "shares not transferred");
        vm.assertEq(_vault.balanceOf(receiver), aliceSharesBefore + receiverSharesBefore, "shares not received");
        vm.assertEq(_fundManager.YIELD_POOL().getUnits(ALICE), 0, "units not transferred");
        vm.assertEq(
            _fundManager.YIELD_POOL().getUnits(receiver),
            aliceUnitsBefore + receiverUnitsBefore,
            "units not transferred"
        );
    }

    function test_transfer_partial(uint256 depositAmount, uint256 proportion, address receiver) public {
        depositAmount = bound(depositAmount, 1, ONE_BILLION * 1e6);
        proportion = bound(proportion, 100, 9900); // ranges from 1% to 99%
        vm.assume(receiver != address(0) && receiver != ALICE && receiver != address(_vault));

        _completeDepositFlow(ALICE, depositAmount);

        uint256 aliceSharesBefore = _vault.balanceOf(ALICE);
        uint128 aliceUnitsBefore = _fundManager.YIELD_POOL().getUnits(ALICE);
        uint256 receiverSharesBefore = _vault.balanceOf(receiver);
        uint128 receiverUnitsBefore = _fundManager.YIELD_POOL().getUnits(receiver);

        uint256 sharesToTransfer = aliceSharesBefore.mulDiv(proportion, 10_000);
        // Mirrors FundManagerBase.onShareTransfer: units move rounded up (Ceil). With shares 1e12x
        // finer than units, a partial transfer can land between unit boundaries; the FM favors the
        // receiver by one unit in that case.
        uint128 expectedUnitsToTransfer =
            uint128(uint256(aliceUnitsBefore).mulDiv(sharesToTransfer, aliceSharesBefore, Math.Rounding.Ceil));

        vm.prank(ALICE);
        _vault.transfer(receiver, sharesToTransfer);

        vm.assertEq(_vault.balanceOf(ALICE), aliceSharesBefore - sharesToTransfer, "shares not transferred");
        vm.assertEq(_vault.balanceOf(receiver), receiverSharesBefore + sharesToTransfer, "shares not received");
        vm.assertEq(
            _fundManager.YIELD_POOL().getUnits(ALICE),
            aliceUnitsBefore - expectedUnitsToTransfer,
            "units not transferred"
        );
        vm.assertEq(
            _fundManager.YIELD_POOL().getUnits(receiver),
            receiverUnitsBefore + expectedUnitsToTransfer,
            "units not transferred"
        );
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

    function test_pendingAndClaimable_viewsFlipOnSettlement(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, ONE_BILLION * 1e6);

        _prepareForDeposit(ALICE, depositAmount);
        _requestDeposit(ALICE, depositAmount);

        // Before settlement: pending > 0, claimable = 0
        vm.assertEq(_vault.pendingDepositRequest(0, ALICE), depositAmount);
        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), 0);

        _vaultCloseEpoch(_vault.totalSupply() / SHARE_SCALE);
        _vaultSettleAndGrantUnits();

        // After settlement: the view mapping flips (even without interaction)
        vm.assertEq(_vault.pendingDepositRequest(0, ALICE), 0);
        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), depositAmount);
    }

    function test_convertToShares_bootstrap(uint256 assets) public view {
        assets = bound(assets, 1, ONE_BILLION * 1e6);
        vm.assertEq(_vault.convertToShares(assets), assets * SHARE_SCALE); // initial rate is BOOTSTRAP_RATE
    }

    function test_convertToAssets_bootstrap(uint256 shares) public view {
        shares = bound(shares, 1, ONE_BILLION * 1e18);

        vm.assertEq(_vault.convertToAssets(shares), shares / SHARE_SCALE);
    }

    function test_convertToShares_afterSettledEpoch() public {
        _completeDepositFlow(ALICE, DEFAULT_DEPOSIT);
        // Close/settle a second epoch reporting the assets backing the supply so rate stays at bootstrap
        _vaultCloseEpoch(_vault.totalSupply() / SHARE_SCALE);
        _vaultSettleEpoch();

        vm.assertEq(_vault.convertToShares(1e6), 1e6 * SHARE_SCALE);
    }

    /// @dev When `currentEpoch - 1` is closed but not yet settled, `_lastSettledRate` must fall
    ///      back to `currentEpoch - 2`'s settled rate rather than to the bootstrap default.
    function test_lastSettledRate_duringCloseWindow_fallsBackToTwoEpochsAgo(uint256 rateMultiplier) public {
        rateMultiplier = bound(rateMultiplier, 2, 100);

        // Cycle 1 (epoch 1): bootstrap deposit at BOOTSTRAP_RATE
        _completeDepositFlow(ALICE, DEFAULT_DEPOSIT);

        // Cycle 2 (epoch 2): close+settle so the epoch-2 rate settles to exactly
        // rateMultiplier * BOOTSTRAP_RATE — nav2 solves
        // (nav2 + 1) * 1e18 / (supply + VIRTUAL_SHARES) == rateMultiplier * BOOTSTRAP_RATE.
        uint256 nav2 = rateMultiplier * (_vault.totalSupply() / SHARE_SCALE + 1) - 1;
        _vaultCloseEpoch(nav2);
        _vaultSettleAndGrantUnits();

        vm.assertTrue(_vault.isEpochSettled(2));
        vm.assertEq(_vault.currentEpoch(), 3);

        // Cycle 3 (epoch 3): close but DO NOT settle → currentEpoch=4, epoch 3 closed-not-settled.
        _vaultCloseEpoch(_vault.totalSupply() / SHARE_SCALE);
        vm.assertEq(_vault.currentEpoch(), 4);
        vm.assertFalse(_vault.isEpochSettled(3));
        vm.assertTrue(_vault.isEpochSettled(2));

        // Conversions must use epoch 2's rate (rateMultiplier * BOOTSTRAP_RATE), not the bootstrap default.
        uint256 sampleAssets = 1000e6;
        vm.assertEq(_vault.convertToShares(sampleAssets * rateMultiplier), sampleAssets * SHARE_SCALE);
        vm.assertEq(_vault.convertToAssets(sampleAssets * SHARE_SCALE), sampleAssets * rateMultiplier);
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

        _vaultCloseEpoch(_vault.totalSupply() / SHARE_SCALE);
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

    /// @dev First-depositor inflation attack regression (the reason for VIRTUAL_SHARES): the
    ///      attacker bootstraps as sole holder with a 1-atom deposit, then inflates the NAV
    ///      (a donation to the FM shows up in the reported NAV at closeEpoch) before the victim's
    ///      epoch settles. The virtual shares absorb the inflation: the victim's settled shares
    ///      are never zeroed (pre-fix they floored to 0, permanently locking the victim's assets)
    ///      and the attack is strictly loss-making — roughly half the donation accrues to the
    ///      virtual holder instead of the attacker.
    function test_firstDepositorInflationAttack_isNeutralized() public {
        // Cycle 1: attacker becomes the sole holder with a 1-atom deposit
        _completeDepositFlow(ALICE, 1);
        uint256 attackerShares = _vault.balanceOf(ALICE);

        // Victim requests a 100 USDC deposit
        uint256 victimDeposit = 100e6;
        _prepareForDeposit(BOB, victimDeposit);
        _requestDeposit(BOB, victimDeposit);

        // Attacker donates 1000 USDC before the close: reported NAV = attacker principal + donation
        uint256 donation = 1000e6;
        _vaultCloseEpoch(1 + donation);
        _vaultSettleAndGrantUnits();

        // The victim's shares survive the inflated rate
        vm.prank(BOB);
        uint256 victimShares = _vault.deposit(victimDeposit, BOB);
        vm.assertGt(victimShares, 0, "victim shares zeroed");

        // The victim's rounding loss is bounded by one share atom's value (< 1 asset atom here)
        uint256 victimValue = _vault.convertToAssets(victimShares);
        vm.assertGe(victimValue + 1, victimDeposit, "victim lost more than rounding dust");

        // The attacker can redeem far less than the 1 + donation atoms they spent
        uint256 attackerValue = _vault.convertToAssets(attackerShares);
        vm.assertLt(attackerValue, 1 + donation, "attack not loss-making");
    }

}
