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
            treasury: 0xac808840f02c47C05507f48165d2222FF28EF4e1, // SF DAO Multisig
            underlyingAsset: 0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB, // pUSD
            yieldAsset: 0x3aDf5b0Fab6bDF9De34DF3035826470d516F3066, // pUSDx
            externalVault: address(0), // No external vault for Polytheme contract
            fundOperator: 0xF9c355002585Cab21AC34aD60FFfB0776657e38F,
            fundAdmin: 0xdc36265ca4505021250F02d3b711Dd9e9F23aD3D,
            initialEraStableYieldRate: 500,
            guaranteedFlowDuration: 7 days,
            shareName: "PT Share v0.2",
            shareSymbol: "Polytheme Share v0.2"
        });
    }

    /**
     * @dev Get Base Mainnet configuration
     */
    function getBaseMainnetConfig() internal pure returns (DeploymentConfig memory) {
        return DeploymentConfig({
            treasury: 0xac808840f02c47C05507f48165d2222FF28EF4e1,
            underlyingAsset: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
            yieldAsset: 0xD04383398dD2426297da660F9CCA3d439AF9ce1b,
            externalVault: 0xbeef0e0834849aCC03f0089F01f4F1Eeb06873C9,
            fundOperator: 0xB9337958009Fc5b320844FE34F9eb58D8018837C,
            fundAdmin: 0x4396c45Ac5910Dab4d27f74fe678932a51f33a4d,
            initialEraStableYieldRate: 300,
            guaranteedFlowDuration: 2 days,
            shareName: "SuperVault Technical Demo Share",
            shareSymbol: "SVTD"
        });
    }

    function getLocalConfig() internal pure returns (DeploymentConfig memory) {
        return getPolygonMainnetConfig();
    }

}
