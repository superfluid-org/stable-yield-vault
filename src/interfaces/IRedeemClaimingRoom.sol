// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

interface IRedeemClaimingRoom {

    /// @notice Error thrown when a function is called by an unauthorized caller
    error INVALID_CALLER();

    /**
     * @notice Redeems assets for the specified redeemer.
     * @dev This operation can only be performed by the vault contract
     * @param redeemer The address of the redeemer.
     * @param amount The amount of assets to redeem.
     */
    function redeemFor(address redeemer, uint256 amount) external;

}
