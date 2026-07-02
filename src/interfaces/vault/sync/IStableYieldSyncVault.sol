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

    //      ______                 __
    //     / ____/   _____  ____  / /______
    //    / __/ | | / / _ \/ __ \/ __/ ___/
    //   / /___ | |/ /  __/ / / / /_(__  )
    //  /_____/ |___/\___/_/ /_/\__/____/

    /**
     * @notice Emitted when the admin terminates the vault, permanently closing the deposit leg while
     *         leaving withdrawals open. One-way; never reversed.
     */
    event Terminated();

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
     * @notice Thrown at construction when the underlying asset is not 6-decimals (USDC).
     * @dev This vault is hard-coded for 6-decimals underlying (USDC) and 18-decimals yield asset (Super USDC).
     *      Revisit `_decimalOffset()` internal function for the vault's 6-to-18 decimal conversion.
     */
    error INVALID_CONFIGURATION();

    /**
     * @notice Thrown on a deposit whose `assets` do not exceed the flat {DEPOSIT_FEE}, so no positive
     *         net principal would remain after the fee.
     */
    error DEPOSIT_BELOW_FEE();

    /**
     * @notice Thrown on a deposit/mint while the vault is terminated (deposit leg permanently
     *         closed). Withdrawals remain open.
     */
    error VAULT_TERMINATED();

    /**
     * @notice Thrown when a non-admin calls an admin-gated function ({terminate}).
     * @dev Authority is the FundManager's DEFAULT_ADMIN_ROLE.
     */
    error NOT_ADMIN();

    //      ______     __                        __   ______                 __  _
    //     / ____/  __/ /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //    / __/ | |/_/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / /____>  </ /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /_____/_/|_|\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @notice Deposit `assets` (gross) in one call after an EIP-2612 permit — for batching through a
     *         Superfluid macro (the vault is EIP-2771-aware, so the real depositor is recovered from
     *         the appended calldata when called via the trusted forwarder).
     * @dev The permit authorizes the vault to pull `assets` (the gross amount); the flat
     *      {DEPOSIT_FEE} is then skimmed and the net is deposited. The permit is consumed best-effort
     *      (a front-run permit that already set the allowance is tolerated).
     * @param assets Gross underlying amount to pull (fee-inclusive); must be authorized by the permit.
     * @param receiver Address to receive the minted shares.
     * @param deadline EIP-2612 permit deadline.
     * @param v Permit signature `v`.
     * @param r Permit signature `r`.
     * @param s Permit signature `s`.
     * @return shares The number of vault shares minted to `receiver`.
     */
    function depositWithPermit(uint256 assets, address receiver, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        returns (uint256 shares);

    /**
     * @notice Permanently terminate the vault: the deposit leg is closed forever while withdrawals
     *         stay open so holders can exit. One-way; cannot be undone.
     * @dev Authorized by the FundManager's DEFAULT_ADMIN_ROLE (reverts {NOT_ADMIN} otherwise).
     */
    function terminate() external;

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

    /**
     * @notice Whether the vault has been terminated (deposit leg permanently closed). One-way.
     */
    function terminated() external view returns (bool);

}
