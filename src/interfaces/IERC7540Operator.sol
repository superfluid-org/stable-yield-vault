// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IERC7540Operator
/// @notice Operator approval methods required by all ERC-7540 vaults.
///         Operators can manage requests on behalf of a controller.
///         ERC-165 interfaceId: 0xe3bc4e65
interface IERC7540Operator {
    /// @notice Emitted when an operator's approval status changes.
    /// @param controller The address granting/revoking approval
    /// @param operator The address being approved/revoked
    /// @param approved Whether the operator is approved
    event OperatorSet(
        address indexed controller,
        address indexed operator,
        bool approved
    );

    /// @notice Grants or revokes operator permissions for msg.sender.
    /// @param operator The address to approve or revoke
    /// @param approved True to approve, false to revoke
    /// @return success Always returns true
    function setOperator(address operator, bool approved)
        external
        returns (bool success);

    /// @notice Returns whether an operator is approved for a controller.
    /// @param controller The address that granted approval
    /// @param operator The address to check
    /// @return status True if the operator is approved
    function isOperator(address controller, address operator)
        external
        view
        returns (bool status);
}
