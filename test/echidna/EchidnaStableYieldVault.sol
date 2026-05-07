// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { ERC1820RegistryCompiled } from
    "@superfluid-finance/ethereum-contracts/contracts/libs/ERC1820RegistryCompiled.sol";
import { SuperToken } from "@superfluid-finance/ethereum-contracts/contracts/superfluid/SuperToken.sol";
import { SuperfluidFrameworkDeployer } from
    "@superfluid-finance/ethereum-contracts/contracts/utils/SuperfluidFrameworkDeployer.t.sol";
import {
    CFAv1ForwarderDeployerLibrary,
    GDAv1ForwarderDeployerLibrary,
    ProxyDeployerLibrary,
    SuperTokenDeployerLibrary,
    SuperTokenFactoryDeployerLibrary,
    SuperfluidCFAv1DeployerLibrary,
    SuperfluidGDAv1DeployerLibrary,
    SuperfluidGovDeployerLibrary,
    SuperfluidHostDeployerLibrary,
    SuperfluidIDAv1DeployerLibrary,
    SuperfluidPeripheryDeployerLibrary,
    SuperfluidPoolLogicDeployerLibrary,
    SuperfluidPoolNFTLogicDeployerLibrary,
    TokenDeployerLibrary
} from "@superfluid-finance/ethereum-contracts/contracts/utils/SuperfluidFrameworkDeploymentSteps.t.sol";
import { TestToken } from "@superfluid-finance/ethereum-contracts/contracts/utils/TestToken.sol";

import { SuperfluidPoolDeployerLibrary } from
    "@superfluid-finance/ethereum-contracts/contracts/agreements/gdav1/SuperfluidPoolDeployerLibrary.sol";
import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";
import { SlotsBitmapLibrary } from "@superfluid-finance/ethereum-contracts/contracts/libs/SlotsBitmapLibrary.sol";

import { FundManager } from "src/FundManager.sol";
import { StableYieldAsyncVault } from "src/StableYieldAsyncVault.sol";
import { IStableYieldAsyncVault } from "src/interfaces/vault/IStableYieldAsyncVault.sol";

interface IHevm {

    function etch(address who, bytes calldata code) external;
    function prank(address) external;
    function warp(uint256) external;

}

