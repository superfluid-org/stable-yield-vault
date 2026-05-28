// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { MockERC4626 } from "../mocks/MockERC4626.sol";

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

import { IERC20 } from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";

import { StableYieldSyncVault } from "src/vault/sync/StableYieldSyncVault.sol";
import { SyncFundManager } from "src/vault/sync/SyncFundManager.sol";

interface IHevm {

    function etch(address who, bytes calldata code) external;
    function prank(address) external;
    function warp(uint256) external;

}

/// @title Echidna fuzzing harness for the synchronous StableYieldSyncVault + SyncFundManager pair.
/// @dev   Deploys the full Superfluid framework + a configurable external ERC-4626 in the
///        constructor and exposes clamped handlers for every mutating entrypoint. Invariants
///        from `docs/sync-vault/design.md §Invariants` are checked after every handler.
contract EchidnaStableYieldSyncVault {

    IHevm private constant HEVM = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint256 private constant ACTOR_INITIAL_USDC = 1_000_000 * 1e6; // 1M USDC each
    uint256 private constant OPERATOR_INITIAL_USDC = 100_000_000 * 1e6; // operator injection treasury
    uint256 private constant EXTERNAL_RESERVE_INITIAL = 100_000_000 * 1e6; // funds simulated external yield
    uint256 private constant INITIAL_RATE = 1000; // 10% APR (bps)
    uint256 private constant INITIAL_FLOW_DURATION = 7 days;
    uint256 private constant MAX_RATE = 5000; // cap fuzzed rate at 50%
    uint256 private constant MAX_WARP = 30 days;

    /// @dev Closed-loop pool funding simulated external gains / absorbing simulated losses.
    address private constant EXTERNAL_RESERVE = address(uint160(uint256(keccak256("ECHIDNA_SYNC_EXT_RESERVE"))));

    SuperfluidFrameworkDeployer private _deployer;
    TestToken private _usdc;
    SuperToken private _usdcx;

    MockERC4626 private _external;
    SyncFundManager private _fundManager;
    StableYieldSyncVault private _vault;

    address[3] private _actors;
    address private _treasury;

    /// @dev Mirror of `totalSupply`, updated only by mint/burn handlers.
    uint256 private _ghostSupply;

    constructor() {
        _actors[0] = address(uint160(uint256(keccak256("ECHIDNA_SYNC_ALICE"))));
        _actors[1] = address(uint160(uint256(keccak256("ECHIDNA_SYNC_BOB"))));
        _actors[2] = address(uint160(uint256(keccak256("ECHIDNA_SYNC_CAROL"))));
        _treasury = address(uint160(uint256(keccak256("ECHIDNA_SYNC_TREASURY"))));

        HEVM.etch(ERC1820RegistryCompiled.at, ERC1820RegistryCompiled.bin);
        _plantSuperfluidLibraries();

        _deployer = new SuperfluidFrameworkDeployer();
        _deployer.deployTestFramework();

        (TestToken usdc_, SuperToken usdcx_) =
            _deployer.deployWrapperSuperToken("USDC", "USDC", 6, type(uint256).max, address(0));
        _usdc = usdc_;
        _usdcx = usdcx_;

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

        // Operator injection treasury.
        _usdc.mint(address(this), OPERATOR_INITIAL_USDC);
        _usdc.approve(address(_fundManager), type(uint256).max);

        // Closed-loop external-yield reserve.
        _usdc.mint(EXTERNAL_RESERVE, EXTERNAL_RESERVE_INITIAL);
        HEVM.prank(EXTERNAL_RESERVE);
        _usdc.approve(address(this), type(uint256).max);

        for (uint256 i = 0; i < _actors.length; i++) {
            address actor = _actors[i];
            _usdc.mint(actor, ACTOR_INITIAL_USDC);
            HEVM.prank(actor);
            _usdc.approve(address(_vault), type(uint256).max);
        }

        // D.7-equivalent: pool config is immutable, one-time check.
        ISuperfluidPool pool = _fundManager.YIELD_POOL();
        require(pool.admin() == address(_fundManager), "pool admin");
        require(!pool.transferabilityForUnitsOwner(), "pool transferability");
        require(!pool.distributionFromAnyAddress(), "pool distribution");
    }

    //      ____                        _ __     ___        __  _
    //     / __ \___  ____  ____  _____(_) /_   /   | _____/ /_(_)___  ____  _____
    //    / / / / _ \/ __ \/ __ \/ ___/ / __/  / /| |/ ___/ __/ / __ \/ __ \/ ___/
    //   / /_/ /  __/ /_/ / /_/ (__  ) / /_   / ___ / /__/ /_/ / /_/ / / / (__  )
    //  /_____/\___/ .___/\____/____/_/\__/  /_/  |_\___/\__/_/\____/_/ /_/____/
    //            /_/

    function deposit(uint8 actorIdx, uint96 amount) external {
        address actor = _actor(actorIdx);
        uint256 amt = _bound(amount, _usdc.balanceOf(actor));
        if (amt == 0) return;

        ISuperfluidPool pool = _fundManager.YIELD_POOL();
        uint128 unitsBefore = pool.getUnits(actor);

        HEVM.prank(actor);
        try _vault.deposit(amt, actor) returns (uint256 shares) {
            _ghostSupply += shares;
            // INV-6: a non-dust deposit grants the receiver yield units at deposit time.
            if (amt >= _fundManager.RAW_PER_UNIT()) {
                assert(pool.getUnits(actor) > unitsBefore);
            }
        } catch { }

        _check();
    }

    function mint(uint8 actorIdx, uint96 shares) external {
        address actor = _actor(actorIdx);
        uint256 maxShares = _vault.maxMint(actor);
        uint256 actorCap = _vault.convertToShares(_usdc.balanceOf(actor));
        uint256 cap = maxShares < actorCap ? maxShares : actorCap;
        uint256 s = _bound(shares, cap);
        if (s == 0) return;

        HEVM.prank(actor);
        try _vault.mint(s, actor) returns (uint256) {
            _ghostSupply += s;
        } catch { }

        _check();
    }

    function withdraw(uint8 actorIdx, uint96 amount) external {
        address actor = _actor(actorIdx);
        uint256 maxA = _vault.maxWithdraw(actor);
        uint256 amt = _bound(amount, maxA);
        if (amt == 0) return;

        uint256 balBefore = _usdc.balanceOf(actor);

        HEVM.prank(actor);
        try _vault.withdraw(amt, actor, actor) returns (uint256 burned) {
            _ghostSupply -= burned;
            // INV-B.6: a successful withdraw pays the receiver EXACTLY the requested underlying.
            assert(_usdc.balanceOf(actor) - balBefore == amt);
        } catch { }

        _check();
    }

    function redeem(uint8 actorIdx, uint96 shares) external {
        address actor = _actor(actorIdx);
        uint256 maxS = _vault.maxRedeem(actor);
        uint256 s = _bound(shares, maxS);
        if (s == 0) return;

        uint256 balBefore = _usdc.balanceOf(actor);

        HEVM.prank(actor);
        try _vault.redeem(s, actor, actor) returns (uint256 assets) {
            _ghostSupply -= s;
            // INV-B.6: a successful redeem pays the receiver EXACTLY the assets it reports.
            assert(_usdc.balanceOf(actor) - balBefore == assets);
        } catch { }

        _check();
    }

    function transfer_shares(uint8 fromIdx, uint8 toIdx, uint96 shares) external {
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

    function operator_set_rate(uint16 rate) external {
        try _fundManager.setStableYieldRate(uint256(rate) % (MAX_RATE + 1)) { } catch { }
        _check();
    }

    function operator_set_duration(uint32 duration) external {
        uint256 d = (uint256(duration) % 90 days) + 1 days;
        try _fundManager.setGuaranteedFlowDuration(d) { } catch { }
        _check();
    }

    function operator_ensure_flow() external {
        // INV-4 (revised 2026-05-26): with the clamp gone, `ensureYieldFlowDuration` is a
        // capital-neutral shuffle between the external position and the super-token reserve. There
        // is no `trackedPrincipal` to pin; the reserve-inclusive NAV identity in `_check()` is the
        // post-condition (upgrade/downgrade + external round-trip are 1:1 modulo rounding, which
        // the external position absorbs).
        try _fundManager.ensureYieldFlowDuration() { } catch { }
        _check();
    }

    //     ______     __                        __   _    __            ____
    //    / ____/  __/ /____  _________  ____ _/ /  | |  / /___ ___  __/ / /_
    //   / __/ | |/_/ __/ _ \/ ___/ __ \/ __ `/ /   | | / / __ `/ / / / / __/
    //  / /____>  </ /_/  __/ /  / / / / /_/ / /     | |/ / /_/ / /_/ / / /_
    // /_____/_/|_|\__/\___/_/  /_/ /_/\__,_/_/      |___/\__,_/\__,_/_/\__/

    function external_simulate_gain(uint96 amount) external {
        uint256 reserveBal = _usdc.balanceOf(EXTERNAL_RESERVE);
        uint256 amt = _bound(amount, reserveBal);
        if (amt == 0) return;
        // Move from the closed-loop reserve into the external vault (real yield).
        HEVM.prank(EXTERNAL_RESERVE);
        _usdc.transfer(address(_external), amt);
        _check();
    }

    function external_simulate_loss(uint96 amount) external {
        uint256 extBal = _usdc.balanceOf(address(_external));
        uint256 amt = _bound(amount, extBal);
        if (amt == 0) return;
        _external.simulateLoss(amt);
        _check();
    }

    function external_set_liquidity_cap(uint96 cap) external {
        _external.setLiquidityCap(uint256(cap));
        _check();
    }

    function warp_seconds(uint32 secs) external {
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

        // INV-2 (reserve-inclusive NAV, floating share, NO clamp — revised 2026-05-26):
        // totalAssets is the plain sum of the FM's recoverable balances (the external position,
        // the scaled super-token reserve, and any raw underlying held by the FM). The
        // `min(trackedPrincipal, …)` clamp / ≈1:1-peg model was dropped 2026-05-26 (see
        // docs/sync-vault/design.md §Revision 2026-05-26); the share now floats with the external
        // vault's performance, so there is no longer a principal ceiling to assert against.
        uint256 recoverable = _external.maxWithdraw(address(_fundManager)) + _fundManager.scaledYieldAssetsBalance()
            + _usdc.balanceOf(address(_fundManager));
        assert(_vault.totalAssets() == recoverable);

        // INV-B.2 (no share over-issuance): the total claim priced at NAV never exceeds the
        // recoverable value. Holds with equality under the OZ virtual-shares offset even when the
        // share is impaired below par (floor rounding keeps convertToAssets(supply) <= NAV).
        assert(_vault.convertToAssets(_vault.totalSupply()) <= _fundManager.totalManagedAssets());

        // Custody hazard invariant (design.md Inv. 7): neither the vault nor the FM holds idle
        // underlying at rest — principal is always deployed to external or upgraded within a call.
        assert(_usdc.balanceOf(address(_vault)) == 0);
        assert(_usdc.balanceOf(address(_fundManager)) == 0);
    }

    //      __ __     __
    //     / // /__  / /___  ___  _____
    //    / // _ \/ / __ \/ _ \/ ___/
    //   / // ___/ / /_/ /  __/ /
    //  /_//_/  /_/ .___/\___/_/
    //           /_/

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
