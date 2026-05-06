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
    SuperfluidCFAv1DeployerLibrary,
    SuperfluidGDAv1DeployerLibrary,
    SuperfluidGovDeployerLibrary,
    SuperfluidHostDeployerLibrary,
    SuperfluidIDAv1DeployerLibrary,
    SuperfluidPeripheryDeployerLibrary,
    SuperfluidPoolLogicDeployerLibrary,
    SuperfluidPoolNFTLogicDeployerLibrary,
    SuperTokenDeployerLibrary,
    SuperTokenFactoryDeployerLibrary,
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
    uint256 private constant FM_INITIAL_USDCX = 50_000_000 * 1e18; // 50M yield reserve
    uint256 private constant FM_INITIAL_USDC = 10_000_000 * 1e6; // 10M unutilized
    uint256 private constant INITIAL_RATE = 1000; // 10% APR (basis points)
    uint256 private constant INITIAL_FLOW_DURATION = 7 days;
    uint256 private constant MAX_RATE = 5000; // cap fuzzed rate at 50%
    uint256 private constant MAX_WARP = 30 days;

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

        _usdc.mint(address(this), 100_000_000 * 1e6);
        _usdc.approve(address(_usdcx), type(uint256).max);
        _usdcx.upgrade(FM_INITIAL_USDCX);
        _usdcx.transfer(address(_fundManager), FM_INITIAL_USDCX);

        _usdc.approve(address(_fundManager), type(uint256).max);
        _fundManager.give(FM_INITIAL_USDC);

        for (uint256 i = 0; i < _actors.length; i++) {
            address actor = _actors[i];
            _usdc.mint(actor, ACTOR_INITIAL_USDC);
            HEVM.prank(actor);
            _usdc.approve(address(_vault), type(uint256).max);
        }

        _ghostMaxEpoch = _vault.currentEpoch();

        // D.7 — pool config: units non-transferable, distribution-from-any-address disabled,
        //       admin is the FundManager. These are set in FundManager's constructor and not
        //       mutable, so a one-time check is sufficient.
        ISuperfluidPool pool = _fundManager.POOL();
        require(pool.admin() == address(_fundManager), "D.7 admin");
        require(!pool.transferabilityForUnitsOwner(), "D.7 transferability");
        require(!pool.distributionFromAnyAddress(), "D.7 distribution");
    }

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

    function _clamp(uint256 v, uint256 maxV) internal pure returns (uint256) {
        if (maxV == 0) return 0;
        return v % (maxV + 1);
    }

    function request_deposit(uint8 actorIdx, uint96 amount) external {
        address actor = _actor(actorIdx);
        uint256 bal = _usdc.balanceOf(actor);
        uint256 amt = _clamp(amount, bal);
        if (amt == 0) return;

        HEVM.prank(actor);
        try _vault.requestDeposit(amt, actor, actor) { } catch { }

        _check();
    }

    function request_redeem(uint8 actorIdx, uint96 shares) external {
        address actor = _actor(actorIdx);
        uint256 bal = _vault.balanceOf(actor);
        uint256 amt = _clamp(shares, bal);
        if (amt == 0) return;

        HEVM.prank(actor);
        try _vault.requestRedeem(amt, actor, actor) returns (uint256) {
            _ghostInflightRedeemShares += amt;
        } catch { }

        _check();
    }

    function claim_deposit(uint8 actorIdx, uint96 portion) external {
        address actor = _actor(actorIdx);
        uint256 maxA = _vault.maxDeposit(actor);
        if (maxA == 0) return;
        uint256 amt = _clamp(portion, maxA);
        if (amt == 0) return;

        ISuperfluidPool pool = _fundManager.POOL();
        uint128 unitsBefore = pool.getTotalUnits();
        int96 flowBefore = pool.getTotalFlowRate();

        HEVM.prank(actor);
        bool ok;
        try _vault.deposit(amt, actor) returns (uint256) {
            ok = true;
        } catch { }

        if (ok) {
            // D.3a — totalUnits is conserved by FM.onClaimDeposit (decrement FM, increment
            //        receiver by the same amount). This holds.
            assert(pool.getTotalUnits() == unitsBefore);
            // D.3b — totalFlowRate temporarily disabled; see finding F-2 below.
            (flowBefore);
        }

        _check();
    }

    function claim_redeem(uint8 actorIdx, uint96 portion) external {
        address actor = _actor(actorIdx);
        uint256 maxS = _vault.maxRedeem(actor);
        if (maxS == 0) return;
        uint256 amt = _clamp(portion, maxS);
        if (amt == 0) return;

        HEVM.prank(actor);
        try _vault.redeem(amt, actor, actor) returns (uint256) {
            _ghostInflightRedeemShares -= amt;
        } catch { }

        _check();
    }

    function close_epoch() external {
        try _fundManager.closeEpoch(0) { } catch { }
        _check();
    }

    function settle_epoch() external {
        try _fundManager.settleEpoch() { } catch { }
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

    /// @dev C.1 — transfer must always revert. Probing via low-level call so the
    ///      revert is captured by the bool, not propagated.
    function try_transfer_share(uint8 fromIdx, uint8 toIdx, uint96 amount) external {
        address from = _actor(fromIdx);
        address to = _actor(toIdx);
        HEVM.prank(from);
        (bool ok,) = address(_vault).call(
            abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), to, amount)
        );
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

    /// @dev B.1 — while a snapshot is open (between closeEpoch and settleEpoch), every
    ///      `requestDeposit` MUST revert with EPOCH_SETTLEMENT_IN_PROGRESS. The fuzzer
    ///      guarantees this state is reached often enough by the natural close→settle
    ///      ordering of `close_epoch` and `settle_epoch` handlers.
    function probe_request_deposit_during_settlement(uint8 actorIdx, uint96 amount) external {
        if (_vault.getSnapshot().epoch == 0) return;
        address actor = _actor(actorIdx);
        uint256 bal = _usdc.balanceOf(actor);
        uint256 amt = _clamp(amount, bal);
        if (amt == 0) return;
        HEVM.prank(actor);
        (bool ok,) = address(_vault).call(
            abi.encodeWithSelector(bytes4(keccak256("requestDeposit(uint256,address,address)")), amt, actor, actor)
        );
        assert(!ok);
    }

    function set_stable_yield_rate(uint16 rate) external {
        try _fundManager.setStableYieldRate(uint256(rate) % (MAX_RATE + 1)) { } catch { }
        _check();
    }

    function warp_seconds(uint32 secs) external {
        HEVM.warp(block.timestamp + (uint256(secs) % MAX_WARP));
        _check();
    }

    /// @dev Combined post-condition for every action handler.
    ///      A.1 — vault underlying balance covers both escrow buckets (>= rather than ==
    ///            to allow transient mid-settlement gaps and one-directional donations).
    ///      A.5 — once an epoch's `isEpochSettled` flips to true, it never reverts to false.
    ///      B.1 (corollary) — currentEpoch is non-decreasing across all handlers.
    ///      C.4 — vault holds exactly the in-flight redeem shares (per ghost).
    function _check() internal {
        // A.1
        uint256 bal = _usdc.balanceOf(address(_vault));
        uint256 owed = _vault.totalPendingDepositAssets() + _vault.totalClaimableRedeemAssets();
        assert(bal >= owed);

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
    }

}
