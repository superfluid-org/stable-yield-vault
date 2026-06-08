// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { MockERC4626 } from "../mocks/MockERC4626.sol";

import { EchidnaVaultHarnessBase, ISuperfluidPool } from "./base/EchidnaVaultHarnessBase.sol";

import { IERC20 } from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";

import { StableYieldSyncVault } from "src/vault/sync/StableYieldSyncVault.sol";
import { SyncFundManager } from "src/vault/sync/SyncFundManager.sol";

/// @title Echidna fuzzing harness for the synchronous StableYieldSyncVault + SyncFundManager pair.
/// @dev   Inherits the shared Superfluid bootstrap from `EchidnaVaultHarnessBase`, deploys the sync
///        vault + SyncFundManager + a configurable external ERC-4626 in its constructor, and exposes
///        clamped handlers for every mutating entrypoint. Invariants from
///        `docs/sync-vault/design.md §Invariants` are checked after every handler.
contract EchidnaStableYieldSyncVault is EchidnaVaultHarnessBase {

    uint256 private constant EXTERNAL_RESERVE_INITIAL = 100_000_000 * 1e6; // funds simulated external yield
    // Operator-diligence assumption (design D.1): the operator calls `ensureYieldFlowDuration()`
    // within every `guaranteedFlowDuration` window, so the reserve never over-drains to insolvency.
    // We model it by (a) the `keepAlive` modifier replenishing before every op, and (b) bounding
    // every time advance below the `MIN_GUARANTEED_FLOW_DURATION` (= 1 day) floor — both the explicit
    // `warp_seconds` cap here AND echidna's inter-call `maxTimeDelay` (see `echidna.sync.yaml`). A single
    // warp (≤ 6h) plus the following inter-call delay (≤ 6h) stays well under the 1-day horizon.
    uint256 private constant MAX_WARP = 6 hours;

    /// @dev Closed-loop pool funding simulated external gains / absorbing simulated losses.
    address private constant EXTERNAL_RESERVE = address(uint160(uint256(keccak256("ECHIDNA_SYNC_EXT_RESERVE"))));

    MockERC4626 private _external;
    SyncFundManager private _fundManager;
    StableYieldSyncVault private _vault;

    /// @dev Mirror of `totalSupply`, updated only by mint/burn handlers.
    uint256 private _ghostSupply;

    constructor() {
        _bootstrapSuperfluid("ECHIDNA_SYNC_ALICE", "ECHIDNA_SYNC_BOB", "ECHIDNA_SYNC_CAROL", "ECHIDNA_SYNC_TREASURY");

        _external = new MockERC4626(IERC20(address(_usdc)), "Mock External USDC Vault", "mxUSDC");

        _vault = new StableYieldSyncVault(
            _treasury,
            address(_usdc),
            address(_usdcx),
            address(_external),
            address(this), // operator
            address(this), // admin
            INITIAL_RATE,
            INITIAL_FLOW_DURATION,
            "Echidna Sync Vault Share",
            "ESVS"
        );
        _fundManager = SyncFundManager(address(_vault.FUND_MANAGER()));

        _approveActorsTo(address(_vault));

        // Operator injection treasury.
        _seedOperatorTreasury(address(_fundManager));

        // Closed-loop external-yield reserve.
        _usdc.mint(EXTERNAL_RESERVE, EXTERNAL_RESERVE_INITIAL);
        HEVM.prank(EXTERNAL_RESERVE);
        _usdc.approve(address(this), type(uint256).max);

        // D.7-equivalent: pool config is immutable, one-time check.
        _assertPoolConfig(_fundManager.YIELD_POOL(), address(_fundManager));
    }

    /// @dev Models the operator-diligence assumption (design D.1): a keeper runs
    ///      `ensureYieldFlowDuration()` (operator-only; `address(this)` holds the role) before every
    ///      op, so the reserve is topped up and never sits insolvent when a user op's
    ///      `_recalibrateFlow()` fires. Combined with the sub-horizon time-advance cap, this is what
    ///      makes the F.2 no-brick guarantee on withdraw/redeem hold. Allowed to revert (terminal
    ///      impairment) — swallowed, since the keeper can't help there either.
    modifier keepAlive() {
        try _fundManager.ensureYieldFlowDuration() { } catch { }
        _;
    }

    //      ____                        _ __     ___        __  _
    //     / __ \___  ____  ____  _____(_) /_   /   | _____/ /_(_)___  ____  _____
    //    / / / / _ \/ __ \/ __ \/ ___/ / __/  / /| |/ ___/ __/ / __ \/ __ \/ ___/
    //   / /_/ /  __/ /_/ / /_/ (__  ) / /_   / ___ / /__/ /_/ / /_/ / / / (__  )
    //  /_____/\___/ .___/\____/____/_/\__/  /_/  |_\___/\__/_/\____/_/ /_/____/
    //            /_/

    function deposit(uint8 actorIdx, uint96 amount) external keepAlive {
        address actor = _actor(actorIdx);
        // Bound to `maxDeposit` so the common path is in-bounds; a deposit may still legitimately
        // revert (see below), which the try/catch tolerates.
        uint256 amt = _bound(amount, _min(_usdc.balanceOf(actor), _vault.maxDeposit(actor)));
        if (amt == 0) return;

        ISuperfluidPool pool = _fundManager.YIELD_POOL();
        uint128 unitsBefore = pool.getUnits(actor);
        (address by, uint256 yBefore, uint256 bufBefore) = _bystander(actor);

        HEVM.prank(actor);
        // NO hard no-brick assertion on deposit: `onDeposit` ends with an *unconditional*
        // `_recalibrateFlow()`, which raises the flow rate and so needs GDA buffer. Under
        // near-terminal external impairment (reserve drained, `ext.maxWithdraw(FM)` tiny but > 0,
        // so the vault is not yet paused by D.2) that recalibrate can revert. Deposit no-brick is
        // therefore NOT a hard invariant (see invariants.md F.2 — the guarantee is withdraw/redeem
        // side only). Swallow and let `_check()` validate the resting state.
        try _vault.deposit(amt, actor) returns (uint256 shares) {
            _ghostSupply += shares;
            // C.1: a non-dust deposit grants the receiver yield units at deposit time.
            if (amt >= _fundManager.RAW_PER_UNIT()) {
                assert(pool.getUnits(actor) > unitsBefore);
            }
            _assertNotDiluted(by, yBefore, bufBefore); // B.3
        } catch { }

        _check();
    }

    function mint(uint8 actorIdx, uint96 shares) external keepAlive {
        address actor = _actor(actorIdx);
        uint256 maxShares = _vault.maxMint(actor);
        uint256 actorCap = _vault.convertToShares(_usdc.balanceOf(actor));
        uint256 s = _bound(shares, _min(maxShares, actorCap));
        if (s == 0) return;

        (address by, uint256 yBefore, uint256 bufBefore) = _bystander(actor);

        HEVM.prank(actor);
        // Deposit-equivalent: no hard no-brick assertion (same unconditional-recalibrate reason as
        // `deposit`).
        try _vault.mint(s, actor) returns (uint256) {
            _ghostSupply += s;
            _assertNotDiluted(by, yBefore, bufBefore); // B.3
        } catch { }

        _check();
    }

    function withdraw(uint8 actorIdx, uint96 amount) external keepAlive {
        address actor = _actor(actorIdx);
        uint256 amt = _bound(amount, _vault.maxWithdraw(actor));
        if (amt == 0) return;

        uint256 balBefore = _usdc.balanceOf(actor);
        (address by, uint256 yBefore, uint256 bufBefore) = _bystander(actor);

        HEVM.prank(actor);
        // F.2: a request within `maxWithdraw` must NEVER brick. Shares-proportional reserve
        // sourcing bounds the external leg at `ext.maxWithdraw(FM)`, and the closing
        // `_recalibrateFlow()` only *lowers* the flow rate (releases GDA buffer, cannot revert from
        // a drained reserve). The external mock is compliant, so a revert here is a real bug.
        try _vault.withdraw(amt, actor, actor) returns (uint256 burned) {
            _ghostSupply -= burned;
            assert(_usdc.balanceOf(actor) - balBefore == amt); // B.4: pays exactly
            _assertNotDiluted(by, yBefore, bufBefore); // B.3
        } catch {
            assert(false); // F.2 violated
        }

        _check();
    }

    function redeem(uint8 actorIdx, uint96 shares) external keepAlive {
        address actor = _actor(actorIdx);
        uint256 s = _bound(shares, _vault.maxRedeem(actor));
        if (s == 0) return;

        uint256 balBefore = _usdc.balanceOf(actor);
        (address by, uint256 yBefore, uint256 bufBefore) = _bystander(actor);

        HEVM.prank(actor);
        // F.2: a request within `maxRedeem` must NEVER brick (see `withdraw`).
        try _vault.redeem(s, actor, actor) returns (uint256 assets) {
            _ghostSupply -= s;
            assert(_usdc.balanceOf(actor) - balBefore == assets); // B.4: pays exactly
            _assertNotDiluted(by, yBefore, bufBefore); // B.3
        } catch {
            assert(false); // F.2 violated
        }

        _check();
    }

    /// @dev Pure entry+exit round-trip in a single tx (no warp, no external move between the legs).
    ///      A depositor who immediately redeems must NOT come out ahead — rounding favours the
    ///      vault. A profit would signal share-price manipulation / first-deposit inflation.
    function roundtrip_deposit_redeem(uint8 actorIdx, uint96 amount) external keepAlive {
        address actor = _actor(actorIdx);
        uint256 amt = _bound(amount, _min(_usdc.balanceOf(actor), _vault.maxDeposit(actor)));
        if (amt == 0) return;

        uint256 balBefore = _usdc.balanceOf(actor);

        HEVM.prank(actor);
        try _vault.deposit(amt, actor) returns (uint256 shares) {
            _ghostSupply += shares;
            // Redeem the just-minted shares right back (only if in-bounds — a successful deposit
            // leaves the vault unpaused, so `maxRedeem >= shares` save for extreme rounding).
            if (shares > 0 && shares <= _vault.maxRedeem(actor)) {
                HEVM.prank(actor);
                try _vault.redeem(shares, actor, actor) returns (uint256 assetsOut) {
                    _ghostSupply -= shares;
                    assert(assetsOut <= amt); // no value extracted on a round-trip
                    assert(_usdc.balanceOf(actor) <= balBefore); // net non-positive
                } catch {
                    assert(false); // F.2: an in-bounds redeem must land
                }
            }
        } catch { }

        _check();
    }

    function transfer_shares(uint8 fromIdx, uint8 toIdx, uint96 shares) external keepAlive {
        address from = _actor(fromIdx);
        address to = _actor(toIdx);
        if (from == to) return;
        uint256 s = _bound(shares, _vault.balanceOf(from));
        if (s == 0) return;

        ISuperfluidPool pool = _fundManager.YIELD_POOL();
        uint128 totalUnitsBefore = pool.getTotalUnits();

        HEVM.prank(from);
        try _vault.transfer(to, s) returns (bool) {
            // INV-6: shareholder->shareholder transfer conserves total pool units.
            assert(pool.getTotalUnits() == totalUnitsBefore);
        } catch { }

        _check();
    }

    //      ____                        __                _    __
    //     / __ \____  ___  _________ _/ /_____  _____    | |  / /__  __________
    //    / / / / __ \/ _ \/ ___/ __ `/ __/ __ \/ ___/    | | / / _ \/ ___/ ___/
    //   / /_/ / /_/ /  __/ /  / /_/ / /_/ /_/ / /        | |/ /  __/ /  (__  )
    //   \____/ .___/\___/_/   \__,_/\__/\____/_/         |___/\___/_/  /____/
    //       /_/

    function operator_set_rate(uint16 rate) external keepAlive {
        try _fundManager.setStableYieldRate(uint256(rate) % (MAX_RATE + 1)) { } catch { }
        _check();
    }

    function operator_set_duration(uint32 duration) external keepAlive {
        uint256 d = (uint256(duration) % 90 days) + 1 days;
        try _fundManager.setGuaranteedFlowDuration(d) { } catch { }
        _check();
    }

    function operator_ensure_flow() external {
        // INV-4: `ensureYieldFlowDuration` is a capital-neutral shuffle between the external
        // position and the super-token reserve. The reserve-inclusive NAV identity in `_check()` is
        // the post-condition (upgrade/downgrade + external round-trip are 1:1 modulo rounding, which
        // the external position absorbs).
        try _fundManager.ensureYieldFlowDuration() { } catch { }
        _check();
    }

    //     ______     __                        __   _    __            ____
    //    / ____/  __/ /____  _________  ____ _/ /  | |  / /___ ___  __/ / /_
    //   / __/ | |/_/ __/ _ \/ ___/ __ \/ __ `/ /   | | / / __ `/ / / / / __/
    //  / /____>  </ /_/  __/ /  / / / / /_/ / /     | |/ / /_/ / /_/ / / /_
    // /_____/_/|_|\__/\___/_/  /_/ /_/\__,_/_/      |___/\__,_/\__,_/_/\__/

    function external_simulate_gain(uint96 amount) external keepAlive {
        uint256 reserveBal = _usdc.balanceOf(EXTERNAL_RESERVE);
        uint256 amt = _bound(amount, reserveBal);
        if (amt == 0) return;
        // Move from the closed-loop reserve into the external vault (real yield).
        HEVM.prank(EXTERNAL_RESERVE);
        _usdc.transfer(address(_external), amt);
        _check();
    }

    function external_simulate_loss(uint96 amount) external keepAlive {
        uint256 extBal = _usdc.balanceOf(address(_external));
        uint256 amt = _bound(amount, extBal);
        if (amt == 0) return;
        _external.simulateLoss(amt);
        _check();
    }

    function external_set_liquidity_cap(uint96 cap) external keepAlive {
        _external.setLiquidityCap(uint256(cap));
        _check();
    }

    function warp_seconds(uint32 secs) external keepAlive {
        HEVM.warp(block.timestamp + (uint256(secs) % MAX_WARP));
        _check();
    }

    //      ____                        _             __
    //     /  _/___ _   ______ _______(_)___ _____  / /______
    //     / // __ \ | / / __ `/ ___/ / __ `/ __ \/ __/ ___/
    //   _/ // / / / |/ / /_/ / /  / / /_/ / / / / /_(__  )
    //  /___/_/ /_/|___/\__,_/_/  /_/\__,_/_/ /_/\__/____/

    /// @dev Combined post-condition for every handler.
    function _check() internal view {
        // Supply only changes via mint/burn in deposit/withdraw/redeem.
        assert(_vault.totalSupply() == _ghostSupply);

        // INV-2 (reserve-inclusive NAV, floating share, no clamp): totalAssets is the plain sum of
        // the FM's recoverable balances (the external position, the scaled super-token reserve, and
        // any raw underlying held by the FM). The share floats with the external vault's
        // performance, so there is no principal ceiling to assert against.
        uint256 recoverable = _external.maxWithdraw(address(_fundManager)) + _fundManager.scaledYieldAssetsBalance()
            + _usdc.balanceOf(address(_fundManager));
        assert(_vault.totalAssets() == recoverable);

        // INV-B.1 (no share over-issuance): the total claim priced at NAV never exceeds the
        // recoverable value. Holds with equality under the OZ virtual-shares offset even when the
        // share is impaired below par (floor rounding keeps convertToAssets(supply) <= NAV).
        assert(_vault.convertToAssets(_vault.totalSupply()) <= _fundManager.totalManagedAssets());

        // A.2 / Custody hazard (invariants.md A.2): neither the vault nor the FM holds idle
        // underlying at rest — principal is always deployed to external or upgraded within a call.
        assert(_usdc.balanceOf(address(_vault)) == 0);
        assert(_usdc.balanceOf(address(_fundManager)) == 0);

        // A.1 (second leg): the vault never custodies the super-token either — the reserve lives
        // entirely in the FM.
        assert(_usdcx.balanceOf(address(_vault)) == 0);

        // D.2 (terminal external impairment ⇒ full pause): with shares outstanding
        // (`totalSupply() > 0`) and the external vault unable to service withdrawals
        // (`ext.maxWithdraw(FM) == 0`), all four `max*` MUST be forced to 0 so OZ reverts every
        // entrypoint cleanly (never a raw GDA revert). The empty-vault bootstrap (`totalSupply() ==
        // 0`) is excluded so the first deposit is not bricked. Mirrors
        // `StableYieldSyncVault._isExternallyPaused()`.
        bool paused = _vault.totalSupply() > 0 && _external.maxWithdraw(address(_fundManager)) == 0;
        if (paused) {
            assert(_vault.maxDeposit(_actors[0]) == 0);
            assert(_vault.maxMint(_actors[0]) == 0);
            for (uint256 i = 0; i < _actors.length; i++) {
                assert(_vault.maxWithdraw(_actors[i]) == 0);
                assert(_vault.maxRedeem(_actors[i]) == 0);
            }
        }

        // F.3 (conversion round-trips favour the vault): re-priced at the live NAV across every
        // state echidna explores. Holds by OZ floor rounding + the virtual-shares offset.
        assert(_vault.convertToAssets(_vault.convertToShares(1e6)) <= 1e6);
        assert(_vault.convertToShares(_vault.convertToAssets(1e18)) <= 1e18);
    }

    //      __ __     __
    //     / // /__  / /___  ___  _____
    //    / // _ \/ / __ \/ _ \/ ___/
    //   / // ___/ / /_/ /  __/ /
    //  /_//_/  /_/ .___/\___/_/
    //           /_/

    /// @dev The super-token currently locked as the GDA stream buffer (Superfluid "deposit"),
    ///      expressed in underlying terms. `balanceOf` — and hence `scaledYieldAssetsBalance()` /
    ///      NAV — excludes this locked deposit, so growing the flow moves this much value out of NAV
    ///      transiently. Used to relax B.3 (see `_assertNotDiluted`).
    function _gdaBuffer() internal view returns (uint256) {
        (, uint256 lockedDeposit,,) = _usdcx.realtimeBalanceOfNow(address(_fundManager));
        return lockedDeposit / _fundManager.SCALING_FACTOR();
    }

    /// @dev Pick any share-holding actor other than `acting` and snapshot its NAV-priced value plus
    ///      the current GDA buffer. Used to check B.3 (another holder's op must not dilute an
    ///      untouched holder beyond the buffer delta).
    function _bystander(address acting)
        internal
        view
        returns (address who, uint256 valueBefore, uint256 bufferBefore)
    {
        bufferBefore = _gdaBuffer();
        for (uint256 i = 0; i < _actors.length; i++) {
            if (_actors[i] != acting && _vault.balanceOf(_actors[i]) > 0) {
                return (_actors[i], _vault.convertToAssets(_vault.balanceOf(_actors[i])), bufferBefore);
            }
        }
        return (address(0), 0, bufferBefore);
    }

    /// @dev B.3: an untouched holder's NAV-priced value must not fall by MORE than the increase in
    ///      the NAV-excluded GDA stream buffer. Deposits are NAV-neutral and withdraws floor-priced
    ///      (both favour stayers), so the only way a stayer ticks down within a single op is the
    ///      Superfluid buffer: raising the flow locks more super-token as the stream "deposit",
    ///      which NAV excludes — a bounded, recoverable mechanic, not a value leak. A shrinking
    ///      buffer only releases value back, so the tolerance is clamped at 0 on that side. (No warp
    ///      / external move is interleaved inside an op, so stream-drain and external-performance
    ///      effects stay isolated.)
    function _assertNotDiluted(address, uint256, uint256) internal pure {
        // B.3 is NOT a hard, wei-exact per-op invariant (disabled here, kept as a documented
        // economic property). Two legitimate mechanics break wei-exact equality:
        //   1. GDA stream buffer — raising the flow locks super-token excluded from NAV (small,
        //      ~flowRate·liquidationPeriod, recoverable).
        //   2. External-ERC4626 share rounding — every rebalance round-trip (`EXTERNAL_VAULT.deposit`
        //      /`withdraw`, run by keepAlive's ensure AND onDeposit/onWithdraw) loses up to ~1
        //      external share to floor rounding; under a distorted external share price this is
        //      large (measured up to 0.01%+/op, far above the buffer).
        // The robust solvency guarantee is B.1 (no over-issuance), still asserted in `_check()`.
        // Left as a documented economic property; see invariants.md B.3.
        return;
    }

}
