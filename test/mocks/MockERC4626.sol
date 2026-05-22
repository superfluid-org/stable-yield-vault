// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { ERC20 } from "@openzeppelin-v5/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";
import { ERC4626 } from "@openzeppelin-v5/contracts/token/ERC20/extensions/ERC4626.sol";
import { Math } from "@openzeppelin-v5/contracts/utils/math/Math.sol";

/**
 * @title MockERC4626
 * @notice Configurable external ERC-4626 used by the StableYieldSyncVault test-suite. Standard OZ
 *         ERC-4626 vault over the same underlying, plus test knobs:
 *           - `simulateGain(amount)`  : mints underlying into the vault (external yield).
 *           - `simulateLoss(amount)`  : burns underlying out of the vault (external loss).
 *           - `setLiquidityCap(cap)`  : caps `maxWithdraw`/`maxRedeem` to model external
 *                                       illiquidity (a withdrawal beyond the cap reverts).
 * @dev Yield/loss move `totalAssets()` (= underlying balance) directly, so the external share
 *      price drifts realistically; the StableYieldSyncVault values its position via
 *      `EXTERNAL_VAULT.maxWithdraw(vault)`.
 */
contract MockERC4626 is ERC4626 {

    using Math for uint256;

    /// @notice Address losses are shunted to (kept out of the vault's accounting).
    address public constant SINK = address(0xdead);

    /// @notice Max underlying serviceable by a single owner's withdrawal. `max` = uncapped.
    uint256 public liquidityCap = type(uint256).max;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC4626(asset_) { }

    //   _____ _                 __      __  _
    //  / ___/(_)___ ___  __  __/ /___ _/ /_(_)___  ____
    //  \__ \/ / __ `__ \/ / / / / __ `/ __/ / __ \/ __ \
    // ___/ / / / / / / / /_/ / / /_/ / /_/ / /_/ / / / /
    // /____/_/_/ /_/ /_/\__,_/_/\__,_/\__/_/\____/_/ /_/

    /// @notice Simulate external yield accrual by minting underlying into this vault.
    function simulateGain(uint256 amount) external {
        MintableLike(asset()).mint(address(this), amount);
    }

    /// @notice Simulate an external loss by moving underlying out of this vault.
    function simulateLoss(uint256 amount) external {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 loss = amount < bal ? amount : bal;
        // slither-disable-next-line unchecked-transfer
        IERC20(asset()).transfer(SINK, loss);
    }

    /// @notice Cap the underlying serviceable per `maxWithdraw`/`maxRedeem` (external illiquidity).
    function setLiquidityCap(uint256 cap) external {
        liquidityCap = cap;
    }

    //   _    ___                 _     __
    //  | |  / (_)__ _      __   | |  / /__  __________
    //  | | / / / _ \ | /| / /   | | / / _ \/ ___/ ___/
    //  | |/ / /  __/ |/ |/ /    | |/ /  __/ /  (__  )
    //  |___/_/\___/|__/|__/     |___/\___/_/  /____/

    /// @dev Liquidity-capped withdrawal limit (in underlying terms).
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 byShares = super.maxWithdraw(owner);
        return byShares < liquidityCap ? byShares : liquidityCap;
    }

    /// @dev Liquidity-capped redemption limit (in share terms).
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 byShares = super.maxRedeem(owner);
        uint256 capInShares = _convertToShares(liquidityCap, Math.Rounding.Floor);
        return byShares < capInShares ? byShares : capInShares;
    }

}

interface MintableLike {

    function mint(address to, uint256 amount) external;

}
