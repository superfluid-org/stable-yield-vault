// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC7540Deposit} from "./IERC7540Deposit.sol";
import {IERC7540Redeem} from "./IERC7540Redeem.sol";
import {IERC7540Operator} from "./IERC7540Operator.sol";
import {IERC7575} from "./IERC7575.sol";

/// @title IStableYieldAsyncVault
/// @notice Fully asynchronous ERC-7540 vault with 4-hour epoch-based settlement.
///
///         Lifecycle:
///           1. Users call requestDeposit / requestRedeem during an epoch
///           2. Epoch closes → operator nets flows, rebalances with YieldStrategy
///           3. Operator calls settleEpoch() with the updated NAV
///           4. Users call deposit/mint or redeem/withdraw to claim
///
///         Design decisions:
///           - Fully async (both deposits and redemptions)
///           - Operator-reported NAV (trusted)
///           - No request cancellation
///           - Forward pricing (all requests in an epoch get the same rate)
///           - requestId = 0 (single request per controller, aggregated)
interface IStableYieldAsyncVault is
    IERC7540Deposit,
    IERC7540Redeem,
    IERC7540Operator,
    IERC7575
{
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
    //  ERC-4626 claim functions (overloaded per ERC-7540)
    // ──────────────────────────────────────────────

    /// @notice Claims shares from a claimable deposit request.
    /// @dev Does NOT transfer assets — they were already transferred on requestDeposit.
    ///      msg.sender must be controller or an approved operator.
    /// @param assets Amount of assets to claim from the claimable balance
    /// @param receiver Address that receives the minted shares
    /// @param controller Address whose claimable request is being consumed
    /// @return shares Amount of shares minted to receiver
    function deposit(uint256 assets, address receiver, address controller)
        external
        returns (uint256 shares);

    /// @notice Claims a specific number of shares from a claimable deposit request.
    /// @dev Does NOT transfer assets — they were already transferred on requestDeposit.
    ///      msg.sender must be controller or an approved operator.
    /// @param shares Amount of shares to mint
    /// @param receiver Address that receives the minted shares
    /// @param controller Address whose claimable request is being consumed
    /// @return assets Amount of assets consumed from the claimable balance
    function mint(uint256 shares, address receiver, address controller)
        external
        returns (uint256 assets);

    /// @notice Claims assets from a claimable redemption request.
    /// @dev Does NOT transfer shares — they were already transferred on requestRedeem.
    ///      msg.sender must be controller or an approved operator.
    /// @param shares Amount of shares to redeem from the claimable balance
    /// @param receiver Address that receives the underlying assets
    /// @param controller Address whose claimable request is being consumed
    /// @return assets Amount of assets sent to receiver
    function redeem(uint256 shares, address receiver, address controller)
        external
        returns (uint256 assets);

    /// @notice Claims a specific amount of assets from a claimable redemption request.
    /// @dev Does NOT transfer shares — they were already transferred on requestRedeem.
    ///      msg.sender must be controller or an approved operator.
    /// @param assets Amount of assets to withdraw
    /// @param receiver Address that receives the underlying assets
    /// @param controller Address whose claimable request is being consumed
    /// @return shares Amount of shares consumed from the claimable balance
    function withdraw(uint256 assets, address receiver, address controller)
        external
        returns (uint256 shares);

    // ──────────────────────────────────────────────
    //  ERC-4626 view overrides (must revert per ERC-7540)
    // ──────────────────────────────────────────────

    /// @notice MUST revert for fully async vaults.
    function previewDeposit(uint256 assets) external view returns (uint256);

    /// @notice MUST revert for fully async vaults.
    function previewMint(uint256 shares) external view returns (uint256);

    /// @notice MUST revert for fully async vaults.
    function previewRedeem(uint256 shares) external view returns (uint256);

    /// @notice MUST revert for fully async vaults.
    function previewWithdraw(uint256 assets) external view returns (uint256);

    // ──────────────────────────────────────────────
    //  ERC-4626 views (non-reverting)
    // ──────────────────────────────────────────────

    /// @notice Returns the address of the underlying asset (e.g. USDC).
    function asset() external view returns (address);

    /// @notice Returns the current total assets managed by the vault (last reported NAV).
    function totalAssets() external view returns (uint256);

    /// @notice Converts an asset amount to shares at the current exchange rate.
    function convertToShares(uint256 assets) external view returns (uint256);

    /// @notice Converts a share amount to assets at the current exchange rate.
    function convertToAssets(uint256 shares) external view returns (uint256);

    // ──────────────────────────────────────────────
    //  Vault-specific: epoch settlement
    // ──────────────────────────────────────────────

    /// @notice Called by the vault operator to settle the current epoch.
    /// @dev The operator must:
    ///        1. Net deposit and redemption flows
    ///        2. Rebalance with the YieldStrategy (deploy or liquidate)
    ///        3. Call this function with the updated NAV
    ///      All pending requests in the current epoch become claimable.
    ///      The exchange rate is locked at newTotalAssets / totalSupply.
    /// @param newTotalAssets The operator-reported NAV after rebalancing
    function settleEpoch(uint256 newTotalAssets) external;

    /// @notice Returns the current epoch number.
    function currentEpoch() external view returns (uint256);

    /// @notice Returns the address of the YieldStrategy contract.
    function yieldStrategy() external view returns (address);

    /// @notice Returns the vault operator address.
    function operator() external view returns (address);

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
