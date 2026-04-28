// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC7540Deposit } from "./IERC7540Deposit.sol";

import { IERC7540Operator } from "./IERC7540Operator.sol";
import { IERC7540Redeem } from "./IERC7540Redeem.sol";
import { IERC7575 } from "./IERC7575.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { IFundManager } from "src/interfaces/IFundManager.sol";

/// @title IStableYieldAsyncVault
/// @notice Fully asynchronous ERC-7540 vault with epoch-based, two-phase settlement.
///
///         Lifecycle:
///           1. Users call requestDeposit / requestRedeem during an epoch
///           2. Operator calls closeEpoch() to snapshot pending flows and lock the epoch rate
///           3. Operator ensures FundManager liquidity (may liquidate working assets)
///           4. Operator calls settleEpoch() to net deposit/redeem flows — surplus deposits
///              are pushed to the FundManager, or a deficit is pulled from it to cover redeems.
///              Pending deposits and claimable redeems are both custodied by the vault itself.
///           5. Users call deposit/mint or redeem/withdraw to claim
///              (lazy settlement resolves pending → claimable on interaction)
///
///         Design decisions:
///           - Fully async (both deposits and redemptions)
///           - Forward pricing (all requests in an epoch get the same rate,
///             computed from effective NAV at closeEpoch, excluding pending flows)
///           - Two-phase settlement (closeEpoch + settleEpoch) to allow the operator
///             to ensure liquidity between phases with exact numbers
///           - No request cancellation — once closeEpoch is called, settleEpoch must follow
///           - requestId = 0 (single request per controller, aggregated)
///           - Claimable deposits stored internally in both asset and share units
///             (pre-computed at the epoch rate)
///           - Claimable redeems stored internally in both share and asset units
///             (pre-computed at the epoch rate)
///
///         Implementation notes:
///           - The 2-param deposit/mint from IERC4626 forward to the
///             3-param overloads with controller = msg.sender
///           - previewDeposit, previewMint, previewRedeem, previewWithdraw
///             MUST revert per ERC-7540 for async flows
interface IStableYieldAsyncVault is IERC4626, IERC7540Deposit, IERC7540Redeem, IERC7540Operator, IERC7575 {

    // ──────────────────────────────────────────────
    //  Datatypes
    // ──────────────────────────────────────────────

    struct Snapshot {
        uint256 epoch;
        uint256 depositingAssets;
        uint256 redeemingShares;
        uint256 rate;
    }

    /**
     * @notice State of a controller's vaults interactions
     * @dev Used to track the epoch of pending deposit and redeem requests
     * @param depositRequestEpoch Tracks which epoch the controller's pending deposit request belongs to (0 is none)
     * @param pendingDepositAssets Assets that the controller has requested to deposit (not yet settled)
     * @param claimableDepositAssets Assets corresponding to the controller's claimable shares (already settled)
     * @param claimableDepositShares Shares that the controller can claim from settled deposits (already settled)
     * @param redeemRequestEpoch Tracks which epoch the controller's pending redeem request belongs to (0 is none)
     * @param pendingRedeemShares Shares that the controller has requested to redeem (not yet settled)
     * @param claimableRedeemShares Shares corresponding to the controller's claimable assets (already settled)
     * @param claimableRedeemAssets Assets that the controller can claim from settled redeems (already settled)
     */
    struct ControllerState {
        uint256 depositRequestEpoch;
        uint256 pendingDepositAssets;
        uint256 claimableDepositAssets;
        uint256 claimableDepositShares;
        uint256 redeemRequestEpoch;
        uint256 pendingRedeemShares;
        uint256 claimableRedeemShares;
        uint256 claimableRedeemAssets;
    }

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    /// @notice Error thrown when passing an invalid function parameter
    error INVALID_PARAMETERS();

    /// @notice Error thrown when the caller of a function is invalid
    error INVALID_CALLER();

    /// @notice Error thrown when attempting to call functions not supported by ERC-7540
    error NOT_SUPPORTED_BY_ASYNC_VAULT();

    error PREVIOUS_EPOCH_NOT_SETTLED();
    error NO_EPOCH_TO_SETTLE();
    error EPOCH_SETTLEMENT_IN_PROGRESS();
    error NOTHING_TO_CLAIM();

    /// @notice Thrown when attempting to set a reference that has already been wired post-deploy.
    error ALREADY_SET();

    /// @notice Thrown when share transfers are attempted. Shares are non-transferable by design (D6).
    error SHARES_NON_TRANSFERABLE();

    /// @notice Thrown when an operation requires the FundManager to be set but it has not been.
    error FUND_MANAGER_NOT_SET();

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

    /// @notice Freeze deposit/redeem requests for the current epoch and lock the epoch rate
    function closeEpoch(uint256 totalFundAssets) external;

    /// @notice Finalize the settlement of a previously closed epoch.
    /// @dev Must be called after closeEpoch(). Uses the locked snapshot and rate to:
    ///        1. Convert pending redeems to asset terms at the epoch rate
    ///        2. Net deposit/redeem flows: push surplus deposits to the FundManager,
    ///           or pull a deficit from the FundManager to cover redeems
    ///        3. Earmark redeemable assets inside the vault for later claims
    ///        4. Store the epoch rate and mark the epoch as settled
    ///      Pending requests from the closed epoch become claimable (lazily) after this call.
    function settleEpoch() external;

    /// @notice Returns the current epoch number.
    function currentEpoch() external view returns (uint256);

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

    function getSnapshot() external view returns (Snapshot memory);

}
