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
     * @notice Thrown when the deposit fee is not equal to the expected value.
     */
    error INVALID_DEPOSIT_FEE();

    /**
     * @notice Thrown when the transfer of the deposit fee to the treasury fails.
     */
    error FEE_TRANSFER_FAILED();

    error INVALID_CALL();

    //      ______     __                        __   ______                 __  _
    //     / ____/  __/ /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //    / __/ | |/_/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / /____>  </ /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /_____/_/|_|\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @dev Deposit `assets` underlying tokens and send the corresponding number of vault `shares` to `receiver`.
     * @param assets The amount of underlying tokens to deposit.
     * @param receiver The address to receive the vault shares.
     * @return shares The number of vault shares minted to `receiver`.
     */
    function depositWithFee(uint256 assets, address receiver) external payable returns (uint256 shares);

    /**
     * @dev Mint `shares` vault shares and pull the corresponding amount of underlying tokens from the caller.
     * @param shares The number of vault shares to mint.
     * @param receiver The address to receive the vault shares.
     * @return assets The amount of underlying tokens pulled from the caller.
     */
    function mintWithFee(uint256 shares, address receiver) external payable returns (uint256 assets);

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
     * @notice The participation fee, taken at deposit (in ETH).
     * @dev flat fee of 0.0001 ETH per deposit
     */
    function DEPOSIT_FEE() external view returns (uint256);

}
