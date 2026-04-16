// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IFundManager } from "./interfaces/IFundManager.sol";

import { IWaitingRoom } from "./interfaces/IWaitingRoom.sol";
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

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract StableYieldAsynchronousVault is ERC20, IStableYieldAsyncVault {

    using Math for uint256;
    using SafeERC20 for IERC20;

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

    /// @dev Tracks which epoch each controller's pending deposit belongs to
    mapping(address controller => uint256 epoch) private _depositRequestEpoch;

    mapping(address controller => uint256 assets) private _pendingDepositRequest;

    /// @dev Claimable deposits stored in both units (pre-computed at the epoch settlement rate)
    ///      deposit() deducts from assets, mint() deducts from shares, both proportionally adjust the other
    mapping(address controller => uint256 assets) private _claimableDepositAssets;
    mapping(address controller => uint256 shares) private _claimableDepositShares;

    /// @dev Tracks which epoch each controller's pending redeem belongs to
    mapping(address controller => uint256 epoch) private _redeemRequestEpoch;

    mapping(address controller => uint256 shares) private _pendingRedeemRequest;

    /// @dev Claimable redeems stored in both units (pre-computed at the epoch settlement rate)
    ///      redeem() deducts from shares, withdraw() deducts from assets, both proportionally adjust the other
    mapping(address controller => uint256 shares) private _claimableRedeemShares;
    mapping(address controller => uint256 assets) private _claimableRedeemAssets;

    /// @dev Exchange rate snapshot per settled epoch (assetsPerShare, scaled by 1e18)
    mapping(uint256 epoch => uint256 assetsPerShare) private _epochRate;
    mapping(uint256 epoch => bool isSettled) private _epochSettled;

    /// @dev Cache of the last settled epoch total assets
    uint256 private _lastReportedTotalAssets;

    /// @dev Total shares owed to settled depositors who haven't claimed yet.
    ///      These "phantom" shares don't exist in totalSupply but represent committed positions.
    uint256 private _unclaimedDepositShares;

    /// @dev Total shares held by the vault for settled redeemers who haven't claimed yet.
    ///      These "dead" shares are still in totalSupply but their backing assets have left NAV.
    uint256 private _unclaimedRedeemShares;

    Snapshot private _snapshot;
    IERC20 public underlyingAsset;
    IFundManager public fundManager;
    IWaitingRoom public redeemWaitingRoom;
    IWaitingRoom public depositWaitingRoom;

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
     * @param _redeemWaitingRoom The address of the Redeem WaitingRoom contract
     * @param _depositWaitingRoom The address of the Deposit WaitingRoom contract
     * @param name The name of the share token.
     * @param symbol The symbol of the share token.
     */
    constructor(
        IERC20 _underlyingAsset,
        address _fundManager,
        address _redeemWaitingRoom,
        address _depositWaitingRoom,
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {
        underlyingAsset = _underlyingAsset;
        fundManager = IFundManager(_fundManager);
        redeemWaitingRoom = IWaitingRoom(_redeemWaitingRoom);
        depositWaitingRoom = IWaitingRoom(_depositWaitingRoom);

        // Initialize the first epoch to 1
        currentEpoch = 1;
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
        if (_snapshot.epoch != 0) revert EPOCH_SETTLEMENT_IN_PROGRESS();

        // no requestId associated with this request
        requestId = 0;

        // Lazy-settle any pending deposit from a previous epoch
        _settleDepositIfNeeded(controller);

        // Transfer the underlying asset from the owner to the DepositWaitingRoom contract
        underlyingAsset.safeTransferFrom(owner, address(depositWaitingRoom), assets);

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
        if (_snapshot.epoch != 0) revert EPOCH_SETTLEMENT_IN_PROGRESS();

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
        // Reject total-loss scenarios
        if (_totalAssets == 0) revert INVALID_PARAMETERS();

        // Ensure previous epoch has been settled before allowing close of a new epoch
        if (_snapshot.epoch != 0) revert PREVIOUS_EPOCH_NOT_SETTLED();

        // Compute effective supply: actual supply + phantom deposit shares - dead redeem shares.
        // This corrects for the lag between settlement (assets move) and claim (shares mint/burn).
        uint256 effectiveSupply = totalSupply() + _unclaimedDepositShares - _unclaimedRedeemShares;

        // Calculate the epoch rate (assets per share) using the total assets reported by the FundManager
        uint256 epochRate = effectiveSupply == 0 ? 1e18 : _totalAssets.mulDiv(1e18, effectiveSupply);

        // Take a snapshot of the epoch's pending deposits and redeems to be used during settlement
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

        // Persist the last reported total assets for view functions
        _lastReportedTotalAssets = _totalAssets;
    }

    /// @inheritdoc IStableYieldAsyncVault
    function settleEpoch() external onlyFundManager {
        uint256 settlingEpoch = _snapshot.epoch;

        if (settlingEpoch == 0) revert NO_EPOCH_TO_SETTLE();

        // Convert pending redeeming shares to asset terms using the epoch rate
        uint256 redeemingAssets = _snapshot.redeemingShares.mulDiv(_snapshot.rate, 1e18);

        if (_snapshot.depositingAssets >= redeemingAssets) {
            if (redeemingAssets > 0) {
                // Move redeemable assets from DepositWaitingRoom to RedeemWaitingRoom
                depositWaitingRoom.move(address(redeemWaitingRoom), redeemingAssets);
            }

            // Calculate surplus of deposits over redeems in asset terms
            uint256 surplus = _snapshot.depositingAssets - redeemingAssets;

            if (surplus > 0) {
                // Move surplus from DepositWaitingRoom to FundManager
                depositWaitingRoom.move(address(fundManager), surplus);
            }
        } else {
            if (_snapshot.depositingAssets > 0) {
                // Move depositing assets from DepositWaitingRoom to RedeemWaitingRoom
                depositWaitingRoom.move(address(redeemWaitingRoom), _snapshot.depositingAssets);
            }

            uint256 deficit = redeemingAssets - _snapshot.depositingAssets;

            // Move deficit from FundManager to RedeemWaitingRoom
            fundManager.move(address(redeemWaitingRoom), deficit);
        }

        // Track unclaimed positions for effective supply adjustment in future closeEpoch calls
        _unclaimedDepositShares += _snapshot.depositingAssets.mulDiv(1e18, _snapshot.rate);
        _unclaimedRedeemShares += _snapshot.redeemingShares;

        // Commit the epoch rate for the settled epoch
        _epochRate[settlingEpoch] = _snapshot.rate;
        _epochSettled[settlingEpoch] = true;

        uint256 totalAssetValue = _snapshot.rate.mulDiv(totalSupply(), 1e18);
        emit EpochSettled(
            settlingEpoch, totalAssetValue, _snapshot.rate, _snapshot.depositingAssets, _snapshot.redeemingShares
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

    function isEpochSettled(uint256 epoch) public view returns (bool isSettled) {
        isSettled = _epochSettled[epoch];
    }

    /// @inheritdoc IStableYieldAsyncVault
    function getSnapshot() external view returns (Snapshot memory snapshot) {
        snapshot = _snapshot;
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
        if (pending > 0 && isEpochSettled(_depositRequestEpoch[controller])) return 0;

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
        if (pending > 0 && isEpochSettled(_redeemRequestEpoch[controller])) return 0;
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
        /**
         * NOTE:
         *      this value is not necessarily up-to-date with the current on-chain state as it relies
         *      on the last reported total assets from the FundManager at the last epoch settlement.
         */
        total = _lastReportedTotalAssets;
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
        if (_claimableDepositAssets[controller] == 0) revert NOTHING_TO_CLAIM();

        // Lazy-settle any pending deposit from a previous epoch
        _settleDepositIfNeeded(controller);

        // Proportional deduction: assets is the native unit, derive shares
        shares = assets.mulDiv(_claimableDepositShares[controller], _claimableDepositAssets[controller]);
        _claimableDepositAssets[controller] -= assets;
        _claimableDepositShares[controller] -= shares;
        _unclaimedDepositShares -= shares;

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function _mintShares(uint256 shares, address receiver, address controller) internal returns (uint256 assets) {
        if (shares == 0) revert INVALID_PARAMETERS();
        if (_claimableDepositAssets[controller] == 0) revert NOTHING_TO_CLAIM();

        // Lazy-settle any pending deposit from a previous epoch
        _settleDepositIfNeeded(controller);

        // Proportional deduction: shares is the native unit, derive assets
        assets = shares.mulDiv(_claimableDepositAssets[controller], _claimableDepositShares[controller]);
        _claimableDepositShares[controller] -= shares;
        _claimableDepositAssets[controller] -= assets;
        _unclaimedDepositShares -= shares;

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function _redeem(uint256 shares, address receiver, address controller) internal returns (uint256 assets) {
        if (shares == 0) revert INVALID_PARAMETERS();
        if (_claimableRedeemAssets[controller] == 0) revert NOTHING_TO_CLAIM();

        // Lazy-settle any pending redeem from a previous epoch
        _settleRedeemIfNeeded(controller);

        // Proportional deduction: shares is the native unit, derive assets
        assets = shares.mulDiv(_claimableRedeemAssets[controller], _claimableRedeemShares[controller]);
        _claimableRedeemShares[controller] -= shares;
        _claimableRedeemAssets[controller] -= assets;
        _unclaimedRedeemShares -= shares;

        // Burn shares pre-transferred to this contract in requestRedeem
        _burn(address(this), shares);

        // Redeem assets for the receiver from the RedeemWaitingRoom
        redeemWaitingRoom.move(receiver, assets);

        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function _withdraw(uint256 assets, address receiver, address controller) internal returns (uint256 shares) {
        if (assets == 0) revert INVALID_PARAMETERS();
        if (_claimableRedeemAssets[controller] == 0) revert NOTHING_TO_CLAIM();

        // Lazy-settle any pending redeem from a previous epoch
        _settleRedeemIfNeeded(controller);

        // Proportional deduction: assets is the native unit, derive shares
        // Round up so at least 1 share is burned per non-zero withdrawal (favors vault)
        shares = assets.mulDiv(_claimableRedeemShares[controller], _claimableRedeemAssets[controller], Math.Rounding.Ceil);
        _claimableRedeemAssets[controller] -= assets;
        _claimableRedeemShares[controller] -= shares;
        _unclaimedRedeemShares -= shares;

        // Burn shares pre-transferred to this contract in requestRedeem
        _burn(address(this), shares);

        // Redeem assets for the receiver from the RedeemWaitingRoom
        redeemWaitingRoom.move(receiver, assets);

        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    /// @dev Returns the exchange rate from the last settled epoch.
    ///      Before any epoch has settled, returns 1e18 (1:1).
    ///      During close/settle window, falls back to the epoch before.
    function _lastSettledRate() internal view returns (uint256 lastSettledRate) {
        // Try the most recent epoch
        if (currentEpoch >= 2 && isEpochSettled(currentEpoch - 1)) {
            lastSettledRate = _epochRate[currentEpoch - 1];
        }
        // Previous epoch closed but not yet settled — try the one before
        else if (currentEpoch >= 3 && isEpochSettled(currentEpoch - 2)) {
            lastSettledRate = _epochRate[currentEpoch - 2];
        } else {
            // Bootstrap: no epochs settled yet
            lastSettledRate = 1e18;
        }
    }

    /// @dev If the controller has a pending deposit from a settled (past) epoch,
    ///      convert pending assets → claimable (both assets and shares) at the epoch's settlement rate.
    function _settleDepositIfNeeded(address controller) internal {
        uint256 pendingAssets = _pendingDepositRequest[controller];
        if (pendingAssets == 0) return;

        uint256 depositRequestEpoch = _depositRequestEpoch[controller];
        if (!isEpochSettled(depositRequestEpoch)) return; // epoch not yet settled

        uint256 epochRate = _epochRate[depositRequestEpoch];

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

        uint256 redeemRequestEpoch = _redeemRequestEpoch[controller];
        if (!isEpochSettled(redeemRequestEpoch)) return; // epoch not yet settled

        uint256 epochRate = _epochRate[redeemRequestEpoch];

        uint256 pendingAssets = pendingShares.mulDiv(epochRate, 1e18);
        _claimableRedeemShares[controller] += pendingShares;
        _claimableRedeemAssets[controller] += pendingAssets;
        _pendingRedeemRequest[controller] = 0;
    }

    /// @dev Read-only: claimable deposit assets, including unsettled pending that has become claimable.
    function _effectiveClaimableDepositAssets(address controller) internal view returns (uint256 assets) {
        assets = _claimableDepositAssets[controller];
        uint256 pending = _pendingDepositRequest[controller];
        if (pending > 0 && isEpochSettled(_depositRequestEpoch[controller])) {
            assets += pending;
        }
    }

    /// @dev Read-only: claimable deposit shares, including unsettled pending that has become claimable.
    function _effectiveClaimableDepositShares(address controller) internal view returns (uint256 shares) {
        shares = _claimableDepositShares[controller];
        uint256 pending = _pendingDepositRequest[controller];

        uint256 depositRequestEpoch = _depositRequestEpoch[controller];

        if (pending > 0 && isEpochSettled(depositRequestEpoch)) {
            uint256 epochRate = _epochRate[depositRequestEpoch];
            shares += pending.mulDiv(1e18, epochRate);
        }
    }

    /// @dev Read-only: claimable redeem shares, including unsettled pending that has become claimable.
    function _effectiveClaimableRedeemShares(address controller) internal view returns (uint256 shares) {
        shares = _claimableRedeemShares[controller];
        uint256 pending = _pendingRedeemRequest[controller];
        if (pending > 0 && isEpochSettled(_redeemRequestEpoch[controller])) {
            shares += pending;
        }
    }

    /// @dev Read-only: claimable redeem assets, including unsettled pending that has become claimable.
    function _effectiveClaimableRedeemAssets(address controller) internal view returns (uint256 assets) {
        assets = _claimableRedeemAssets[controller];
        uint256 pending = _pendingRedeemRequest[controller];

        uint256 redeemRequestEpoch = _redeemRequestEpoch[controller];

        if (pending > 0 && isEpochSettled(redeemRequestEpoch)) {
            uint256 epochRate = _epochRate[redeemRequestEpoch];
            assets += pending.mulDiv(epochRate, 1e18);
        }
    }

    //      __  ___          ___ _____
    //     /  |/  /___  ____/ (_) __(_)__  __________
    //    / /|_/ / __ \/ __  / / /_/ / _ \/ ___/ ___/
    //   / /  / / /_/ / /_/ / / __/ /  __/ /  (__  )
    //  /_/  /_/\____/\__,_/_/_/ /_/\___/_/  /____/

    modifier onlyFundManager() {
        if (msg.sender != address(fundManager)) revert INVALID_CALLER();
        _;
    }

}
