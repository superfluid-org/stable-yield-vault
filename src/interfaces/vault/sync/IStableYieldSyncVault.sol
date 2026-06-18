// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { ISyncFundManager } from "src/interfaces/vault/sync/ISyncFundManager.sol";

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IStableYieldSyncVault
 * @notice Synchronous ERC-4626 stable-yield vault — a thin share/accounting face. It holds no
 *         assets: the paired {SyncFundManager} (deployed and pinned here at construction) is
 *         the sole capital custodian (external-vault shares + yield asset reserve) and NAV
 *         authority. The share floats with the external vault's NAV. The vault pulls underlying from the caller,
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

    /**
     * @notice Thrown on a deposit whose `assets` do not exceed the flat {DEPOSIT_FEE}, so no positive
     *         net principal would remain after the fee.
     */
    error DEPOSIT_BELOW_FEE();

    //      ______     __                        __   ______                 __  _
    //     / ____/  __/ /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //    / __/ | |/_/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / /____>  </ /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /_____/_/|_|\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

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

    /**
     * @notice The treasury address collecting the fees.
     * @dev Pinned at construction.
     */
    function TREASURY() external view returns (address);

    /**
     * @notice The flat participation fee, taken in the underlying asset on every deposit/mint and
     *         sent to {TREASURY}.
     * @dev Flat 0.2 USDC (6-dec underlying). On `deposit` it is subtracted from the input (the net is
     *      deposited); on `mint` it is added on top of the assets required for the requested shares.
     */
    function DEPOSIT_FEE() external view returns (uint256);

}
