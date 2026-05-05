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

    function _prepareForDeposit(address user, uint256 amount) internal {
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

        vm.startPrank(address(_fundManager));
        _vault.onSettleEpoch();

        if (snap.depositingAssets > 0) {
            uint256 units = snap.depositingAssets * _fundManager.UNIT_PER_ASSET_DEPOSITED();
            _fundManager.POOL().increaseMemberUnits(address(_fundManager), uint128(units));
        }

        vm.stopPrank();
    }

    /// @dev Full deposit lifecycle for a single user. At rate=1e18, shares issued == assets deposited (in atoms).
    ///      Reports NAV matching current outstanding shares to keep the epoch rate at 1e18.
    function _completeDepositFlow(address user, uint256 amount) internal {
        _prepareForDeposit(user, amount);
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
        vm.assertEq(aliceShares, assetAmount); // rate=1e18 => share atoms == asset atoms

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
        vm.assertEq(snap.rate, 1e18); // zero supply => default bootstrap rate
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
        vm.assertEq(snap.rate, 1e18);
        vm.assertEq(_vault.totalPendingDepositAssets(), 0, "totalPending reset at close");
        vm.assertEq(_vault.currentEpoch(), 2);
    }

    function test_onCloseEpoch_computesRateFromEffectiveSupply(uint256 assetAmount) public {
        assetAmount = bound(assetAmount, 1, ONE_BILLION * 1e6);

        // Bootstrap: Alice holds assetAmount shares at rate=1e18
        _completeDepositFlow(ALICE, assetAmount);

        // NAV doubled -> rate should be 2e18
        _vaultCloseEpoch(2 * assetAmount);
        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();
        vm.assertEq(snap.rate, 2e18);
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
        emit EpochSettled(1, depositAmount, 1e18, depositAmount, 0);

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
        // effectiveSupply = 0 (ts) + depositAmount (unclaimedDeposit) - 0 = depositAmount
        // rate = depositAmount * 1e18 / depositAmount = 1e18
        vm.assertEq(snap.rate, 1e18);
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
        vm.assertEq(_vault.maxMint(ALICE), depositAmount);

        vm.prank(ALICE);
        uint256 shares = _vault.deposit(depositAmount, ALICE);

        vm.assertEq(shares, depositAmount); // rate=1e18
        vm.assertEq(_vault.balanceOf(ALICE), depositAmount);
        vm.assertEq(_vault.totalSupply(), depositAmount);
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

        vm.assertEq(shares, half);
        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), depositAmount - half);
        vm.assertEq(_vault.balanceOf(ALICE), half);
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

        vm.prank(ALICE);
        uint256 assets = _vault.mint(depositAmount, ALICE);

        vm.assertEq(assets, depositAmount);
        vm.assertEq(_vault.balanceOf(ALICE), depositAmount);
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

        vm.assertEq(shares, depositAmount); // rate=1e18
        vm.assertEq(_vault.balanceOf(ALICE), depositAmount);
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

        vm.prank(BOB);
        uint256 assets = _vault.mint(depositAmount, ALICE, ALICE);

        vm.assertEq(assets, depositAmount); // rate=1e18
        vm.assertEq(_vault.balanceOf(ALICE), depositAmount);
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
    function test_deposit_revertsOnDustShares_afterRateInflation(uint256 partialAssets) public {
        // Cycle 1: Alice claims at the bootstrap rate (1e18) so totalSupply > 0 going into cycle 2
        _completeDepositFlow(ALICE, DEFAULT_DEPOSIT);

        // Bob requests a tiny pending deposit
        uint256 bobDeposit = 100;
        _prepareForDeposit(BOB, bobDeposit);
        _requestDeposit(BOB, bobDeposit);

        // Inflate NAV so that the cycle-2 rate makes Bob's pending atoms round to 0 shares.
        // effectiveSupply == totalSupply (DEFAULT_DEPOSIT). Reporting 1000× supply makes rate = 1e21,
        // which is large enough that bobDeposit * 1e18 / rate floors to 0.
        _vaultCloseEpoch(1000 * DEFAULT_DEPOSIT);
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
        _vaultCloseEpoch(_vault.totalSupply() == 0 ? depositAmount : _vault.totalSupply());
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
        _vaultCloseEpoch(_vault.totalSupply() == 0 ? depositAmount : _vault.totalSupply());
        _vaultSettleAndGrantUnits();

        vm.prank(ALICE);
        uint256 shares = _vault.withdraw(depositAmount, ALICE, ALICE);

        vm.assertEq(shares, aliceShares);
        vm.assertEq(_usdc.balanceOf(ALICE), depositAmount);
    }

    function test_redeem_revertsOnInvalidController(uint256 depositAmount, address invalidController) public {
        depositAmount = bound(depositAmount, 1, ONE_BILLION * 1e6);

        _completeDepositFlow(ALICE, depositAmount);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        vm.prank(ALICE);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);
        _vaultCloseEpoch(_vault.totalSupply() == 0 ? depositAmount : _vault.totalSupply());
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
        _vaultCloseEpoch(_vault.totalSupply() == 0 ? depositAmount : _vault.totalSupply());
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

    /// @dev Deflated NAV in cycle 2 → claimableAssets is positive (=1) but tiny; partial redeems
    ///      below the share-per-asset threshold round to 0 assets and must revert in `_redeem`.
    function test_redeem_revertsOnDustAssets_afterRateDeflation(uint256 partialShares) public {
        // Use a large deposit so a deflated rate yields exactly one redeemable atom.
        uint256 depositAmount = ONE_BILLION * 1e6;
        _completeDepositFlow(ALICE, depositAmount);
        uint256 aliceShares = _vault.balanceOf(ALICE);

        vm.prank(ALICE);
        _vault.requestRedeem(aliceShares, ALICE, ALICE);

        // Close at NAV=1: effectiveSupply == aliceShares so rate = 1e18 / aliceShares.
        // redeemingAssets = aliceShares * rate / 1e18 == 1 → claimableAssets is non-zero
        // but any partial claim with shares < aliceShares rounds assets to 0.
        _vaultCloseEpoch(1);
        _vaultSettleAndGrantUnits();

        partialShares = bound(partialShares, 1, aliceShares - 1);
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

    function test_pendingAndClaimable_viewsFlipOnSettlement(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, ONE_BILLION * 1e6);

        _prepareForDeposit(ALICE, depositAmount);
        _requestDeposit(ALICE, depositAmount);

        // Before settlement: pending > 0, claimable = 0
        vm.assertEq(_vault.pendingDepositRequest(0, ALICE), depositAmount);
        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), 0);

        _vaultCloseEpoch(_vault.totalSupply() == 0 ? depositAmount : _vault.totalSupply());
        _vaultSettleAndGrantUnits();

        // After settlement: the view mapping flips (even without interaction)
        vm.assertEq(_vault.pendingDepositRequest(0, ALICE), 0);
        vm.assertEq(_vault.claimableDepositRequest(0, ALICE), depositAmount);
    }

    function test_convertToShares_bootstrap(uint256 assets) public view {
        assets = bound(assets, 1, ONE_BILLION * 1e6);
        vm.assertEq(_vault.convertToShares(assets), assets); // initial rate is 1e18
    }

    function test_convertToAssets_bootstrap(uint256 shares) public view {
        shares = bound(shares, 1, ONE_BILLION * 1e18);

        vm.assertEq(_vault.convertToAssets(shares), shares);
    }

    function test_convertToShares_afterSettledEpoch() public {
        _completeDepositFlow(ALICE, DEFAULT_DEPOSIT);
        // Close/settle a second epoch reporting NAV == outstanding shares so rate stays 1e18
        _vaultCloseEpoch(_vault.totalSupply());
        _vaultSettleEpoch();

        vm.assertEq(_vault.convertToShares(1e6), 1e6);
    }

    /// @dev When `currentEpoch - 1` is closed but not yet settled, `_lastSettledRate` must fall
    ///      back to `currentEpoch - 2`'s settled rate rather than to the bootstrap default.
    function test_lastSettledRate_duringCloseWindow_fallsBackToTwoEpochsAgo(uint256 rateMultiplier) public {
        rateMultiplier = bound(rateMultiplier, 2, 100);

        // Cycle 1 (epoch 1): bootstrap deposit at rate=1e18
        _completeDepositFlow(ALICE, DEFAULT_DEPOSIT);

        // Cycle 2 (epoch 2): close+settle reporting rateMultiplier × outstanding shares so rate
        // for epoch 2 settles to rateMultiplier * 1e18.
        uint256 nav2 = rateMultiplier * _vault.totalSupply();
        _vaultCloseEpoch(nav2);
        _vaultSettleAndGrantUnits();

        vm.assertTrue(_vault.isEpochSettled(2));
        vm.assertEq(_vault.currentEpoch(), 3);

        // Cycle 3 (epoch 3): close but DO NOT settle → currentEpoch=4, epoch 3 closed-not-settled.
        _vaultCloseEpoch(_vault.totalSupply());
        vm.assertEq(_vault.currentEpoch(), 4);
        vm.assertFalse(_vault.isEpochSettled(3));
        vm.assertTrue(_vault.isEpochSettled(2));

        // Conversions must use epoch 2's rate (rateMultiplier * 1e18), not the bootstrap default.
        uint256 sampleAssets = 1000e6;
        vm.assertEq(_vault.convertToShares(sampleAssets * rateMultiplier), sampleAssets);
        vm.assertEq(_vault.convertToAssets(sampleAssets), sampleAssets * rateMultiplier);
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
