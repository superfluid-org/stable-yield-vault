// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

library NetworkConfig {

    struct DeploymentConfig {
        address underlyingAsset;
        address yieldAsset;
        address fundOperator;
        address fundAdmin;
        uint256 initialEraStableYieldRate;
        uint256 guaranteedFlowDuration;
        string shareName;
        string shareSymbol;
    }

    function getNetworkConfig(uint256 chainId) internal pure returns (DeploymentConfig memory config) {
        if (chainId == 137) {
            config = getPolygonMainnetConfig();
        } else {
            revert("Unsupported chainId");
        }
    }

    /**
     * @dev Get Polygon Mainnet configuration
     */
    function getPolygonMainnetConfig() internal pure returns (DeploymentConfig memory) {
        return DeploymentConfig({
            underlyingAsset: address(0),
            yieldAsset: address(0),
            fundOperator: address(0),
            fundAdmin: address(0),
            initialEraStableYieldRate: 0,
            guaranteedFlowDuration: 0,
            shareName: "",
            shareSymbol: ""
        });
    }

    function getLocalConfig() internal pure returns (DeploymentConfig memory) {
        return getPolygonMainnetConfig();
    }

}
