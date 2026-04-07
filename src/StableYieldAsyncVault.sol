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
import { IYieldStrategy } from "./interfaces/IYieldStrategy.sol";
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

    /// @dev Tracks which epoch each controller's pending deposit belongs to
    mapping(address controller => uint256 epoch) private _depositRequestEpoch;
    /// @dev Tracks which epoch each controller's pending redeem belongs to
    mapping(address controller => uint256 epoch) private _redeemRequestEpoch;

    /// @dev Exchange rate snapshot per settled epoch (assetsPerShare, scaled by 1e18)
    mapping(uint256 epoch => uint256 assetsPerShare) private _epochRate;

    IERC20 public underlyingAsset;
    IYieldStrategy private _yieldStrategy;
    address public vaultOperator;

    uint256 public currentEpoch;
    uint256 public totalPendingDepositAssets;
    uint256 public totalPendingRedeemShares;

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
    constructor(
        IERC20 _underlyingAsset,
        IYieldStrategy yieldStrategy_,
        address _vaultOperator,
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {
        underlyingAsset = _underlyingAsset;
        _yieldStrategy = yieldStrategy_;
        vaultOperator = _vaultOperator;
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

        // Lazy-settle any pending deposit from a previous epoch
        _settleDepositIfNeeded(controller);

        // Transfer the underlying asset from the owner to this contract
        underlyingAsset.transferFrom(owner, address(this), assets);

        // Accrue the assets deposited by this controller
        _pendingDepositRequest[controller] += assets;
        totalPendingDepositAssets += assets;
        _depositRequestEpoch[controller] = currentEpoch;

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

        // Lazy-settle any pending redeem from a previous epoch
        _settleRedeemIfNeeded(controller);

        // Transfer the shares from the owner to this contract
        transferFrom(owner, address(this), shares);

        // Accrue the shares pending to be redeemed by this controller
        _pendingRedeemRequest[controller] += shares;
        totalPendingRedeemShares += shares;
        _redeemRequestEpoch[controller] = currentEpoch;

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

    /// @inheritdoc IStableYieldAsyncVault
    function settleEpoch() external {
        if (msg.sender != vaultOperator) revert INVALID_CALLER();

        uint256 epoch = currentEpoch;

        // Compute rate excluding pending flows
        uint256 effectiveAssets =
            _yieldStrategy.totalValue() + underlyingAsset.balanceOf(address(this)) - totalPendingDepositAssets;
        uint256 effectiveSupply = totalSupply() - totalPendingRedeemShares;

        // assetsPerShare scaled by 1e18; if no shares exist yet, 1:1
        uint256 assetsPerShare = effectiveSupply == 0 ? 1e18 : effectiveAssets.mulDiv(1e18, effectiveSupply);
        _epochRate[epoch] = assetsPerShare;

        // Convert pending redeems to asset terms using the epoch rate
        uint256 redeemAssets = totalPendingRedeemShares.mulDiv(assetsPerShare, 1e18);

        // Net and move funds
        if (totalPendingDepositAssets > redeemAssets) {
            // Net inflow : deploy excess into strategy
            uint256 toDeploy = totalPendingDepositAssets - redeemAssets;
            underlyingAsset.approve(address(_yieldStrategy), toDeploy);
            _yieldStrategy.deploy(toDeploy);
        } else if (redeemAssets > totalPendingDepositAssets) {
            // Net outflow : liquidate from strategy to cover redemptions
            uint256 toLiquidate = redeemAssets - totalPendingDepositAssets;
            _yieldStrategy.liquidate(toLiquidate);
        }

        emit EpochSettled(epoch, effectiveAssets, assetsPerShare, totalPendingDepositAssets, totalPendingRedeemShares);

        // Update epoch accounting
        totalPendingDepositAssets = 0;
        totalPendingRedeemShares = 0;
        currentEpoch = epoch + 1;
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
        uint256 rate = _lastSettledRate();
        shares = assets.mulDiv(1e18, rate);
    }

    /// @inheritdoc IERC4626
    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        uint256 rate = _lastSettledRate();
        assets = shares.mulDiv(rate, 1e18);
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
        total = _yieldStrategy.totalValue() + underlyingAsset.balanceOf(address(this));
    }

    /// @inheritdoc IERC7540Operator
    function isOperator(address controller, address operator) public view returns (bool status) {
        status = _isOperator[controller][operator];
    }

    /// @inheritdoc IStableYieldAsyncVault
    function yieldStrategy() external view returns (address) {
        return address(_yieldStrategy);
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

    /// @inheritdoc IStableYieldAsyncVault
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0xe3bc4e65 // IERC7540Operator
            || interfaceId == 0x2f0a18c5 // IERC7575
            || interfaceId == 0xce3bbe50 // IERC7540Deposit
            || interfaceId == 0x620ee8e4; // IERC7540Redeem
    }

    //      ____      __                        __   ______                 __  _
    //     /  _/___  / /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //     / // __ \/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   _/ // / / / /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /___/_/ /_/\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    function _deposit(uint256 assets, address receiver, address controller) internal returns (uint256 shares) {
        if (assets == 0) revert INVALID_PARAMETERS();

        // Lazy-settle any pending deposit from a previous epoch
        _settleDepositIfNeeded(controller);

        // underflow would revert if not enough claimable assets
        _claimableDepositRequest[controller] -= assets;

        shares = convertToShares(assets);

        _mint(receiver, shares);

        emit Deposit(controller, receiver, assets, shares);
    }

    function _mintShares(uint256 shares, address receiver, address controller) internal returns (uint256 assets) {
        if (shares == 0) revert INVALID_PARAMETERS();

        // Lazy-settle any pending deposit from a previous epoch
        _settleDepositIfNeeded(controller);

        assets = convertToAssets(shares);

        // underflow would revert if not enough claimable assets
        _claimableDepositRequest[controller] -= assets;

        _mint(receiver, shares);

        emit Deposit(controller, receiver, assets, shares);
    }

    function _redeem(uint256 shares, address receiver, address controller) internal returns (uint256 assets) {
        if (shares == 0) revert INVALID_PARAMETERS();

        // Lazy-settle any pending redeem from a previous epoch
        _settleRedeemIfNeeded(controller);

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

        // Lazy-settle any pending redeem from a previous epoch
        _settleRedeemIfNeeded(controller);

        shares = convertToShares(assets);

        // underflow would revert if not enough claimable shares
        _claimableRedeemRequest[controller] -= shares;

        // Burn shares pre-transferred to this contract in requestRedeem
        _burn(address(this), shares);

        // Transfer assets to the receiver
        underlyingAsset.transfer(receiver, assets);

        emit Withdraw(controller, receiver, receiver, assets, shares);
    }

    /// @dev Returns the exchange rate from the last settled epoch.
    ///      Before any epoch has settled (epoch 0), returns 1e18 (1:1).
    function _lastSettledRate() internal view returns (uint256) {
        if (currentEpoch == 0) return 1e18;
        return _epochRate[currentEpoch - 1];
    }

    /// @dev If the controller has a pending deposit from a settled (past) epoch,
    ///      convert it to claimable using the stored epoch rate.
    function _settleDepositIfNeeded(address controller) internal {
        uint256 pending = _pendingDepositRequest[controller];
        if (pending == 0) return;

        uint256 requestEpoch = _depositRequestEpoch[controller];
        if (requestEpoch >= currentEpoch) return; // not yet settled

        // Convert pending assets → claimable assets (stays in asset terms,
        // the share conversion happens at claim time using the epoch rate)
        _claimableDepositRequest[controller] += pending;
        _pendingDepositRequest[controller] = 0;
    }

    /// @dev If the controller has a pending redeem from a settled (past) epoch,
    ///      convert it to claimable using the stored epoch rate.
    function _settleRedeemIfNeeded(address controller) internal {
        uint256 pending = _pendingRedeemRequest[controller];
        if (pending == 0) return;

        uint256 requestEpoch = _redeemRequestEpoch[controller];
        if (requestEpoch >= currentEpoch) return; // not yet settled

        // Convert pending shares → claimable shares
        _claimableRedeemRequest[controller] += pending;
        _pendingRedeemRequest[controller] = 0;
    }

}
