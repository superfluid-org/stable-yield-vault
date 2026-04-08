// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC7540Deposit } from "./IERC7540Deposit.sol";

import { IERC7540Operator } from "./IERC7540Operator.sol";
import { IERC7540Redeem } from "./IERC7540Redeem.sol";
import { IERC7575 } from "./IERC7575.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IStableYieldAsyncVault
/// @notice Fully asynchronous ERC-7540 vault with epoch-based settlement.
///
///         Lifecycle:
///           1. Users call requestDeposit / requestRedeem during an epoch
///           2. Operator calls settleEpoch() which atomically:
///              a. Computes the fair exchange rate (excluding pending flows)
///              b. Nets deposit/redeem flows and rebalances with YieldStrategy
///              c. Stores the epoch rate and advances the epoch
///           3. Users call deposit/mint or redeem/withdraw to claim
///              (lazy settlement resolves pending → claimable on interaction)
///
///         Design decisions:
///           - Fully async (both deposits and redemptions)
///           - Forward pricing (all requests in an epoch get the same rate,
///             computed from effective NAV at settlement, excluding pending flows)
///           - Atomic settlement with fund movement to/from YieldStrategy
///           - No request cancellation
///           - requestId = 0 (single request per controller, aggregated)
///           - Claimable deposits stored internally as shares (pre-computed at epoch rate)
///           - Claimable redeems stored internally as assets (pre-computed at epoch rate)
///
///         Implementation notes:
///           - The 2-param deposit/mint from IERC4626 forward to the
///             3-param overloads with controller = msg.sender
///           - previewDeposit, previewMint, previewRedeem, previewWithdraw
///             MUST revert per ERC-7540 for async flows
interface IStableYieldAsyncVault is IERC4626, IERC7540Deposit, IERC7540Redeem, IERC7540Operator, IERC7575 {

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    /// @notice Error thrown when passing an invalid function parameter
    error INVALID_PARAMETERS();

    /// @notice Error thrown when the caller of a function is invalid
    error INVALID_CALLER();

    /// @notice Error thrown when attempting to call fucntions not supported by ERC-7540
    error NOT_SUPPORTED_BY_ASYNC_VAULT();

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice Emitted when the operator settles an epoch.
    /// @param epoch The epoch number that was settled
    /// @param totalAssets The NAV reported by the operator
    /// @param assetsPerShare The computed exchange rate (scaled by 1e18)
    /// @param totalDepositAssets Total assets deposited in this epoch
    /// @param totalRedeemShares Total shares redeemed in this epoch
    event EpochSettled(
        uint256 indexed epoch,
        uint256 totalAssets,
        uint256 assetsPerShare,
        uint256 totalDepositAssets,
        uint256 totalRedeemShares
    );

    // ──────────────────────────────────────────────
    //  ERC-7540: 3-param claim overloads
    //  These extend the 2-param ERC-4626 versions
    //  to support controller-based claiming.
    // ──────────────────────────────────────────────

    /// @notice Claims shares from a claimable deposit request.
    /// @dev Does NOT transfer assets — they were already transferred on requestDeposit.
    ///      msg.sender must be controller or an approved operator.
    /// @param assets Amount of assets to claim from the claimable balance
    /// @param receiver Address that receives the minted shares
    /// @param controller Address whose claimable request is being consumed
    /// @return shares Amount of shares minted to receiver
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares);

    /// @notice Claims a specific number of shares from a claimable deposit request.
    /// @dev Does NOT transfer assets — they were already transferred on requestDeposit.
    ///      msg.sender must be controller or an approved operator.
    /// @param shares Amount of shares to mint
    /// @param receiver Address that receives the minted shares
    /// @param controller Address whose claimable request is being consumed
    /// @return assets Amount of assets consumed from the claimable balance
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets);

    /// @notice Claims assets from a claimable redemption request.
    /// @dev Does NOT transfer shares — they were already transferred on requestRedeem.
    ///      msg.sender must be controller or an approved operator.
    /// @param shares Amount of shares to redeem from the claimable balance
    /// @param receiver Address that receives the underlying assets
    /// @param controller Address whose claimable request is being consumed
    /// @return assets Amount of assets sent to receiver
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets);

    /// @notice Claims a specific amount of assets from a claimable redemption request.
    /// @dev Does NOT transfer shares — they were already transferred on requestRedeem.
    ///      msg.sender must be controller or an approved operator.
    /// @param assets Amount of assets to withdraw
    /// @param receiver Address that receives the underlying assets
    /// @param controller Address whose claimable request is being consumed
    /// @return shares Amount of shares consumed from the claimable balance
    function withdraw(uint256 assets, address receiver, address controller) external returns (uint256 shares);

    // ──────────────────────────────────────────────
    //  Vault-specific: epoch settlement
    // ──────────────────────────────────────────────

    /// @notice Called by the vault operator to settle the current epoch.
    /// @dev Atomically:
    ///        1. Computes fair rate from effective assets/supply (excludes pending flows)
    ///        2. Converts pending redeems to asset terms at the epoch rate
    ///        3. Nets deposit/redeem flows and moves funds to/from YieldStrategy
    ///        4. Stores the epoch rate, resets pending totals, advances epoch
    ///      All pending requests in the current epoch become claimable (lazily).
    function settleEpoch() external;

    /// @notice Returns the current epoch number.
    function currentEpoch() external view returns (uint256);

    /// @notice Returns the address of the YieldStrategy contract.
    function yieldStrategy() external view returns (address);

    /// @notice Returns the vault operator address (the settlement authority).
    /// @dev Not to be confused with ERC-7540 operators, which are user-approved
    ///      delegates for managing requests.
    function vaultOperator() external view returns (address);

    // ──────────────────────────────────────────────
    //  ERC-165
    // ──────────────────────────────────────────────

    /// @notice ERC-165 interface detection.
    /// @dev Must return true for:
    ///        - 0xe3bc4e65 (ERC-7540 operator methods)
    ///        - 0x2f0a18c5 (ERC-7575)
    ///        - 0xce3bbe50 (async deposit)
    ///        - 0x620ee8e4 (async redeem)
    function supportsInterface(bytes4 interfaceId) external view returns (bool);

}
