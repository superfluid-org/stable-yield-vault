// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IERC7575
/// @notice Minimal ERC-7575 interface required by ERC-7540.
///         Exposes the share token address, enabling multitoken vault patterns.
///         ERC-165 interfaceId: 0x2f0a18c5
interface IERC7575 {
    /// @notice Returns the address of the share token.
    /// @dev For single-token vaults, this returns address(this).
    ///      For multitoken vaults, this may return a separate ERC-20 contract.
    /// @return shareTokenAddress The address of the ERC-20 share token
    function share() external view returns (address shareTokenAddress);
}
