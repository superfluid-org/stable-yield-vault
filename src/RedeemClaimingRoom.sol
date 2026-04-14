// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IRedeemClaimingRoom } from "./interfaces/IRedeemClaimingRoom.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RedeemClaimingRoom is IRedeemClaimingRoom {

    address public immutable VAULT;
    IERC20 public immutable ASSET;

    constructor(address vault, address asset) {
        VAULT = vault;
        ASSET = IERC20(asset);
    }

    /// @inheritdoc IRedeemClaimingRoom
    function redeemFor(address redeemer, uint256 amount) external onlyVault {
        ASSET.transfer(redeemer, amount);
    }

    modifier onlyVault() {
        if (msg.sender != VAULT) {
            revert INVALID_CALLER();
        }
        _;
    }

}