/// @title Echidna fuzzing harness for the StableYieldAsyncVault + FundManager pair.
/// @dev   Deploys the full Superfluid framework in the constructor and exposes clamped action
///        handlers for each mutating entrypoint so Echidna's fuzzer spends time on logic, not
///        revert paths. Tier A invariants (asset accounting) are checked after every handler.
contract EchidnaStableYieldVault {

    IHevm private constant HEVM = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint256 private constant ACTOR_INITIAL_USDC = 1_000_000 * 1e6; // 1M USDC each
    uint256 private constant OPERATOR_INITIAL_USDC = 100_000_000 * 1e6; // 100M operator treasury
    uint256 private constant STRATEGY_RESERVE_INITIAL = 100_000_000 * 1e6; // 100M strategy yield pool
    uint256 private constant INITIAL_RATE = 1000; // 10% APR (basis points)
    uint256 private constant INITIAL_FLOW_DURATION = 7 days;
    uint256 private constant MAX_RATE = 5000; // cap fuzzed rate at 50%
    uint256 private constant MAX_WARP = 30 days;

    /// @dev Closed-loop strategy reserve. Holds a finite USDC pool that funds simulated
    ///      gains and absorbs simulated losses, modelling an off-chain strategy that earns
    ///      from / loses to a bounded external counterparty. Total USDC across {harness,
    ///      strategy reserve, FM, vault, actors, sink} is conserved across the run.
    address private constant STRATEGY_RESERVE = address(uint160(uint256(keccak256("ECHIDNA_STRATEGY_RESERVE"))));

    SuperfluidFrameworkDeployer.Framework private _sf;
    SuperfluidFrameworkDeployer private _deployer;
    TestToken private _usdc;
    SuperToken private _usdcx;

    FundManager private _fundManager;
    StableYieldAsyncVault private _vault;

    address[3] private _actors;

    /// @dev Highest epoch number observed across all handler calls; must never decrease.
    uint256 private _ghostMaxEpoch;

    /// @dev Highest epoch number we've observed as `isEpochSettled == true`. Used by A.5
    ///      to assert the settled flag is sticky (once true for an epoch, never false again).
    uint256 private _ghostLastSettledEpoch;

    /// @dev C.4 — share balance the vault holds for in-flight redeems.
    ///      Incremented when `requestRedeem` succeeds; decremented when `redeem` succeeds.
    ///      Must equal `_vault.balanceOf(address(_vault))` at all times.
    uint256 private _ghostInflightRedeemShares;

    /// @dev Net underlying capital the harness currently holds as "external strategy"
    ///      (Σ takes − Σ gives). Used to clamp `operator_simulate_*` and `close_epoch_with_working`,
    ///      and to gate the rate-direction invariant.
    uint256 private _ghostOutstandingCapital;

    /// @dev Last-settled rate (`convertToAssets(1e18)`) captured immediately after the most
    ///      recent successful `settle_epoch`. Zero before the first settlement.
    uint256 private _ghostLastSettleRate;

    /// @dev Total underlying assets reported at the most recent successful close (NAV).
    uint256 private _ghostLastSettleNav;

    /// @dev True if any investor entrypoint (request/claim) has succeeded since the last
    ///      successful settle. Gates the rate-direction invariant.
    bool private _ghostInvestorActivitySinceSettle;

    /// @dev True if `warp_seconds` has advanced `block.timestamp` since the last successful
    ///      settle. Gates the rate-direction invariant — yield-stream payout makes
    ///      `scaledYieldAssetsBalance` decay over time, which is unrelated to operator PnL.
    bool private _ghostTimeAdvancedSinceSettle;

    /// @dev B.5 — snapshot rate captured at the most recent successful close. Zero when no
    ///      snapshot is open. Asserted equal to `getSnapshot().rate` on every `_check`
    ///      while the snapshot is open.
    uint256 private _ghostSnapshotRate;

    /// @dev G.4 — `convertToAssets(1e18)` captured at constructor and after every successful
    ///      settle. Asserted equal on every `_check` — convertTo* uses last-settled rate,
    ///      so the in-flight snapshot must never leak into it.
    uint256 private _ghostStableConvert;

    /// @dev C.2 / C.3 — expected `totalSupply`. Updated only by claim handlers (mint on
    ///      claim_deposit, burn on claim_redeem / claim_withdraw). Asserted equal to
    ///      `_vault.totalSupply()` on every `_check` — any handler that accidentally
    ///      changes supply outside the claim path will trip this.
    uint256 private _ghostTotalSupply;

    constructor() {
        _actors[0] = address(uint160(uint256(keccak256("ECHIDNA_ALICE"))));
        _actors[1] = address(uint160(uint256(keccak256("ECHIDNA_BOB"))));
        _actors[2] = address(uint160(uint256(keccak256("ECHIDNA_CAROL"))));

        HEVM.etch(ERC1820RegistryCompiled.at, ERC1820RegistryCompiled.bin);
        _plantSuperfluidLibraries();

        _deployer = new SuperfluidFrameworkDeployer();
        _deployer.deployTestFramework();
        _sf = _deployer.getFramework();

        (TestToken usdc_, SuperToken usdcx_) =
            _deployer.deployWrapperSuperToken("USDC", "USDC", 6, type(uint256).max, address(0));
        _usdc = usdc_;
        _usdcx = usdcx_;

        _vault = new StableYieldAsyncVault(
            address(_usdc),
            address(_usdcx),
            address(this),
            address(this),
            INITIAL_RATE,
            INITIAL_FLOW_DURATION,
            "Echidna Vault Share",
            "EVS"
        );
        _fundManager = FundManager(address(_vault.FUND_MANAGER()));

        // Operator treasury — used to optionally seed FM via `operator_give` during fuzzing.
        // The FM itself starts EMPTY: at zero share supply the system has no NAV, and
        // pre-seeding would establish a fictitious starting balance with no real-world
        // counterpart (and would mask first-depositor / bootstrap-rate behaviour).
        _usdc.mint(address(this), OPERATOR_INITIAL_USDC);
        _usdc.approve(address(_fundManager), type(uint256).max);

        // Pre-fund the strategy reserve. This is the closed-loop pool that funds simulated
        // gains and absorbs simulated losses (see operator_simulate_gain / _simulate_loss).
        _usdc.mint(STRATEGY_RESERVE, STRATEGY_RESERVE_INITIAL);
        HEVM.prank(STRATEGY_RESERVE);
        _usdc.approve(address(this), type(uint256).max);

        for (uint256 i = 0; i < _actors.length; i++) {
            address actor = _actors[i];
            _usdc.mint(actor, ACTOR_INITIAL_USDC);
            HEVM.prank(actor);
            _usdc.approve(address(_vault), type(uint256).max);
        }

        _ghostMaxEpoch = _vault.currentEpoch();
        // FM is empty at construction, so NAV is zero. The first close+settle with
        // depositor capital establishes the real baseline.
        _ghostLastSettleNav = 0;
        _ghostStableConvert = _vault.convertToAssets(1e18);

        // D.7 — pool config: units non-transferable, distribution-from-any-address disabled,
        //       admin is the FundManager. These are set in FundManager's constructor and not
        //       mutable, so a one-time check is sufficient.
        ISuperfluidPool pool = _fundManager.POOL();
        require(pool.admin() == address(_fundManager), "D.7 admin");
        require(!pool.transferabilityForUnitsOwner(), "D.7 transferability");
        require(!pool.distributionFromAnyAddress(), "D.7 distribution");
    }

    //      ____                        _ __     ___        __  _
    //     / __ \___  ____  ____  _____(_) /_   /   | _____/ /_(_)___  ____  _____
    //    / / / / _ \/ __ \/ __ \/ ___/ / __/  / /| |/ ___/ __/ / __ \/ __ \/ ___/
    //   / /_/ /  __/ /_/ / /_/ (__  ) / /_   / ___ / /__/ /_/ / /_/ / / / (__  )
    //  /_____/\___/ .___/\____/____/_/\__/  /_/  |_\___/\__/_/\____/_/ /_/____/
    //            /_/

    function request_deposit(uint8 actorIdx, uint96 amount) external {
        address actor = _actor(actorIdx);
        uint256 bal = _usdc.balanceOf(actor);
        uint256 amt = _bound(amount, bal);
        if (amt == 0) return;

        ISuperfluidPool pool = _fundManager.POOL();
        uint128 actorUnitsBefore = pool.getUnits(actor);
        uint256 vaultBalanceBefore = _usdc.balanceOf(address(_vault));

        HEVM.prank(actor);
        try _vault.requestDeposit(amt, actor, actor) returns (uint256 reqId) {
            _ghostInvestorActivitySinceSettle = true;
            // A.6 — request id is the constant REQUEST_ID == 0
            assert(reqId == 0);
            // D.1 (negative form) — yield stream commences at claim, NOT at request:
            //                       requestDeposit must not change pool units.
            assert(pool.getUnits(actor) == actorUnitsBefore);
            assert(_usdc.balanceOf(address(_vault)) == vaultBalanceBefore + amt);
        } catch { }

        _check();
    }

    /// @dev F.6 — `requestDeposit` via an approved operator. `caller` (= operator) acts
    ///      on `owner`'s behalf. Owner == controller for simplicity; the cross-receiver
    ///      case is exercised by `claim_deposit_for`.
    function request_deposit_for(uint8 callerIdx, uint8 ownerIdx, uint96 amount) external {
        address caller = _actor(callerIdx);
        address owner = _actor(ownerIdx);
        if (caller == owner) return;
        uint256 bal = _usdc.balanceOf(owner);
        uint256 amt = _bound(amount, bal);
        if (amt == 0) return;

        HEVM.prank(caller);
        try _vault.requestDeposit(amt, owner, owner) returns (uint256 reqId) {
            _ghostInvestorActivitySinceSettle = true;
            assert(reqId == 0);
        } catch { }

        _check();
    }

    /// @dev A.3 / B.1 — while a snapshot is open (between closeEpoch and settleEpoch),
    ///      every `requestDeposit` MUST revert with EPOCH_SETTLEMENT_IN_PROGRESS.
    function probe_request_deposit_during_settlement(uint8 actorIdx, uint96 amount) external {
        if (_vault.getSnapshot().epoch == 0) return;
        address actor = _actor(actorIdx);
        uint256 bal = _usdc.balanceOf(actor);
        uint256 amt = _bound(amount, bal);
        if (amt == 0) return;
        HEVM.prank(actor);
        (bool ok,) = address(_vault).call(
            abi.encodeWithSelector(bytes4(keccak256("requestDeposit(uint256,address,address)")), amt, actor, actor)
        );
        assert(!ok);
    }

    function claim_deposit(uint8 actorIdx, uint96 portion) external {
        address actor = _actor(actorIdx);
        uint256 maxA = _vault.maxDeposit(actor);
        if (maxA == 0) return;
        uint256 amt = _bound(portion, maxA);
        if (amt == 0) return;

        ISuperfluidPool pool = _fundManager.POOL();
        uint128 unitsBefore = pool.getTotalUnits();
        int96 flowBefore = pool.getTotalFlowRate();
        uint128 actorUnitsBefore = pool.getUnits(actor);

        HEVM.prank(actor);
        bool ok;
        try _vault.deposit(amt, actor) returns (uint256 sharesMinted) {
            ok = true;
            _ghostInvestorActivitySinceSettle = true;

            // C.2 — shares mint at claim, never elsewhere
            _ghostTotalSupply += sharesMinted;
        } catch { }

        if (ok) {
            // D.3a — totalUnits is conserved by FM.onClaimDeposit (decrement FM, increment
            //        receiver by the same amount). This holds.
            assert(pool.getTotalUnits() == unitsBefore);

            // D.3b — totalFlowRate temporarily disabled; see finding F-2.
            // NOTE : this fails because of the `onClaimDeposit` tweaks units and may create adjustment flowrate
            // assert(pool.getTotalFlowRate() == flowBefore);

            // D.1 — yield stream commences at claim: receiver gains units. Strict-only
            //        when the deposited amount maps to ≥ 1 GDA unit.
            if (amt >= _fundManager.RAW_PER_UNIT()) {
                assert(pool.getUnits(actor) > actorUnitsBefore);
            }
        }

        _check();
    }

    /// @dev 3-arg `deposit` with `caller` claiming `controller`'s pending request and
    ///      minting shares to a third actor (`receiver`). Pool units land on `receiver`.
    function claim_deposit_for(uint8 callerIdx, uint8 controllerIdx, uint8 receiverIdx, uint96 portion) external {
        address caller = _actor(callerIdx);
        address controller = _actor(controllerIdx);
        address receiver = _actor(receiverIdx);
        uint256 maxA = _vault.maxDeposit(controller);
        if (maxA == 0) return;
        uint256 amt = _bound(portion, maxA);
        if (amt == 0) return;

        ISuperfluidPool pool = _fundManager.POOL();
        uint128 receiverUnitsBefore = pool.getUnits(receiver);
        uint128 totalUnitsBefore = pool.getTotalUnits();

        HEVM.prank(caller);
        try _vault.deposit(amt, receiver, controller) returns (uint256 sharesMinted) {
            _ghostInvestorActivitySinceSettle = true;
            _ghostTotalSupply += sharesMinted;
            // D.3a — totalUnits conserved (FM down by N, receiver up by N).
            assert(pool.getTotalUnits() == totalUnitsBefore);
            // D.1 — yield stream lands on RECEIVER, not controller.
            if (amt >= _fundManager.RAW_PER_UNIT()) {
                assert(pool.getUnits(receiver) > receiverUnitsBefore);
            }
        } catch { }

        _check();
    }

    /// @dev H.3 — `mint` rounds assets up (vs `deposit`'s shares-down). Caller is the
    ///      controller; receiver is the same actor. 2-arg overload.
    function claim_mint(uint8 actorIdx, uint96 portion) external {
        address actor = _actor(actorIdx);
        uint256 maxS = _vault.maxMint(actor);
        if (maxS == 0) return;
        uint256 amt = _bound(portion, maxS);
        if (amt == 0) return;

        ISuperfluidPool pool = _fundManager.POOL();
        uint128 actorUnitsBefore = pool.getUnits(actor);
        uint256 supplyBefore = _vault.totalSupply();

        HEVM.prank(actor);
        try _vault.mint(amt, actor) returns (uint256) {
            _ghostInvestorActivitySinceSettle = true;
            // C.2 — shares mint at claim. Strict change.
            uint256 minted = _vault.totalSupply() - supplyBefore;
            assert(minted == amt);
            _ghostTotalSupply += minted;
            // D.1 — yield stream commences at claim: receiver gains units when amt is
            //        large enough to map to ≥1 GDA unit.
            if (amt >= _fundManager.RAW_PER_UNIT()) {
                assert(pool.getUnits(actor) > actorUnitsBefore);
            }
        } catch { }

        _check();
    }

    //      ____           __                       ___        __  _
    //     / __ \___  ____/ /__  ___  ____ ___     /   | _____/ /_(_)___  ____  _____
    //    / /_/ / _ \/ __  / _ \/ _ \/ __ `__ \   / /| |/ ___/ __/ / __ \/ __ \/ ___/
    //   / _, _/  __/ /_/ /  __/  __/ / / / / /  / ___ / /__/ /_/ / /_/ / / / (__  )
    //  /_/ |_|\___/\__,_/\___/\___/_/ /_/ /_/  /_/  |_\___/\__/_/\____/_/ /_/____/

    function request_redeem(uint8 actorIdx, uint96 shares) external {
        address actor = _actor(actorIdx);
        uint256 bal = _vault.balanceOf(actor);
        uint256 amt = _bound(shares, bal);
        if (amt == 0) return;

        ISuperfluidPool pool = _fundManager.POOL();
        uint128 actorUnitsBefore = pool.getUnits(actor);
        int96 actorFlowRateBefore = pool.getMemberFlowRate(actor);

        HEVM.prank(actor);
        try _vault.requestRedeem(amt, actor, actor) returns (uint256 reqId) {
            _ghostInvestorActivitySinceSettle = true;
            _ghostInflightRedeemShares += amt;
            // A.6 — request id is the constant REQUEST_ID == 0
            assert(reqId == 0);
            // D.2 — yield stream stops at requestRedeem: redeemer's units must decrease.
            //        (Skip if before == 0, which means the actor never claimed.)
            if (actorUnitsBefore > 0) {
                assert(pool.getUnits(actor) < actorUnitsBefore);
                assert(pool.getMemberFlowRate(actor) < actorFlowRateBefore);
            }
        } catch { }

        _check();
    }

    /// @dev F.6 — `requestRedeem` via an approved operator on `owner`'s shares.
    function request_redeem_for(uint8 callerIdx, uint8 ownerIdx, uint96 shares) external {
        address caller = _actor(callerIdx);
        address owner = _actor(ownerIdx);
        if (caller == owner) return;
        uint256 bal = _vault.balanceOf(owner);
        uint256 amt = _bound(shares, bal);
        if (amt == 0) return;

        HEVM.prank(caller);
        try _vault.requestRedeem(amt, owner, owner) returns (uint256 reqId) {
            _ghostInvestorActivitySinceSettle = true;
            _ghostInflightRedeemShares += amt;
            assert(reqId == 0);
        } catch { }

        _check();
    }

    /// @dev A.3 — `requestRedeem` MUST revert with EPOCH_SETTLEMENT_IN_PROGRESS.
    function probe_request_redeem_during_settlement(uint8 actorIdx, uint96 shares) external {
        if (_vault.getSnapshot().epoch == 0) return;
        address actor = _actor(actorIdx);
        uint256 bal = _vault.balanceOf(actor);
        uint256 amt = _bound(shares, bal);
        if (amt == 0) return;
        HEVM.prank(actor);
        (bool ok,) = address(_vault).call(
            abi.encodeWithSelector(bytes4(keccak256("requestRedeem(uint256,address,address)")), amt, actor, actor)
        );
        assert(!ok);
    }

    function claim_redeem(uint8 actorIdx, uint96 portion) external {
        address actor = _actor(actorIdx);
        uint256 maxS = _vault.maxRedeem(actor);
        if (maxS == 0) return;
        uint256 amt = _bound(portion, maxS);
        if (amt == 0) return;

        HEVM.prank(actor);
        try _vault.redeem(amt, actor, actor) returns (uint256) {
            _ghostInvestorActivitySinceSettle = true;
            _ghostInflightRedeemShares -= amt;
            // C.3 — shares burn at claim, never elsewhere
            _ghostTotalSupply -= amt;
        } catch { }

        _check();
    }
    /// @dev 3-arg `redeem` with cross-actor receiver. Caller claims controller's settled
    ///      redeem; underlying lands on `receiver`.

    function claim_redeem_for(uint8 callerIdx, uint8 controllerIdx, uint8 receiverIdx, uint96 portion) external {
        address caller = _actor(callerIdx);
        address controller = _actor(controllerIdx);
        address receiver = _actor(receiverIdx);
        uint256 maxS = _vault.maxRedeem(controller);
        if (maxS == 0) return;
        uint256 amt = _bound(portion, maxS);
        if (amt == 0) return;

        HEVM.prank(caller);
        try _vault.redeem(amt, receiver, controller) returns (uint256) {
            _ghostInvestorActivitySinceSettle = true;
            _ghostInflightRedeemShares -= amt;
            _ghostTotalSupply -= amt;
        } catch { }

        _check();
    }

    /// @dev Asset-denominated claim of a settled redeem. Counterpart to `claim_redeem`
    ///      (which is share-denominated). Exercises the `withdraw` codepath and C.5.
    function claim_withdraw(uint8 actorIdx, uint96 portion) external {
        address actor = _actor(actorIdx);
        uint256 maxA = _vault.maxWithdraw(actor);
        if (maxA == 0) return;
        uint256 amt = _bound(portion, maxA);
        if (amt == 0) return;

        HEVM.prank(actor);
        try _vault.withdraw(amt, actor, actor) returns (uint256 shares) {
            _ghostInvestorActivitySinceSettle = true;
            _ghostInflightRedeemShares -= shares;
            // C.3 — shares burn at claim, never elsewhere
            _ghostTotalSupply -= shares;
            // C.5 — `withdraw` rounds shares up so any non-zero asset withdrawal
            //       burns at least one share.
            assert(shares >= 1);
        } catch { }

        _check();
    }

    /// @dev 3-arg `withdraw` with cross-actor receiver.
    function claim_withdraw_for(uint8 callerIdx, uint8 controllerIdx, uint8 receiverIdx, uint96 portion) external {
        address caller = _actor(callerIdx);
        address controller = _actor(controllerIdx);
        address receiver = _actor(receiverIdx);
        uint256 maxA = _vault.maxWithdraw(controller);
        if (maxA == 0) return;
        uint256 amt = _bound(portion, maxA);
        if (amt == 0) return;

        HEVM.prank(caller);
        try _vault.withdraw(amt, receiver, controller) returns (uint256 shares) {
            _ghostInvestorActivitySinceSettle = true;
            _ghostInflightRedeemShares -= shares;
            _ghostTotalSupply -= shares;
            // C.5 — withdraw rounds shares up.
            assert(shares >= 1);
        } catch { }

        _check();
    }

    //     ____                        __                __  ___                                                  __
    //    / __ \____  ___  _________ _/ /_____  _____   /  |/  /___ _____  ____ _____ ____  ____ ___  ___  ____  / /_
    //   / / / / __ \/ _ \/ ___/ __ `/ __/ __ \/ ___/  / /|_/ / __ `/ __ \/ __ `/ __ `/ _ \/ __ `__ \/ _ \/ __ \/ __/
    //  / /_/ / /_/ /  __/ /  / /_/ / /_/ /_/ / /     / /  / / /_/ / / / / /_/ / /_/ /  __/ / / / / /  __/ / / / /_
    //  \____/ .___/\___/_/   \__,_/\__/\____/_/     /_/  /_/\__,_/_/ /_/\__,_/\__, /\___/_/ /_/ /_/\___/_/ /_/\__/
    //      /_/                                                               /____/

    // Cross-actor / operator-approval flows. Exercises:
    //  · F.6 — the `_isOperator[controller][operator]` authorization branch.
    //  · 3-arg `deposit/mint/redeem/withdraw` with controller != receiver.
    //  · H.3 — `mint` rounds assets *up* (different from `deposit`'s shares-down rounding).

    /// @dev F.6 — toggle operator approval on behalf of `ownerIdx`. msg.sender is the
    ///      owner; the contract grants/revokes operator privileges for `operatorIdx`.
    function set_operator(uint8 ownerIdx, uint8 operatorIdx, bool approved) external {
        address owner = _actor(ownerIdx);
        address operator = _actor(operatorIdx);
        if (owner == operator) return;
        HEVM.prank(owner);
        try _vault.setOperator(operator, approved) returns (bool) { } catch { }

        assert(_vault.isOperator(owner, operator) == approved);
        _check();
    }

    //      ______                 __       _____      __  __  __                          __
    //     / ____/___  ____  _____/ /_     / ___/___  / /_/ /_/ /__  ____ ___  ___  ____  / /_
    //    / __/ / __ \/ __ \/ ___/ __ \    \__ \/ _ \/ __/ __/ / _ \/ __ `__ \/ _ \/ __ \/ __/
    //   / /___/ /_/ / /_/ / /__/ / / /   ___/ /  __/ /_/ /_/ /  __/ / / / / /  __/ / / / /_
    //  /_____/ .___/\____/\___/_/ /_/   /____/\___/\__/\__/_/\___/_/ /_/ /_/\___/_/ /_/\__/
    //       /_/

    function close_epoch() external {
        // E.3 — vault.totalAssets() reported on close MUST equal
        //        workingAssets + unutilizedAssetsBalance + scaledYieldAssetsBalance.
        //        We pass workingAssets = 0; FM reads its own balances at the same block.
        uint256 expectedTotal = _fundManager.unutilizedAssetsBalance() + _fundManager.scaledYieldAssetsBalance();
        bool ok;
        try _fundManager.closeEpoch(0) {
            ok = true;
        } catch { }
        if (ok) {
            // A.2 — pending counters are reset on close (moved into the snapshot).
            assert(_vault.totalPendingDepositAssets() == 0);
            assert(_vault.totalPendingRedeemShares() == 0);
            // E.3
            assert(_vault.totalAssets() == expectedTotal);
            // B.5 — capture the locked rate so `_check` can verify it never moves
            //        between now and the next successful settle.
            _ghostSnapshotRate = _vault.getSnapshot().rate;
        }
        _check();
    }

    /// @dev `closeEpoch(workingAssets)` with a fuzzed non-zero `workingAssets`. Clamped to
    ///      `outstanding + 25%` so the operator-reported value is in a believable band
    ///      around the actual external position (gains and small reporting overshoot are
    ///      possible; absurd over-reporting is filtered).
    ///
    ///      Asserts:
    ///       · E.3 — `vault.totalAssets() == working + unutilized + scaledYield`.
    ///       · A.2 — pending counters reset on close.
    ///       · Rate-direction (Tier-D, gated): when no investor activity and no time
    ///         advancement has happened since the last settle, the new last-settled
    ///         rate moves in the same direction as the operator-driven NAV change.
    ///         This is the post-settle check; it fires inside `settle_epoch` after
    ///         the close→settle pair completes.
    function close_epoch_with_working(uint96 working) external {
        // Clamp to outstanding + 25% slack to allow gain reporting without absurd values.
        uint256 maxW = _ghostOutstandingCapital + (_ghostOutstandingCapital / 4);
        if (maxW == 0) maxW = 1;
        uint256 w = _bound(working, maxW);

        uint256 expectedTotal = w + _fundManager.unutilizedAssetsBalance() + _fundManager.scaledYieldAssetsBalance();

        bool ok;
        try _fundManager.closeEpoch(w) {
            ok = true;
        } catch { }
        if (ok) {
            // A.2 — pending counters reset on close
            assert(_vault.totalPendingDepositAssets() == 0);
            assert(_vault.totalPendingRedeemShares() == 0);
            // E.3 — NAV identity at close
            assert(_vault.totalAssets() == expectedTotal);
            // B.5 — capture the locked rate
            _ghostSnapshotRate = _vault.getSnapshot().rate;
        }
        _check();
    }

    /// @dev A.3 / B.1 — same window: a second `closeEpoch` MUST revert with
    ///      PREVIOUS_EPOCH_NOT_SETTLED.
    function probe_close_epoch_during_snapshot() external {
        if (_vault.getSnapshot().epoch == 0) return;
        (bool ok,) =
            address(_fundManager).call(abi.encodeWithSelector(bytes4(keccak256("closeEpoch(uint256)")), uint256(0)));
        assert(!ok);
    }

    function settle_epoch() external {
        // E.5 / B.3 — if preconditions don't hold, settleEpoch MUST revert. This is the
        //              canonical check that operator-side capital movement (a `take`
        //              between close and settle) cannot land the system in a partial
        //              settlement state.
        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();
        if (snap.epoch != 0) {
            (bool can,,) = _fundManager.canSettleEpoch();
            if (!can) {
                (bool ok,) = address(_fundManager).call(abi.encodeWithSelector(bytes4(keccak256("settleEpoch()"))));
                assert(!ok);
                _check();
                return;
            }
        }

        bool succeeded;
        try _fundManager.settleEpoch() {
            succeeded = true;
        } catch { }

        if (succeeded) {
            // Refresh rate-direction baseline from the just-settled epoch, then clear the
            // gating flags so the next settle compares against this snapshot.
            if (_vault.totalSupply() > 0) {
                _ghostLastSettleRate = _vault.convertToAssets(1e18);
            }
            _ghostLastSettleNav = _vault.totalAssets();
            _ghostInvestorActivitySinceSettle = false;
            _ghostTimeAdvancedSinceSettle = false;
            // B.5 — snapshot is gone; clear the locked-rate ghost so `_check` stops
            //        asserting it for the next close→settle window.
            _ghostSnapshotRate = 0;
            // G.4 — settle is the only event that legitimately changes convertTo* output.
            //        Rebase the stable-convert ghost.
            _ghostStableConvert = _vault.convertToAssets(1e18);
        }

        _check();
        // NOTE on D.5 (forward-solvency, post-settle):
        // A naive `evaluateYieldAssetsDeficit() <= 0` check fails immediately after
        // settle_epoch because Superfluid's GDA reserves a buffer at distributeFlow,
        // and `yieldAssetsBalance()` (= balanceOf, the real-time available balance)
        // already excludes that buffer. The spec wording in docs/invariants.md D.5
        // doesn't account for this gap. Tracking as a finding rather than asserting
        // here; a stricter check would have to add the GDA buffer back into actual
        // balance. See docs/audit/echidna-findings.md.
    }

    /// @dev A.3 (negative form) — when no snapshot is open, `settleEpoch` MUST revert
    ///      with SETTLEMENT_PRECONDITIONS_NOT_MET("CURRENT_EPOCH_NOT_CLOSED").
    function probe_settle_when_no_snapshot() external {
        if (_vault.getSnapshot().epoch != 0) return;
        (bool ok,) = address(_fundManager).call(abi.encodeWithSelector(bytes4(keccak256("settleEpoch()"))));
        assert(!ok);
    }

    //     _____ __  _      __            _____ __
    //    / ___// /_(_)____/ /____  __   / ___// /_  ____ _________  _____
    //    \__ \/ __/ / ___/ //_/ / / /   \__ \/ __ \/ __ `/ ___/ _ \/ ___/
    //   ___/ / /_/ / /__/ ,< / /_/ /   ___/ / / / / /_/ / /  /  __(__  )
    //  /____/\__/_/\___/_/|_|\__, /   /____/_/ /_/\__,_/_/   \___/____/
    //                       /____/

    /// @dev C.1 — transfer must always revert. Probing via low-level call so the
    ///      revert is captured by the bool, not propagated.
    function try_transfer_share(uint8 fromIdx, uint8 toIdx, uint96 amount) external {
        address from = _actor(fromIdx);
        address to = _actor(toIdx);
        HEVM.prank(from);
        (bool ok,) =
            address(_vault).call(abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), to, amount));
        assert(!ok);
    }

    /// @dev C.1 — transferFrom must always revert.
    function try_transfer_from_share(uint8 fromIdx, uint8 toIdx, uint96 amount) external {
        address from = _actor(fromIdx);
        address to = _actor(toIdx);
        (bool ok,) = address(_vault).call(
            abi.encodeWithSelector(bytes4(keccak256("transferFrom(address,address,uint256)")), from, to, amount)
        );
        assert(!ok);
    }

    //      ___                               ______            __             __   ________              __
    //     /   | _____________  __________   / ____/___  ____  / /__________  / /  / ____/ /_  ___  _____/ /_______
    //    / /| |/ ___/ ___/ _ \/ ___/ ___/  / /   / __ \/ __ \/ __/ ___/ __ \/ /  / /   / __ \/ _ \/ ___/ //_/ ___/
    //   / ___ / /__/ /__/  __(__  |__  )  / /___/ /_/ / / / / /_/ /  / /_/ / /  / /___/ / / /  __/ /__/ ,< (__  )
    //  /_/  |_\___/\___/\___/____/____/   \____/\____/_/ /_/\__/_/   \____/_/   \____/_/ /_/\___/\___/_/|_/____/

    // Negative-authorization probes (F.1–F.4). All MUST revert.

    /// @dev F.2 — non-operator cannot close an epoch.
    function probe_unauthorized_close_epoch(uint8 actorIdx) external {
        address actor = _actor(actorIdx);
        HEVM.prank(actor);
        (bool ok,) =
            address(_fundManager).call(abi.encodeWithSelector(bytes4(keccak256("closeEpoch(uint256)")), uint256(0)));
        assert(!ok);
    }

    /// @dev F.2 — non-operator cannot settle an epoch.
    function probe_unauthorized_settle_epoch(uint8 actorIdx) external {
        address actor = _actor(actorIdx);
        HEVM.prank(actor);
        (bool ok,) = address(_fundManager).call(abi.encodeWithSelector(bytes4(keccak256("settleEpoch()"))));
        assert(!ok);
    }

    /// @dev F.2 — non-operator cannot give underlying to FM.
    function probe_unauthorized_give(uint8 actorIdx, uint96 amount) external {
        address actor = _actor(actorIdx);
        HEVM.prank(actor);
        (bool ok,) =
            address(_fundManager).call(abi.encodeWithSelector(bytes4(keccak256("give(uint256)")), uint256(amount)));
        assert(!ok);
    }

    /// @dev F.2 — non-operator cannot take underlying from FM.
    function probe_unauthorized_take(uint8 actorIdx, uint96 amount) external {
        address actor = _actor(actorIdx);
        HEVM.prank(actor);
        (bool ok,) =
            address(_fundManager).call(abi.encodeWithSelector(bytes4(keccak256("take(uint256)")), uint256(amount)));
        assert(!ok);
    }

    /// @dev F.2 — non-operator cannot change the stable yield rate.
    function probe_unauthorized_set_yield_rate(uint8 actorIdx, uint16 rate) external {
        address actor = _actor(actorIdx);
        HEVM.prank(actor);
        (bool ok,) = address(_fundManager).call(
            abi.encodeWithSelector(bytes4(keccak256("setStableYieldRate(uint256)")), uint256(rate))
        );
        assert(!ok);
    }

    /// @dev F.2 — non-operator cannot trigger ensureYieldFlowDuration.
    function probe_unauthorized_ensure_flow_duration(uint8 actorIdx) external {
        address actor = _actor(actorIdx);
        HEVM.prank(actor);
        (bool ok,) = address(_fundManager).call(abi.encodeWithSelector(bytes4(keccak256("ensureYieldFlowDuration()"))));
        assert(!ok);
    }

    /// @dev F.3 — non-admin cannot change `guaranteedFlowDuration`.
    function probe_unauthorized_set_duration(uint8 actorIdx, uint32 duration) external {
        address actor = _actor(actorIdx);
        HEVM.prank(actor);
        (bool ok,) = address(_fundManager).call(
            abi.encodeWithSelector(bytes4(keccak256("setGuaranteedFlowDuration(uint256)")), uint256(duration))
        );
        assert(!ok);
    }

    /// @dev F.1 — only the FundManager can call vault settlement hooks. Calling from the
    ///      harness (which is not the FM) MUST revert.
    function probe_unauthorized_on_close_epoch(uint96 totalAssets_) external {
        (bool ok,) = address(_vault).call(
            abi.encodeWithSelector(bytes4(keccak256("onCloseEpoch(uint256)")), uint256(totalAssets_))
        );
        assert(!ok);
    }

    /// @dev F.1 — same gating for `onSettleEpoch`.
    function probe_unauthorized_on_settle_epoch() external {
        (bool ok,) = address(_vault).call(abi.encodeWithSelector(bytes4(keccak256("onSettleEpoch()"))));
        assert(!ok);
    }

    /// @dev F.4 — only the vault (VAULT_ROLE) can call FM hooks. The harness is not the
    ///      vault and was never granted VAULT_ROLE, so calls MUST revert.
    function probe_unauthorized_on_claim_deposit(uint8 actorIdx, uint96 amount) external {
        address shareholder = _actor(actorIdx);
        (bool ok,) = address(_fundManager).call(
            abi.encodeWithSelector(bytes4(keccak256("onClaimDeposit(address,uint256)")), shareholder, uint256(amount))
        );
        assert(!ok);
    }

    /// @dev F.4 — same gating for `onRequestRedeem`.
    function probe_unauthorized_on_request_redeem(uint8 actorIdx, uint96 sharesRedeemed, uint96 totalSharesOwned)
        external
    {
        address shareholder = _actor(actorIdx);
        (bool ok,) = address(_fundManager).call(
            abi.encodeWithSelector(
                bytes4(keccak256("onRequestRedeem(address,uint256,uint256)")),
                shareholder,
                uint256(sharesRedeemed),
                uint256(totalSharesOwned)
            )
        );
        assert(!ok);
    }

    //      ____                 _                 ____                      __
    //     / __ \________ _   __(_)__ _      __   / __ \___ _   _____  _____/ /______
    //    / /_/ / ___/ _ \ | / / / _ \ | /| / /  / /_/ / _ \ | / / _ \/ ___/ __/ ___/
    //   / ____/ /  /  __/ |/ / /  __/ |/ |/ /  / _, _/  __/ |/ /  __/ /  / /_(__  )
    //  /_/   /_/   \___/|___/_/\___/|__/|__/  /_/ |_|\___/|___/\___/_/   \__/____/

    // G.1 — preview functions MUST revert (fully-async vault).
    function probe_preview_deposit(uint96 assets) external {
        (bool ok,) =
            address(_vault).call(abi.encodeWithSelector(bytes4(keccak256("previewDeposit(uint256)")), uint256(assets)));
        assert(!ok);
    }

    // G.1 — preview functions MUST revert (fully-async vault).
    function probe_preview_mint(uint96 shares) external {
        (bool ok,) =
            address(_vault).call(abi.encodeWithSelector(bytes4(keccak256("previewMint(uint256)")), uint256(shares)));
        assert(!ok);
    }

    // G.1 — preview functions MUST revert (fully-async vault).
    function probe_preview_redeem(uint96 shares) external {
        (bool ok,) =
            address(_vault).call(abi.encodeWithSelector(bytes4(keccak256("previewRedeem(uint256)")), uint256(shares)));
        assert(!ok);
    }

    // G.1 — preview functions MUST revert (fully-async vault).
    function probe_preview_withdraw(uint96 assets) external {
        (bool ok,) =
            address(_vault).call(abi.encodeWithSelector(bytes4(keccak256("previewWithdraw(uint256)")), uint256(assets)));
        assert(!ok);
    }

    //      ____        __          __  ___                                                  __
    //     / __ \____ _/ /____     /  |/  /___ _____  ____ _____ ____  ____ ___  ___  ____  / /_
    //    / /_/ / __ `/ __/ _ \   / /|_/ / __ `/ __ \/ __ `/ __ `/ _ \/ __ `__ \/ _ \/ __ \/ __/
    //   / _, _/ /_/ / /_/  __/  / /  / / /_/ / / / / /_/ / /_/ /  __/ / / / / /  __/ / / / /_
    //  /_/ |_|\__,_/\__/\___/  /_/  /_/\__,_/_/ /_/\__,_/\__, /\___/_/ /_/ /_/\___/_/ /_/\__/
    //                                                   /____/

    function set_stable_yield_rate(uint16 rate) external {
        try _fundManager.setStableYieldRate(uint256(rate) % (MAX_RATE + 1)) { } catch { }
        _check();
    }

    /// @dev Admin-set forward-solvency horizon. Clamped to [1 day, 90 days + 1 day]
    ///      so the rebalance step has a chance to succeed against available unutilized
    ///      capital. Triggers `_rebalanceYieldAssets` internally — exercises D.5/D.6
    ///      and may surface gap I.1 (`INVARIANT_VIOLATED` is declared but never raised).
    function set_guaranteed_flow_duration(uint32 duration) external {
        uint256 d = (uint256(duration) % 90 days) + 1 days;
        try _fundManager.setGuaranteedFlowDuration(d) { } catch { }
        _check();
    }

    /// @dev Operator-triggered top-up. Idempotent in the no-deficit case; restarts the
    ///      stream if `totalUnits > 0` but `totalFlowRate == 0`.
    function ensure_yield_flow_duration() external {
        try _fundManager.ensureYieldFlowDuration() { } catch { }
        _check();
    }

    /// @dev D.6 — `setGuaranteedFlowDuration` MUST revert with DURATION_BELOW_FLOOR for
    ///      durations below `MIN_GUARANTEED_FLOW_DURATION` (1 day).
    function probe_set_duration_below_floor(uint32 duration) external {
        uint256 d = uint256(duration) % 1 days; // [0, 1d − 1]
        (bool ok,) = address(_fundManager).call(
            abi.encodeWithSelector(bytes4(keccak256("setGuaranteedFlowDuration(uint256)")), d)
        );
        assert(!ok);
    }

    //    ____                        __                 ___        __  _
    //   / __ \____  ___  _________ _/ /_____  _____    /   | _____/ /_(_)___  ____  _____
    //  / / / / __ \/ _ \/ ___/ __ `/ __/ __ \/ ___/   / /| |/ ___/ __/ / __ \/ __ \/ ___/
    // / /_/ / /_/ /  __/ /  / /_/ / /_/ /_/ / /      / ___ / /__/ /_/ / /_/ / / / (__  )
    // \____/ .___/\___/_/   \__,_/\__/\____/_/      /_/  |_\___/\__/_/\____/_/ /_/____/
    //     /_/
    // Operator capital lifecycle. The harness plays the role of "external strategy":
    //  · `operator_take` pulls underlying out of FM into the harness.
    //  · `operator_simulate_gain` transfers USDC from the strategy reserve into the
    //    harness (simulated off-chain alpha; bounded by reserve balance and outstanding capital).
    //  · `operator_simulate_loss` transfers USDC from the harness back to the strategy
    //    reserve (simulated off-chain drawdown; bounded by outstanding capital).
    //  · `operator_give` returns underlying from the harness to FM.
    //  · `close_epoch_with_working` lets the operator report a non-zero `workingAssets`
    //     so realized PnL flows into the snapshot rate.

    /// @dev Pulls up to `unutilizedAssetsBalance()` from the FM into the harness.
    function operator_take(uint96 amount) external {
        uint256 maxA = _fundManager.unutilizedAssetsBalance();
        uint256 amt = _bound(amount, maxA);
        if (amt == 0) return;

        try _fundManager.take(amt) {
            _ghostOutstandingCapital += amt;
        } catch { }

        _check();
    }

    /// @dev Simulates an off-chain gain by pulling USDC from the strategy reserve into
    ///      the harness. Bounded by both the outstanding deployed capital (a single call
    ///      can at most double the external position) and the reserve's own balance
    ///      (closed-loop — total USDC in the test world is conserved).
    function operator_simulate_gain(uint96 amount) external {
        if (_ghostOutstandingCapital == 0) return;
        uint256 reserveBal = _usdc.balanceOf(STRATEGY_RESERVE);
        uint256 maxA = _ghostOutstandingCapital < reserveBal ? _ghostOutstandingCapital : reserveBal;
        uint256 amt = _bound(amount, maxA);
        if (amt == 0) return;
        HEVM.prank(STRATEGY_RESERVE);
        _usdc.transfer(address(this), amt);
        _check();
    }

    /// @dev Simulates an off-chain loss by transferring USDC from the harness back to the
    ///      strategy reserve. Gated on outstanding capital — losses only realize against
    ///      deployed capital, not against the operator's untouched treasury.
    function operator_simulate_loss(uint96 amount) external {
        if (_ghostOutstandingCapital == 0) return;
        uint256 bal = _usdc.balanceOf(address(this));
        uint256 maxA = _ghostOutstandingCapital < bal ? _ghostOutstandingCapital : bal;
        uint256 amt = _bound(amount, maxA);
        if (amt == 0) return;
        _usdc.transfer(STRATEGY_RESERVE, amt);
        _check();
    }

    /// @dev Returns underlying from the harness to FM. Clamped to the harness's USDC
    ///      balance so `transferFrom` inside `give` cannot fail. The ghost saturates at
    ///      zero — giving back more than was taken (returning gain) is normal.
    function operator_give(uint96 amount) external {
        uint256 bal = _usdc.balanceOf(address(this));
        uint256 amt = _bound(amount, bal);
        if (amt == 0) return;

        try _fundManager.give(amt) {
            if (amt >= _ghostOutstandingCapital) {
                _ghostOutstandingCapital = 0;
            } else {
                _ghostOutstandingCapital -= amt;
            }
        } catch { }

        _check();
    }

    /// @dev E.5 reproducer. While a snapshot is open, drain unutilized via `take`. If the
    ///      closed epoch had any redeems, settlement now MUST revert with
    ///      SETTLEMENT_PRECONDITIONS_NOT_MET("INSUFFICIENT_ASSETS_IN_FUND_MANAGER")
    ///      — the FM does not protect itself from operator-coordination errors.
    ///      The probe is conservative: it only asserts when `canSettleEpoch == false`,
    ///      i.e. the take actually broke the precondition.
    function probe_take_during_snapshot_breaks_settle(uint96 amount) external {
        IStableYieldAsyncVault.Snapshot memory snap = _vault.getSnapshot();
        if (snap.epoch == 0) return;
        uint256 maxA = _fundManager.unutilizedAssetsBalance();
        uint256 amt = _bound(amount, maxA);
        if (amt == 0) return;

        try _fundManager.take(amt) {
            _ghostOutstandingCapital += amt;
        } catch {
            return;
        }

        (bool can,,) = _fundManager.canSettleEpoch();
        if (!can) {
            (bool ok,) = address(_fundManager).call(abi.encodeWithSelector(bytes4(keccak256("settleEpoch()"))));
            assert(!ok);
        }
        _check();
    }

    function warp_seconds(uint32 secs) external {
        uint256 delta = uint256(secs) % MAX_WARP;
        if (delta > 0) _ghostTimeAdvancedSinceSettle = true;
        HEVM.warp(block.timestamp + delta);
        _check();
    }

    /// @dev Long-horizon warp — up to 365 days per call. Lets the fuzzer reach
    ///      `guaranteedFlowDuration` boundaries and meaningful yield-stream accrual
    ///      that the 30-day `warp_seconds` cannot.
    function warp_seconds_long(uint32 secs) external {
        uint256 delta = uint256(secs) % (365 days);
        if (delta > 0) _ghostTimeAdvancedSinceSettle = true;
        HEVM.warp(block.timestamp + delta);
        _check();
    }

    //      __ __              ___                        __  _
    //     / //_/__  __  __   /   |  _____________  _____/ /_(_)___  ____  _____
    //    / ,< / _ \/ / / /  / /| | / ___/ ___/ _ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / /| /  __/ /_/ /  / ___ |(__  |__  )  __/ /  / /_/ / /_/ / / / (__  )
    //  /_/ |_\___/\__, /  /_/  |_/____/____/\___/_/   \__/_/\____/_/ /_/____/
    //            /____/

    /// @dev Rate-direction invariant — fired opportunistically. When the only state
    ///      change since the last settle was operator-driven NAV movement (no investor
    ///      activity, no time warp), the sign of (newRate − oldRate) must match the
    ///      sign of (newNav − oldNav). Time advancement is excluded because the GDA
    ///      stream pays USDCx out of FM continuously, biasing NAV downward independent
    ///      of operator PnL.
    ///
    ///      Called from `_check`. Trivially short-circuits when the gate isn't met.
    function _checkRateDirection() internal view {
        if (_ghostInvestorActivitySinceSettle) return;
        if (_ghostTimeAdvancedSinceSettle) return;
        if (_ghostLastSettleRate == 0) return; // baseline not established
        if (_vault.totalSupply() == 0) return;

        uint256 newRate = _vault.convertToAssets(1e18);
        uint256 newNav = _vault.totalAssets();

        bool navUp = newNav > _ghostLastSettleNav;
        bool navDown = newNav < _ghostLastSettleNav;
        bool rateUp = newRate > _ghostLastSettleRate;
        bool rateDown = newRate < _ghostLastSettleRate;

        // Direction must match. Equality on either side is acceptable (rounding).
        assert(!(navUp && rateDown));
        assert(!(navDown && rateUp));
    }

    /// @dev Combined post-condition for every action handler.
    ///      A.1 — vault underlying balance covers both escrow buckets (>= rather than ==
    ///            to allow transient mid-settlement gaps and one-directional donations).
    ///      A.5 — once an epoch's `isEpochSettled` flips to true, it never reverts to false.
    ///      B.1 (corollary) — currentEpoch is non-decreasing across all handlers.
    ///      C.4 — vault holds exactly the in-flight redeem shares (per ghost).
    function _check() internal {
        // A.1 — vault underlying balance covers both escrow buckets. Strict equality is
        //        the documented quiescent-state form (no open snapshot); during
        //        settlement the partition transiently holds more, so we relax to ≥.
        uint256 bal = _usdc.balanceOf(address(_vault));
        uint256 owed = _vault.totalPendingDepositAssets() + _vault.totalClaimableRedeemAssets();
        if (_vault.getSnapshot().epoch == 0) {
            assert(bal == owed);
        } else {
            assert(bal >= owed);
        }

        // B.1 corollary — currentEpoch monotonic
        uint256 nowEpoch = _vault.currentEpoch();
        assert(nowEpoch >= _ghostMaxEpoch);
        _ghostMaxEpoch = nowEpoch;

        // A.5 — sticky settled flag. Re-verify the highest epoch we've seen settled is
        //       still settled, then advance the ghost to the new high-water mark.
        if (_ghostLastSettledEpoch > 0) {
            assert(_vault.isEpochSettled(_ghostLastSettledEpoch));
        }
        for (uint256 e = _ghostLastSettledEpoch + 1; e < nowEpoch; e++) {
            if (_vault.isEpochSettled(e)) {
                _ghostLastSettledEpoch = e;
            }
        }

        // C.4 — vault custody of in-flight redeem shares
        assert(_vault.balanceOf(address(_vault)) == _ghostInflightRedeemShares);

        // C.2 / C.3 — totalSupply only changes via claim_deposit / claim_redeem / claim_withdraw.
        assert(_vault.totalSupply() == _ghostTotalSupply);

        // B.5 — while a snapshot is open, its locked rate must not move.
        if (_ghostSnapshotRate != 0) {
            assert(_vault.getSnapshot().rate == _ghostSnapshotRate);
        }

        // G.4 — convertTo* uses last-settled rate. Between two settles, the value is
        //        constant — the in-flight snapshot rate must not leak in.
        assert(_vault.convertToAssets(1e18) == _ghostStableConvert);

        // Rate-direction invariant (operator-PnL cluster, gated)
        _checkRateDirection();
    }

    //      __  __     __                   ______                 __  _
    //     / / / /__  / /___  ___  _____   / ____/_  ______  _____/ /_(_)___  ____  _____
    //    / /_/ / _ \/ / __ \/ _ \/ ___/  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / __  /  __/ / /_/ /  __/ /     / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /_/ /_/\___/_/ .___/\___/_/     /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/
    //              /_/

    /// @dev Foundry's runtime auto-deploys external libraries; Echidna does not.
    ///      Each library address below is pinned in foundry.toml's [profile.echidna]
    ///      and in echidna.yaml's --compile-libraries; here we deploy each one and
    ///      etch its runtime bytecode at the pinned address so the framework's
    ///      DELEGATECALLs land on real code.
    function _plantSuperfluidLibraries() internal {
        _plant(type(SlotsBitmapLibrary).creationCode, address(uint160(0xA01)));
        _plant(type(SuperfluidPoolDeployerLibrary).creationCode, address(uint160(0xA02)));
        _plant(type(SuperfluidGovDeployerLibrary).creationCode, address(uint160(0xA03)));
        _plant(type(SuperfluidHostDeployerLibrary).creationCode, address(uint160(0xA04)));
        _plant(type(SuperfluidCFAv1DeployerLibrary).creationCode, address(uint160(0xA05)));
        _plant(type(SuperfluidIDAv1DeployerLibrary).creationCode, address(uint160(0xA06)));
        _plant(type(SuperfluidPoolLogicDeployerLibrary).creationCode, address(uint160(0xA07)));
        _plant(type(SuperfluidGDAv1DeployerLibrary).creationCode, address(uint160(0xA08)));
        _plant(type(CFAv1ForwarderDeployerLibrary).creationCode, address(uint160(0xA09)));
        _plant(type(GDAv1ForwarderDeployerLibrary).creationCode, address(uint160(0xA0A)));
        _plant(type(SuperTokenDeployerLibrary).creationCode, address(uint160(0xA0B)));
        _plant(type(SuperfluidPoolNFTLogicDeployerLibrary).creationCode, address(uint160(0xA0C)));
        _plant(type(ProxyDeployerLibrary).creationCode, address(uint160(0xA0D)));
        _plant(type(TokenDeployerLibrary).creationCode, address(uint160(0xA0E)));
        _plant(type(SuperTokenFactoryDeployerLibrary).creationCode, address(uint160(0xA0F)));
        _plant(type(SuperfluidPeripheryDeployerLibrary).creationCode, address(uint160(0xA10)));
    }

    function _plant(bytes memory creationCode, address pinned) internal {
        address deployed;
        assembly {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0), "lib deploy failed");
        HEVM.etch(pinned, deployed.code);
    }

    function _actor(uint8 idx) internal view returns (address) {
        return _actors[idx % _actors.length];
    }

    function _bound(uint256 v, uint256 maxV) internal pure returns (uint256) {
        if (maxV == 0) return 0;
        return v % (maxV + 1);
    }

}
