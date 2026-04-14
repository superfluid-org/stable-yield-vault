// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IWaitingRoom } from "./interfaces/IWaitingRoom.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract WaitingRoom is IWaitingRoom {

    address public immutable VAULT;
    IERC20 public immutable ASSET;

    constructor(address vault, address asset) {
        VAULT = vault;
        ASSET = IERC20(asset);
    }

    /// @inheritdoc IWaitingRoom
    function move(address recipient, uint256 amount) external onlyVault {
        ASSET.transfer(recipient, amount);
    }

    modifier onlyVault() {
        if (msg.sender != VAULT) {
            revert INVALID_CALLER();
        }
        _;
    }

}
