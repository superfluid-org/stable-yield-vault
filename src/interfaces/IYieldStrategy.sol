// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IYieldStrategy
/// @notice Interface for the external yield strategy contract.
///         The vault operator uses this to deploy and withdraw assets.
interface IYieldStrategy {
    /// @notice Deploys assets from the vault into the yield strategy.
    /// @param assets Amount of underlying assets to deploy
    function deploy(uint256 assets) external;

    /// @notice Withdraws assets from the yield strategy back to the vault.
    /// @param assets Amount of underlying assets to liquidate
    /// @return received Actual amount of assets returned (may differ due to slippage)
    function liquidate(uint256 assets) external returns (uint256 received);

    /// @notice Returns the current total value of all assets held by the strategy.
    /// @dev This is an informational view; the vault uses operator-reported NAV
    ///      for settlement, not this value directly.
    /// @return totalValue Current value denominated in the vault's underlying asset
    function totalValue() external view returns (uint256 totalValue);
}
