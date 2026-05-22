// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { ISyncFundManager } from "src/interfaces/vault/sync/ISyncFundManager.sol";

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IStableYieldSyncVault
 * @notice Synchronous ERC-4626 stable-yield vault — a thin share/accounting face. It holds no
 *         assets: the paired {SyncFundManager} (deployed and pinned here at construction) is
 *         the sole capital custodian (external-vault shares, `trackedPrincipal`, yield assets
 *         reserve) and NAV authority. The vault pulls underlying from the caller,
 *         forwards it to the FundManager, mints/burns shares. The stable yield is streamed via
 *         Superfluid Distribution pool, pre-funded from each deposit.
 */
interface IStableYieldSyncVault is IERC4626 {

    //      ______
    //     / ____/_____________  __________
    //    / __/ / ___/ ___/ __ \/ ___/ ___/
    //   / /___/ /  / /  / /_/ / /  (__  )
    //  /_____/_/  /_/   \____/_/  /____/

    /**
     * @notice Thrown at construction when the external vault's `asset()` is not the vault's
     *         underlying asset.
     */
    error EXTERNAL_ASSET_MISMATCH();

    //   _    ___                 ______                 __  _
    //  | |  / (_)__ _      __   / ____/_  ______  _____/ /_(_)___  ____  _____
    //  | | / / / _ \ | /| / /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //  | |/ / /  __/ |/ |/ /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  |___/_/\___/|__/|__/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @notice The paired FundManager that custodies all capital and routes the stable yield
     *         stream.
     * @dev Deployed and pinned at construction (`msg.sender == vault`).
     */
    function FUND_MANAGER() external view returns (ISyncFundManager);

}
