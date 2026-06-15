// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

library NetworkConfig {

    struct DeploymentConfig {
        address treasury;
        address underlyingAsset;
        address yieldAsset;
        address externalVault;
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
        } else if (chainId == 8453) {
            config = getBaseMainnetConfig();
        } else {
            revert("Unsupported chainId");
        }
    }

    /**
     * @dev Get Polygon Mainnet configuration
     */
    function getPolygonMainnetConfig() internal pure returns (DeploymentConfig memory) {
        return DeploymentConfig({
            treasury: address(0),
            underlyingAsset: address(0),
            yieldAsset: address(0),
            externalVault: address(0),
            fundOperator: address(0),
            fundAdmin: address(0),
            initialEraStableYieldRate: 0,
            guaranteedFlowDuration: 0,
            shareName: "",
            shareSymbol: ""
        });
    }

    /**
     * @dev Get Base Mainnet configuration
     */
    function getBaseMainnetConfig() internal pure returns (DeploymentConfig memory) {
        return DeploymentConfig({
            treasury: 0xdc36265ca4505021250F02d3b711Dd9e9F23aD3D,
            underlyingAsset: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
            yieldAsset: 0xD04383398dD2426297da660F9CCA3d439AF9ce1b,
            externalVault: 0xbeef0e0834849aCC03f0089F01f4F1Eeb06873C9,
            fundOperator: 0xB9337958009Fc5b320844FE34F9eb58D8018837C,
            fundAdmin: 0xdc36265ca4505021250F02d3b711Dd9e9F23aD3D,
            initialEraStableYieldRate: 300,
            guaranteedFlowDuration: 2 days,
            shareName: "SYV v0 Share",
            shareSymbol: "SYVV0"
        });
    }

    function getLocalConfig() internal pure returns (DeploymentConfig memory) {
        return getPolygonMainnetConfig();
    }

}
