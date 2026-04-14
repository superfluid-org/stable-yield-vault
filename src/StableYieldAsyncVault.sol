// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IFundManager } from "./interfaces/IFundManager.sol";

import { IRedeemClaimingRoom } from "./interfaces/IRedeemClaimingRoom.sol";
import {
    IERC4626,
    IERC7540Deposit,
    IERC7540Operator,
    IERC7540Redeem,
    IERC7575,
    IStableYieldAsyncVault
} from "./interfaces/vault/IStableYieldAsyncVault.sol";
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

    /// @dev Claimable deposits stored in both units (pre-computed at the epoch settlement rate)
    ///      deposit() deducts from assets, mint() deducts from shares, both proportionally adjust the other
    mapping(address controller => uint256 assets) private _claimableDepositAssets;
    mapping(address controller => uint256 shares) private _claimableDepositShares;

    mapping(address controller => uint256 shares) private _pendingRedeemRequest;

    /// @dev Claimable redeems stored in both units (pre-computed at the epoch settlement rate)
    ///      redeem() deducts from shares, withdraw() deducts from assets, both proportionally adjust the other
    mapping(address controller => uint256 shares) private _claimableRedeemShares;
    mapping(address controller => uint256 assets) private _claimableRedeemAssets;

    /// @dev Tracks which epoch each controller's pending deposit belongs to
    mapping(address controller => uint256 epoch) private _depositRequestEpoch;

    /// @dev Tracks which epoch each controller's pending redeem belongs to
    mapping(address controller => uint256 epoch) private _redeemRequestEpoch;

    /// @dev Exchange rate snapshot per settled epoch (assetsPerShare, scaled by 1e18)
    mapping(uint256 epoch => uint256 assetsPerShare) private _epochRate;

    Snapshot private _snapshot;
    IERC20 public underlyingAsset;
    IFundManager public fundManager;
    IRedeemClaimingRoom public redeemClaimingRoom;

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
     * @param _fundManager The address of the FundManager contract
     * @param _redeemClaimingRoom The address of the RedeemClaimingRoom contract
     * @param name The name of the share token.
     * @param symbol The symbol of the share token.
     */
    constructor(
        IERC20 _underlyingAsset,
        address _fundManager,
        address _redeemClaimingRoom,
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {
        underlyingAsset = _underlyingAsset;
        fundManager = IFundManager(_fundManager);
        redeemClaimingRoom = IRedeemClaimingRoom(_redeemClaimingRoom);
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
        if (_snapshot.rate != 0) revert EPOCH_SETTLEMENT_IN_PROGRESS();

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
        if (_snapshot.rate != 0) revert EPOCH_SETTLEMENT_IN_PROGRESS();

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
    function closeEpoch(uint256 _totalAssets) external onlyFundManager {
        if (_snapshot.rate != 0) revert PREVIOUS_EPOCH_NOT_SETTLED();

        uint256 shareSupply = totalSupply();
        uint256 epochRate = shareSupply == 0 ? 1e18 : _totalAssets.mulDiv(1e18, shareSupply);

        _snapshot = Snapshot({
            epoch: currentEpoch,
            depositingAssets: totalPendingDepositAssets,
            redeemingShares: totalPendingRedeemShares,
            rate: epochRate
        });

        // Update epoch accounting
        totalPendingDepositAssets = 0;
        totalPendingRedeemShares = 0;

        // Increment current epoch (future requests will be included in the new epoch)
        currentEpoch++;
    }

    /// @inheritdoc IStableYieldAsyncVault
    function settleEpoch() external onlyFundManager {
        if (_snapshot.rate == 0) revert NO_EPOCH_TO_SETTLE();

        // Convert pending redeems to asset terms using the epoch rate
        uint256 redeemAssets = _snapshot.redeemingShares.mulDiv(_snapshot.rate, 1e18);

        if (_snapshot.depositingAssets >= redeemAssets) {
            // TODO
            // 1- move `redeemAssets` amount from DepositWaitingRoom to RedeemClaimingRoom
            // 2- move `surplus` (if any) amount from DepositWaitingRoom to the FundManager
        } else {
            // TODO :
            // 1- move `depositingAssets` amount from DepositWaitingRoom to RedeemClaimingRoom
            // 2- pull `deficit` amount from the FundManager to RedeemClaimingRoom
        }

        // Commit the epoch rate for the settled epoch
        _epochRate[_snapshot.epoch] = _snapshot.rate;

        uint256 totalAssetValue = _snapshot.rate.mulDiv(totalSupply(), 1e18);
        emit EpochSettled(
            _snapshot.epoch, totalAssetValue, _snapshot.rate, _snapshot.depositingAssets, _snapshot.redeemingShares
        );

        // Clear the snapshot as it has been settled
        delete _snapshot;
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

    /// @inheritdoc IStableYieldAsyncVault
    function getSnapshot() external view returns (Snapshot memory) {
        return _snapshot;
    }

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
        uint256 pending = _pendingDepositRequest[controller];

        // If the epoch has been settled, this is no longer truly pending (it's claimable)
        if (pending > 0 && _epochRate[_depositRequestEpoch[controller]] != 0) return 0;
        assets = pending;
    }

    /// @inheritdoc IERC7540Deposit
    function claimableDepositRequest(uint256, address controller) external view returns (uint256 assets) {
        assets = _effectiveClaimableDepositAssets(controller);
    }

    /// @inheritdoc IERC7540Redeem
    function pendingRedeemRequest(uint256, address controller) external view returns (uint256 shares) {
        uint256 pending = _pendingRedeemRequest[controller];
        // If the epoch has been settled, this is no longer truly pending (it's claimable)
        if (pending > 0 && _epochRate[_redeemRequestEpoch[controller]] != 0) return 0;
        shares = pending;
    }

    /// @inheritdoc IERC7540Redeem
    function claimableRedeemRequest(uint256, address controller) external view returns (uint256 shares) {
        shares = _effectiveClaimableRedeemShares(controller);
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
        /// FIXME
    }

    /// @inheritdoc IERC7540Operator
    function isOperator(address controller, address operator) public view returns (bool status) {
        status = _isOperator[controller][operator];
    }

    /// @inheritdoc IERC4626
    function maxDeposit(address controller) external view returns (uint256 maxAssets) {
        maxAssets = _effectiveClaimableDepositAssets(controller);
    }

    /// @inheritdoc IERC4626
    function maxMint(address controller) external view returns (uint256 maxShares) {
        maxShares = _effectiveClaimableDepositShares(controller);
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address controller) external view returns (uint256 maxShares) {
        maxShares = _effectiveClaimableRedeemShares(controller);
    }

    /// @inheritdoc IERC4626
    function maxWithdraw(address controller) external view returns (uint256 maxAssets) {
        maxAssets = _effectiveClaimableRedeemAssets(controller);
    }

    /// @notice MUST revert for fully async vaults per ERC-7540 standard
    function previewDeposit(uint256) external pure returns (uint256) {
        revert NOT_SUPPORTED_BY_ASYNC_VAULT();
    }

    /// @notice MUST revert for fully async vaults per ERC-7540 standard
    function previewMint(uint256) external pure returns (uint256) {
        revert NOT_SUPPORTED_BY_ASYNC_VAULT();
    }

    /// @notice MUST revert for fully async vaults per ERC-7540 standard
    function previewRedeem(uint256) external pure returns (uint256) {
        revert NOT_SUPPORTED_BY_ASYNC_VAULT();
    }

    /// @notice MUST revert for fully async vaults per ERC-7540 standard
    function previewWithdraw(uint256) external pure returns (uint256) {
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

        // Proportional deduction: assets is the native unit, derive shares
        shares = assets.mulDiv(_claimableDepositShares[controller], _claimableDepositAssets[controller]);
        _claimableDepositAssets[controller] -= assets;
        _claimableDepositShares[controller] -= shares;

        _mint(receiver, shares);

        emit Deposit(controller, receiver, assets, shares);
    }

    function _mintShares(uint256 shares, address receiver, address controller) internal returns (uint256 assets) {
        if (shares == 0) revert INVALID_PARAMETERS();

        // Lazy-settle any pending deposit from a previous epoch
        _settleDepositIfNeeded(controller);

        // Proportional deduction: shares is the native unit, derive assets
        assets = shares.mulDiv(_claimableDepositAssets[controller], _claimableDepositShares[controller]);
        _claimableDepositShares[controller] -= shares;
        _claimableDepositAssets[controller] -= assets;

        _mint(receiver, shares);

        emit Deposit(controller, receiver, assets, shares);
    }

    function _redeem(uint256 shares, address receiver, address controller) internal returns (uint256 assets) {
        if (shares == 0) revert INVALID_PARAMETERS();

        // Lazy-settle any pending redeem from a previous epoch
        _settleRedeemIfNeeded(controller);

        // Proportional deduction: shares is the native unit, derive assets
        assets = shares.mulDiv(_claimableRedeemAssets[controller], _claimableRedeemShares[controller]);
        _claimableRedeemShares[controller] -= shares;
        _claimableRedeemAssets[controller] -= assets;

        // Burn shares pre-transferred to this contract in requestRedeem
        _burn(address(this), shares);

        // Redeem assets for the receiver from the RedeemClaimingRoom
        redeemClaimingRoom.redeemFor(receiver, assets);

        emit Withdraw(controller, receiver, receiver, assets, shares);
    }

    function _withdraw(uint256 assets, address receiver, address controller) internal returns (uint256 shares) {
        if (assets == 0) revert INVALID_PARAMETERS();

        // Lazy-settle any pending redeem from a previous epoch
        _settleRedeemIfNeeded(controller);

        // Proportional deduction: assets is the native unit, derive shares
        shares = assets.mulDiv(_claimableRedeemShares[controller], _claimableRedeemAssets[controller]);
        _claimableRedeemAssets[controller] -= assets;
        _claimableRedeemShares[controller] -= shares;

        // Burn shares pre-transferred to this contract in requestRedeem
        _burn(address(this), shares);

        // Redeem assets for the receiver from the RedeemClaimingRoom
        redeemClaimingRoom.redeemFor(receiver, assets);

        emit Withdraw(controller, receiver, receiver, assets, shares);
    }

    /// @dev Returns the exchange rate from the last settled epoch.
    ///      Before any epoch has settled, returns 1e18 (1:1).
    ///      During close/settle window, falls back to the epoch before.
    function _lastSettledRate() internal view returns (uint256) {
        if (currentEpoch == 0) return 1e18;
        uint256 rate = _epochRate[currentEpoch - 1];
        if (rate != 0) return rate;
        // Previous epoch is closed but not yet settled — use the one before
        if (currentEpoch <= 1) return 1e18;
        return _epochRate[currentEpoch - 2];
    }

    /// @dev If the controller has a pending deposit from a settled (past) epoch,
    ///      convert pending assets → claimable (both assets and shares) at the epoch's settlement rate.
    function _settleDepositIfNeeded(address controller) internal {
        uint256 pendingAssets = _pendingDepositRequest[controller];
        if (pendingAssets == 0) return;

        uint256 epochRate = _epochRate[_depositRequestEpoch[controller]];
        if (epochRate == 0) return; // epoch not yet settled

        uint256 pendingShares = pendingAssets.mulDiv(1e18, epochRate);
        _claimableDepositAssets[controller] += pendingAssets;
        _claimableDepositShares[controller] += pendingShares;
        _pendingDepositRequest[controller] = 0;
    }

    /// @dev If the controller has a pending redeem from a settled (past) epoch,
    ///      convert pending shares → claimable (both shares and assets) at the epoch's settlement rate.
    function _settleRedeemIfNeeded(address controller) internal {
        uint256 pendingShares = _pendingRedeemRequest[controller];
        if (pendingShares == 0) return;

        uint256 epochRate = _epochRate[_redeemRequestEpoch[controller]];
        if (epochRate == 0) return; // epoch not yet settled

        uint256 pendingAssets = pendingShares.mulDiv(epochRate, 1e18);
        _claimableRedeemShares[controller] += pendingShares;
        _claimableRedeemAssets[controller] += pendingAssets;
        _pendingRedeemRequest[controller] = 0;
    }

    /// @dev Read-only: claimable deposit assets, including unsettled pending that has become claimable.
    function _effectiveClaimableDepositAssets(address controller) internal view returns (uint256 assets) {
        assets = _claimableDepositAssets[controller];
        uint256 pending = _pendingDepositRequest[controller];
        if (pending > 0 && _epochRate[_depositRequestEpoch[controller]] != 0) {
            assets += pending;
        }
    }

    /// @dev Read-only: claimable deposit shares, including unsettled pending that has become claimable.
    function _effectiveClaimableDepositShares(address controller) internal view returns (uint256 shares) {
        shares = _claimableDepositShares[controller];
        uint256 pending = _pendingDepositRequest[controller];
        if (pending > 0) {
            uint256 epochRate = _epochRate[_depositRequestEpoch[controller]];
            if (epochRate != 0) {
                shares += pending.mulDiv(1e18, epochRate);
            }
        }
    }

    /// @dev Read-only: claimable redeem shares, including unsettled pending that has become claimable.
    function _effectiveClaimableRedeemShares(address controller) internal view returns (uint256 shares) {
        shares = _claimableRedeemShares[controller];
        uint256 pending = _pendingRedeemRequest[controller];
        if (pending > 0 && _epochRate[_redeemRequestEpoch[controller]] != 0) {
            shares += pending;
        }
    }

    /// @dev Read-only: claimable redeem assets, including unsettled pending that has become claimable.
    function _effectiveClaimableRedeemAssets(address controller) internal view returns (uint256 assets) {
        assets = _claimableRedeemAssets[controller];
        uint256 pending = _pendingRedeemRequest[controller];
        if (pending > 0) {
            uint256 epochRate = _epochRate[_redeemRequestEpoch[controller]];
            if (epochRate != 0) {
                assets += pending.mulDiv(epochRate, 1e18);
            }
        }
    }

    modifier onlyFundManager() {
        if (msg.sender != address(fundManager)) revert INVALID_CALLER();
        _;
    }

}
