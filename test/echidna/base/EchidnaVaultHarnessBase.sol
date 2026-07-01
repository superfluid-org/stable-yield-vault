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

interface IHevm {

    function etch(address who, bytes calldata code) external;
    function prank(address) external;
    function warp(uint256) external;
    function deal(address who, uint256 newBalance) external;

}

/// @title Shared Echidna harness scaffolding for both StableYield vault families.
/// @dev   Holds the Superfluid-framework bootstrap, the 6-dec USDC/USDCx wrapper deploy, the actor
///        funding, and the library-planting / bounding helpers that are identical across the async
///        and sync harnesses. The concrete harness (one per family) inherits this, deploys its own
///        vault + FundManager (+ external vault, for sync) in its constructor, and supplies the
///        family-specific action handlers + `_check()` invariant set. Echidna fuzzes the concrete
///        contract; this base is abstract and exposes no external entrypoints.
abstract contract EchidnaVaultHarnessBase {

    IHevm internal constant HEVM = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint256 internal constant ACTOR_INITIAL_USDC = 1_000_000 * 1e6; // 1M USDC each
    uint256 internal constant OPERATOR_INITIAL_USDC = 100_000_000 * 1e6; // operator injection treasury
    uint256 internal constant INITIAL_RATE = 1000; // 10% APR (basis points)
    uint256 internal constant INITIAL_FLOW_DURATION = 7 days;
    uint256 internal constant MAX_RATE = 5000; // cap fuzzed rate at 50%

    SuperfluidFrameworkDeployer internal _deployer;
    TestToken internal _usdc;
    SuperToken internal _usdcx;

    address[3] internal _actors;
    address internal _treasury;

    //      ____              __       __
    //     / __ )____  ____  / /______/ /__________ _____
    //    / __  / __ \/ __ \/ __/ ___/ __/ ___/ __ `/ __ \
    //   / /_/ / /_/ / /_/ / /_(__  ) /_/ /  / /_/ / /_/ /
    //  /_____/\____/\____/\__/____/\__/_/   \__,_/ .___/
    //                                          /_/

    /// @dev Plants the Superfluid external libraries, deploys the test framework + a 6-dec USDC/USDCx
    ///      wrapper super-token, derives the actor + treasury addresses from the given salts and mints
    ///      each actor its starting USDC. Call this FIRST in the concrete constructor, before deploying
    ///      the vault. Actor-to-vault approvals (`_approveActorsTo`) and the operator-treasury seed
    ///      (`_seedOperatorTreasury`) come after, once the vault / FundManager addresses exist.
    function _bootstrapSuperfluid(
        string memory aliceSalt,
        string memory bobSalt,
        string memory carolSalt,
        string memory treasurySalt
    ) internal {
        // String salts (not bytes32) so the derived addresses match the originals exactly:
        // `keccak256(bytes("ECHIDNA_ALICE"))` hashes the 13 UTF-8 bytes, as the inline literals did.
        _actors[0] = address(uint160(uint256(keccak256(bytes(aliceSalt)))));
        _actors[1] = address(uint160(uint256(keccak256(bytes(bobSalt)))));
        _actors[2] = address(uint160(uint256(keccak256(bytes(carolSalt)))));
        _treasury = address(uint160(uint256(keccak256(bytes(treasurySalt)))));

        HEVM.etch(ERC1820RegistryCompiled.ADDRESS, ERC1820RegistryCompiled.BYTECODE);
        _plantSuperfluidLibraries();

        _deployer = new SuperfluidFrameworkDeployer();
        _deployer.deployTestFramework();

        (TestToken usdc_, SuperToken usdcx_) =
            _deployer.deployWrapperSuperToken("USDC", "USDC", 6, type(uint256).max, address(0));
        _usdc = usdc_;
        _usdcx = usdcx_;

        for (uint256 i = 0; i < _actors.length; i++) {
            _usdc.mint(_actors[i], ACTOR_INITIAL_USDC);
        }
    }

    /// @dev Approve `spender` (the vault) to pull each actor's USDC. Run after the vault is deployed.
    function _approveActorsTo(address spender) internal {
        for (uint256 i = 0; i < _actors.length; i++) {
            HEVM.prank(_actors[i]);
            _usdc.approve(spender, type(uint256).max);
        }
    }

    /// @dev Mint the operator-injection treasury to the harness (`address(this)` plays the operator)
    ///      and approve the FundManager to pull from it. Run after the FundManager is deployed.
    function _seedOperatorTreasury(address fundManager) internal {
        _usdc.mint(address(this), OPERATOR_INITIAL_USDC);
        _usdc.approve(fundManager, type(uint256).max);
    }

    /// @dev One-time pool-config invariant (async D.7 / sync equivalent): the GDA pool is admined by
    ///      the FundManager, its units are non-transferable, and distribution-from-any-address is off.
    ///      These are fixed in the FundManager constructor and immutable, so a single check suffices.
    function _assertPoolConfig(ISuperfluidPool pool, address fundManager) internal view {
        require(pool.admin() == fundManager, "pool admin");
        require(!pool.transferabilityForUnitsOwner(), "pool transferability");
        require(!pool.distributionFromAnyAddress(), "pool distribution");
    }

    //      __  __     __
    //     / / / /__  / /___  ___  _____
    //    / /_/ / _ \/ / __ \/ _ \/ ___/
    //   / __  /  __/ / /_/ /  __/ /
    //  /_/ /_/\___/_/ .___/\___/_/
    //              /_/

    /// @dev Foundry's runtime auto-deploys external libraries; Echidna does not. Each library address
    ///      below is pinned in foundry.toml's [profile.echidna] and in the echidna config's
    ///      `--compile-libraries`; here we deploy each one and etch its runtime bytecode at the pinned
    ///      address so the framework's DELEGATECALLs land on real code.
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

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

}
