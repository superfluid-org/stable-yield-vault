// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IERC4626, IStableYieldAsyncVault } from "./interfaces/IStableYieldAsyncVault.sol";
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

    IERC20 public underlyingAsset;

    //     ______                 __                  __
    //    / ____/___  ____  _____/ /________  _______/ /_____  _____
    //   / /   / __ \/ __ \/ ___/ __/ ___/ / / / ___/ __/ __ \/ ___/
    //  / /___/ /_/ / / / (__  ) /_/ /  / /_/ / /__/ /_/ /_/ / /
    //  \____/\____/_/ /_/____/\__/_/   \__,_/\___/\__/\____/_/

    //      ______     __                        __   ______                 __  _
    //     / ____/  __/ /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //    / __/ | |/_/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / /____>  </ /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /_____/_/|_|\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @notice Transfers assets from owner and submits an async deposit request.
    /// @param assets Amount of underlying assets to deposit
    /// @param controller Address that will control this request and claim shares
    /// @param owner Address from which assets are transferred
    /// @return requestId The ID for this request (0 if not using request IDs)
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

    /// @notice Claims shares from a claimable deposit request.
    /// @dev Does NOT transfer assets — they were already transferred on requestDeposit.
    ///      msg.sender must be controller or an approved operator.
    /// @param assets Amount of assets to claim from the claimable balance
    /// @param receiver Address that receives the minted shares
    /// @param controller Address whose claimable request is being consumed
    /// @return shares Amount of shares minted to receiver
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares) {
        if (controller != msg.sender && !_isOperator[controller][msg.sender]) revert INVALID_CALLER();
        _deposit(assets, receiver, controller);
    }

    /// @notice Claims shares from a claimable deposit request.
    /// @dev Does NOT transfer assets — they were already transferred on requestDeposit.
    /// @param assets Amount of assets to claim from the claimable balance
    /// @param receiver Address that receives the minted shares
    /// @return shares Amount of shares minted to receiver
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        _deposit(assets, receiver, msg.sender);
    }

    /// @notice Claims a specific number of shares from a claimable deposit request.
    /// @dev Does NOT transfer assets — they were already transferred on requestDeposit.
    ///      msg.sender must be controller or an approved operator.
    /// @param shares Amount of shares to mint
    /// @param receiver Address that receives the minted shares
    /// @param controller Address whose claimable request is being consumed
    /// @return assets Amount of assets consumed from the claimable balance
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets) {
        if (controller != msg.sender && !_isOperator[controller][msg.sender]) revert INVALID_CALLER();
        _mintShares(shares, receiver, controller);
    }

    /// @notice Claims a specific number of shares from a claimable deposit request.
    /// @dev Does NOT transfer assets — they were already transferred on requestDeposit.
    /// @param shares Amount of shares to mint
    /// @param receiver Address that receives the minted shares
    /// @return assets Amount of assets consumed from the claimable balance
    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        _mintShares(shares, receiver, msg.sender);
    }

    /// @notice Grants or revokes operator permissions for msg.sender.
    /// @param operator The address to approve or revoke
    /// @param approved True to approve, false to revoke
    /// @return success Always returns true
    function setOperator(address operator, bool approved) external returns (bool success) {
        _isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        success = true;
    }

    //      ____      __                        __   ______                 __  _
    //     /  _/___  / /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //     / // __ \/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   _/ // / / / /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /___/_/ /_/\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    function _mintShares(uint256 shares, address receiver, address controller) internal returns (uint256 assets) {
        if (shares == 0) revert INVALID_PARAMETERS();

        assets = convertToAssets(shares);
        // this naive example uses the instantaneous exchange rate.
        // It may be more common to use the rate locked in upon Claimable stage.

        // underflow would revert if not enough claimable shares
        _claimableDepositRequest[controller] -= assets;

        _mint(receiver, shares);

        emit Deposit(controller, receiver, assets, shares);
    }

    function _deposit(uint256 assets, address receiver, address controller) internal returns (uint256 shares) {
        if (assets == 0) revert INVALID_PARAMETERS();

        // underflow would revert if not enough claimable assets
        _claimableDepositRequest[controller] -= assets;

        // this naive example uses the instantaneous exchange rate.
        // It may be more common to use the rate locked in upon Claimable stage.
        shares = convertToShares(assets);

        _mint(receiver, shares);

        emit Deposit(controller, receiver, assets, shares);
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

    /// @notice Returns the amount of assets in Pending state for a controller.
    /// @param controller The address that controls the request
    /// @return assets Amount of assets still pending
    function pendingDepositRequest(uint256, address controller) external view returns (uint256 assets) {
        assets = _pendingDepositRequest[controller];
    }

    /// @notice Returns the amount of assets in Claimable state for a controller.
    /// @param controller The address that controls the request
    /// @return assets Amount of assets ready to be claimed via deposit/mint
    function claimableDepositRequest(uint256, address controller) external view returns (uint256 assets) {
        assets = _claimableDepositRequest[controller];
    }

    /// @notice Returns the address of the share token.
    /// @return shareTokenAddress The address of the ERC-20 share token
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

    /// @notice Returns whether an operator is approved for a controller.
    /// @param controller The address that granted approval
    /// @param operator The address to check
    /// @return status True if the operator is approved
    function isOperator(address controller, address operator) public view returns (bool status) {
        status = _isOperator[controller][operator];
    }

    /// @notice MUST revert for fully async vaults.
    /// @dev Refer to ERC-7540 standard
    function previewDeposit(uint256) external view returns (uint256) {
        revert NOT_SUPPORTED_BY_ASYNC_VAULT();
    }

    /// @notice MUST revert for fully async vaults.
    /// @dev Refer to ERC-7540 standard
    function previewMint(uint256) external view returns (uint256) {
        revert NOT_SUPPORTED_BY_ASYNC_VAULT();
    }

    /// @notice MUST revert for fully async vaults.
    /// @dev Refer to ERC-7540 standard
    function previewRedeem(uint256) external view returns (uint256) {
        revert NOT_SUPPORTED_BY_ASYNC_VAULT();
    }

    /// @notice MUST revert for fully async vaults.
    /// @dev Refer to ERC-7540 standard
    function previewWithdraw(uint256) external view returns (uint256) {
        revert NOT_SUPPORTED_BY_ASYNC_VAULT();
    }

    //      ____      __                        __   ______                 __  _
    //     /  _/___  / /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //     / // __ \/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   _/ // / / / /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /___/_/ /_/\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

}
