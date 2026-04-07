// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    IERC4626,
    IERC7540Deposit,
    IERC7540Operator,
    IERC7540Redeem,
    IERC7575,
    IStableYieldAsyncVault
} from "./interfaces/IStableYieldAsyncVault.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract StableYieldAsynchronousVault is ERC20, IStableYieldAsyncVault {

    using Math for uint256;

    //      ____                          __        __    __        _____ __        __
    //     /  _/___ ___  ____ ___  __  __/ /_____ _/ /_  / /__     / ___// /_____ _/ /____  _____
    //     / // __ `__ \/ __ `__ \/ / / / __/ __ `/ __ \/ / _ \    \__ \/ __/ __ `/ __/ _ \/ ___/
    //   _/ // / / / / / / / / / / /_/ / /_/ /_/ / /_/ / /  __/   ___/ / /_/ /_/ / /_/  __(__  )
    //  /___/_/ /_/ /_/_/ /_/ /_/\__,_/\__/\__,_/_.___/_/\___/   /____/\__/\__,_/\__/\___/____/

    //     _____ __        __
    //    / ___// /_____ _/ /____  _____
    //    \__ \/ __/ __ `/ __/ _ \/ ___/
    //   ___/ / /_/ /_/ / /_/  __(__  )
    //  /____/\__/\__,_/\__/\___/____/

    mapping(address controller => mapping(address operator => bool)) private _isOperator;

    mapping(address controller => uint256 assets) private _pendingDepositRequest;
    mapping(address controller => uint256 assets) private _claimableDepositRequest;

    mapping(address controller => uint256 shares) private _pendingRedeemRequest;
    mapping(address controller => uint256 shares) private _claimableRedeemRequest;

    IERC20 public underlyingAsset;

    //     ______                 __                  __
    //    / ____/___  ____  _____/ /________  _______/ /_____  _____
    //   / /   / __ \/ __ \/ ___/ __/ ___/ / / / ___/ __/ __ \/ ___/
    //  / /___/ /_/ / / / (__  ) /_/ /  / /_/ / /__/ /_/ /_/ / /
    //  \____/\____/_/ /_/____/\__/_/   \__,_/\___/\__/\____/_/

    /**
     * @notice Initializes the vault with the underlying asset and share token metadata.
     * @param _underlyingAsset The address of the underlying ERC-20 asset.
     * @param name The name of the share token.
     * @param symbol The symbol of the share token.
     */
    constructor(IERC20 _underlyingAsset, string memory name, string memory symbol) ERC20(name, symbol) {
        underlyingAsset = _underlyingAsset;
    }

    //      ______     __                        __   ______                 __  _
    //     / ____/  __/ /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //    / __/ | |/_/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / /____>  </ /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /_____/_/|_|\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @inheritdoc IERC7540Deposit
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId) {
        if (assets == 0) revert INVALID_PARAMETERS();
        if (owner != msg.sender && !_isOperator[owner][msg.sender]) revert INVALID_CALLER();

        // no requestId associated with this request
        requestId = 0;

        // Transfer the underlying asset from the owner to this contract
        underlyingAsset.transferFrom(owner, address(this), assets);

        // Accrue the assets deposited by this controller
        _pendingDepositRequest[controller] += assets;

        emit DepositRequest(controller, owner, requestId, msg.sender, assets);
    }

    /// @inheritdoc IStableYieldAsyncVault
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares) {
        if (controller != msg.sender && !_isOperator[controller][msg.sender]) revert INVALID_CALLER();
        shares = _deposit(assets, receiver, controller);
    }

    /// @inheritdoc IERC4626
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = _deposit(assets, receiver, msg.sender);
    }

    /// @inheritdoc IStableYieldAsyncVault
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets) {
        if (controller != msg.sender && !_isOperator[controller][msg.sender]) revert INVALID_CALLER();
        assets = _mintShares(shares, receiver, controller);
    }

    /// @inheritdoc IERC4626
    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = _mintShares(shares, receiver, msg.sender);
    }

    /// @inheritdoc IERC7540Redeem
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId) {
        if (shares == 0) revert INVALID_PARAMETERS();
        if (owner != msg.sender && !_isOperator[owner][msg.sender]) revert INVALID_CALLER();

        // no requestId associated with this request
        requestId = 0;

        // Transfer the shares from the owner to this contract
        transferFrom(owner, address(this), shares);

        // Accrue the shares pending to be redeemed by this controller
        _pendingRedeemRequest[controller] += shares;

        emit RedeemRequest(controller, owner, requestId, msg.sender, shares);
    }

    /// @inheritdoc IStableYieldAsyncVault
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets) {
        if (controller != msg.sender && !_isOperator[controller][msg.sender]) revert INVALID_CALLER();
        assets = _redeem(shares, receiver, controller);
    }

    /// @inheritdoc IStableYieldAsyncVault
    function withdraw(uint256 assets, address receiver, address controller) external returns (uint256 shares) {
        if (controller != msg.sender && !_isOperator[controller][msg.sender]) revert INVALID_CALLER();
        shares = _withdraw(assets, receiver, controller);
    }

    /// @inheritdoc IERC7540Operator
    function setOperator(address operator, bool approved) external returns (bool success) {
        _isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        success = true;
    }

    //   _    ___                 ______                 __  _
    //  | |  / (_)__ _      __   / ____/_  ______  _____/ /_(_)___  ____  _____
    //  | | / / / _ \ | /| / /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //  | |/ / /  __/ |/ |/ /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  |___/_/\___/|__/|__/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @inheritdoc IERC4626
    function convertToShares(uint256 assets) public view returns (uint256 shares) {
        /// NOTE : this assumes that shareToken and assetToken have the same decimals.
        /// FIXME : to consider the totalAssets reported by the YieldStrategy at last epoch transition
        /// instead of the instantaneous totalAssets which may fluctuate due to pending requests and unrealized yield.

        shares = assets.mulDiv(totalSupply(), totalAssets() + 1);
    }

    /// @inheritdoc IERC4626
    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        /// NOTE : this assumes that shareToken and assetToken have the same decimals.
        /// FIXME : to consider the totalAssets reported by the YieldStrategy at last epoch transition
        /// instead of the instantaneous totalAssets which may fluctuate due to pending requests and unrealized yield.
        assets = shares.mulDiv(totalAssets() + 1, totalSupply());
    }

    /// @inheritdoc IERC7540Deposit
    function pendingDepositRequest(uint256, address controller) external view returns (uint256 assets) {
        assets = _pendingDepositRequest[controller];
    }

    /// @inheritdoc IERC7540Deposit
    function claimableDepositRequest(uint256, address controller) external view returns (uint256 assets) {
        assets = _claimableDepositRequest[controller];
    }

    /// @inheritdoc IERC7540Redeem
    function pendingRedeemRequest(uint256, address controller) external view returns (uint256 shares) {
        shares = _pendingRedeemRequest[controller];
    }

    /// @inheritdoc IERC7540Redeem
    function claimableRedeemRequest(uint256, address controller) external view returns (uint256 shares) {
        shares = _claimableRedeemRequest[controller];
    }

    /// @inheritdoc IERC7575
    function share() external view returns (address shareTokenAddress) {
        shareTokenAddress = address(this);
    }

    /// @inheritdoc IERC4626
    function asset() external view returns (address assetTokenAddress) {
        assetTokenAddress = address(underlyingAsset);
    }

    /// @inheritdoc IERC4626
    function totalAssets() public view returns (uint256 total) {
        /// FIXME : shall be equal to YieldStrategy NAV + unutilized capital
        total = underlyingAsset.balanceOf(address(this));
    }

    /// @inheritdoc IERC7540Operator
    function isOperator(address controller, address operator) public view returns (bool status) {
        status = _isOperator[controller][operator];
    }

    /// @inheritdoc IERC4626
    function maxDeposit(address receiver) external view returns (uint256 maxAssets) {
        maxAssets = _claimableDepositRequest[receiver];
    }

    /// @inheritdoc IERC4626
    function maxMint(address receiver) external view returns (uint256 maxShares) {
        maxShares = convertToShares(_claimableDepositRequest[receiver]);
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address owner) external view returns (uint256 maxShares) {
        maxShares = _claimableRedeemRequest[owner];
    }

    /// @inheritdoc IERC4626
    function maxWithdraw(address owner) external view returns (uint256 maxAssets) {
        maxAssets = convertToAssets(_claimableRedeemRequest[owner]);
    }

    /// @notice MUST revert for fully async vaults per ERC-7540 standard
    function previewDeposit(uint256) external view returns (uint256) {
        revert NOT_SUPPORTED_BY_ASYNC_VAULT();
    }

    /// @notice MUST revert for fully async vaults per ERC-7540 standard
    function previewMint(uint256) external view returns (uint256) {
        revert NOT_SUPPORTED_BY_ASYNC_VAULT();
    }

    /// @notice MUST revert for fully async vaults per ERC-7540 standard
    function previewRedeem(uint256) external view returns (uint256) {
        revert NOT_SUPPORTED_BY_ASYNC_VAULT();
    }

    /// @notice MUST revert for fully async vaults per ERC-7540 standard
    function previewWithdraw(uint256) external view returns (uint256) {
        revert NOT_SUPPORTED_BY_ASYNC_VAULT();
    }

    //      ____      __                        __   ______                 __  _
    //     /  _/___  / /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //     / // __ \/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   _/ // / / / /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /___/_/ /_/\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    function _deposit(uint256 assets, address receiver, address controller) internal returns (uint256 shares) {
        if (assets == 0) revert INVALID_PARAMETERS();

        // underflow would revert if not enough claimable assets
        _claimableDepositRequest[controller] -= assets;

        shares = convertToShares(assets);

        _mint(receiver, shares);

        emit Deposit(controller, receiver, assets, shares);
    }

    function _mintShares(uint256 shares, address receiver, address controller) internal returns (uint256 assets) {
        if (shares == 0) revert INVALID_PARAMETERS();

        assets = convertToAssets(shares);

        // underflow would revert if not enough claimable shares
        _claimableDepositRequest[controller] -= assets;

        _mint(receiver, shares);

        emit Deposit(controller, receiver, assets, shares);
    }

    function _redeem(uint256 shares, address receiver, address controller) internal returns (uint256 assets) {
        if (shares == 0) revert INVALID_PARAMETERS();

        // underflow would revert if not enough claimable shares
        _claimableRedeemRequest[controller] -= shares;

        assets = convertToAssets(shares);

        // Burn shares pre-transferred to this contract in requestRedeem
        _burn(address(this), shares);

        // Transfer assets to the receiver
        underlyingAsset.transfer(receiver, assets);

        emit Withdraw(controller, receiver, receiver, assets, shares);
    }

    function _withdraw(uint256 assets, address receiver, address controller) internal returns (uint256 shares) {
        if (assets == 0) revert INVALID_PARAMETERS();

        shares = convertToShares(assets);

        // underflow would revert if not enough claimable assets
        _claimableRedeemRequest[controller] -= shares;

        // Burn shares pre-transferred to this contract in requestRedeem
        _burn(address(this), shares);

        // Transfer assets to the receiver
        underlyingAsset.transfer(receiver, assets);

        emit Withdraw(controller, receiver, receiver, assets, shares);
    }

}
