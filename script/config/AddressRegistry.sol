// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

library AddressRegistry {

    struct DeployedAddresses {
        address asyncVault;
        address fundManager;
    }

    function getNetworkConfig(uint256 chainId) internal pure returns (DeployedAddresses memory addresses) {
        if (chainId == 137) {
            addresses = getPolygonMainnetAddresses();
        } else {
            revert("Unsupported chainId");
        }
    }

    /**
     * @dev Get Polygon Mainnet configuration
     */
    function getPolygonMainnetAddresses() internal pure returns (DeployedAddresses memory addresses) {
        return DeployedAddresses({ asyncVault: address(0), fundManager: address(0) });
    }

}
