// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

library NetworkConfig {

    struct DeploymentConfig {
        address underlying;
        address superToken;
        address fundOperator;
        uint256 initialAnnualRate;
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
            underlying: address(0),
            superToken: address(0),
            fundOperator: address(0),
            initialAnnualRate: 0,
            guaranteedFlowDuration: 0,
            shareName: "",
            shareSymbol: ""
        });
    }

    function getLocalConfig() internal pure returns (DeploymentConfig memory) {
        return getPolygonMainnetConfig();
    }

}
