// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IERC7540Redeem
/// @notice Interface for asynchronous redemption flows as defined in ERC-7540.
///         ERC-165 interfaceId: 0x620ee8e4
interface IERC7540Redeem {
    /// @notice Emitted when a redemption request is submitted.
    /// @param controller The address controlling this request
    /// @param owner The address whose shares were locked
    /// @param requestId The ID discriminating this request
    /// @param sender The caller of requestRedeem
    /// @param shares The amount of shares locked
    event RedeemRequest(
        address indexed controller,
        address indexed owner,
        uint256 indexed requestId,
        address sender,
        uint256 shares
    );

    /// @notice Locks shares from owner and submits an async redemption request.
    /// @param shares Amount of vault shares to redeem
    /// @param controller Address that will control this request and claim assets
    /// @param owner Address from which shares are transferred
    /// @return requestId The ID for this request (0 if not using request IDs)
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        returns (uint256 requestId);

    /// @notice Returns the amount of shares in Pending state for a controller.
    /// @param requestId The request ID (0 if not using request IDs)
    /// @param controller The address that controls the request
    /// @return shares Amount of shares still pending
    function pendingRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 shares);

    /// @notice Returns the amount of shares in Claimable state for a controller.
    /// @param requestId The request ID (0 if not using request IDs)
    /// @param controller The address that controls the request
    /// @return shares Amount of shares ready to be claimed via redeem/withdraw
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 shares);
}
