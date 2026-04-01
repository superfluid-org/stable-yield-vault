// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IERC7540Deposit
/// @notice Interface for asynchronous deposit flows as defined in ERC-7540.
///         ERC-165 interfaceId: 0xce3bbe50
interface IERC7540Deposit {

    /// @notice Emitted when a deposit request is submitted.
    /// @param controller The address controlling this request
    /// @param owner The address whose assets were transferred
    /// @param requestId The ID discriminating this request
    /// @param sender The caller of requestDeposit
    /// @param assets The amount of assets locked
    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );

    /// @notice Transfers assets from owner and submits an async deposit request.
    /// @param assets Amount of underlying assets to deposit
    /// @param controller Address that will control this request and claim shares
    /// @param owner Address from which assets are transferred
    /// @return requestId The ID for this request (0 if not using request IDs)
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);

    /// @notice Returns the amount of assets in Pending state for a controller.
    /// @param requestId The request ID (0 if not using request IDs)
    /// @param controller The address that controls the request
    /// @return assets Amount of assets still pending
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256 assets);

    /// @notice Returns the amount of assets in Claimable state for a controller.
    /// @param requestId The request ID (0 if not using request IDs)
    /// @param controller The address that controls the request
    /// @return assets Amount of assets ready to be claimed via deposit/mint
    function claimableDepositRequest(uint256 requestId, address controller) external view returns (uint256 assets);

}
