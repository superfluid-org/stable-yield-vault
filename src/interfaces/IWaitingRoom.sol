// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

interface IWaitingRoom {

    /// @notice Error thrown when a function is called by an unauthorized caller
    error INVALID_CALLER();

    /**
     * @notice Moves assets to the specified recipient.
     * @dev This operation can only be performed by the vault contract
     * @param recipient The address of the recipient.
     * @param amount The amount of assets to move.
     */
    function move(address recipient, uint256 amount) external;

}
