// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IFundManager } from "./interfaces/IFundManager.sol";

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

    uint256 internal constant REQUEST_ID = 0;

    /// FIXME : remove this as its probably not needed
    address public immutable DEPLOYER;

    //     _____ __        __
    //    / ___// /_____ _/ /____  _____
    //    \__ \/ __/ __ `/ __/ _ \/ ___/
    //   ___/ / /_/ /_/ / /_/  __(__  )
    //  /____/\__/\__,_/\__/\___/____/

    mapping(address controller => mapping(address operator => bool)) private _isOperator;

    mapping(address controller => ControllerState state) private _controllerStates;

    /// @dev Exchange rate snapshot per settled epoch (assetsPerShare, scaled by 1e18)
    mapping(uint256 epoch => uint256 assetsPerShare) private _epochRate;
    mapping(uint256 epoch => bool isSettled) private _epochSettled;

    /// @dev Cache of the last settled epoch total assets
    uint256 private _lastReportedTotalAssets;

    /// @dev Total shares owed to settled depositors who haven't claimed yet.
    uint256 private _unclaimedDepositShares;

    /// @dev Total shares held by the vault for settled redeemers who haven't claimed yet.
    uint256 private _unclaimedRedeemShares;

    Snapshot private _snapshot;
    IERC20 public underlyingAsset;
    IFundManager public fundManager;

    uint256 public currentEpoch;
    uint256 public totalPendingDepositAssets;
    uint256 public totalPendingRedeemShares;

    /// @notice Asset balance the vault holds as earmark for settled-but-unclaimed redeems.
    ///         Invariant: `underlyingAsset.balanceOf(vault) == totalPendingDepositAssets + totalClaimableRedeemAssets`.
    uint256 public totalClaimableRedeemAssets;

    //     ______                 __                  __
    //    / ____/___  ____  _____/ /________  _______/ /_____  _____
    //   / /   / __ \/ __ \/ ___/ __/ ___/ / / / ___/ __/ __ \/ ___/
    //  / /___/ /_/ / / / (__  ) /_/ /  / /_/ / /__/ /_/ /_/ / /
    //  \____/\____/_/ /_/____/\__/_/   \__,_/\___/\__/\____/_/

    /**
     * @notice Initializes the vault with the underlying asset and share token metadata.
     * @dev    The FundManager address must be wired via `setFundManager` after deployment.
     *         This breaks the construction cycle between Vault and FundManager (FM needs Vault).
     * @param _underlyingAsset The address of the underlying ERC-20 asset.
     * @param name The name of the share token.
     * @param symbol The symbol of the share token.
     */
    constructor(IERC20 _underlyingAsset, string memory name, string memory symbol) ERC20(name, symbol) {
        underlyingAsset = _underlyingAsset;
        DEPLOYER = msg.sender;

        // Initialize the first epoch to 1
        currentEpoch = 1;
    }

    /**
     * @notice One-shot setter wiring the FundManager address after deployment. Callable once by DEPLOYER.
     * @param _fundManager Address of the deployed FundManager.
     */
    function setFundManager(address _fundManager) external {
        if (msg.sender != DEPLOYER) revert INVALID_CALLER();
        if (address(fundManager) != address(0)) revert ALREADY_SET();
        fundManager = IFundManager(_fundManager);
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

        // Lazy-settle any pending deposit from a previous settled epoch
        _settleDepositIfNeeded(controller);

        // Pending deposits are custodied by the vault itself until settlement.
        underlyingAsset.safeTransferFrom(owner, address(this), assets);

        ControllerState storage cs = _controllerStates[controller];

        // Accrue the assets deposited by this controller
        cs.pendingDepositAssets += assets;
        totalPendingDepositAssets += assets;

        // Record the epoch of this deposit request
        cs.depositRequestEpoch = currentEpoch;

        requestId = REQUEST_ID;

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

        // Lazy-settle any pending redeem from a previous epoch
        _settleRedeemIfNeeded(controller);

        // Snapshot the owner's share balance to compute the proportional unit decrement.
        uint256 totalSharesOwned = balanceOf(owner);
        if (shares > totalSharesOwned) revert INVALID_PARAMETERS();

        // Inform FM to decrement units and recalibrate the GDA flow.
        fundManager.onRequestRedeem(controller, shares, totalSharesOwned);

        // Transfer the shares from the owner to this contract
        _transfer(owner, address(this), shares);

        ControllerState storage cs = _controllerStates[controller];

        // Accrue the shares pending to be redeemed by this controller
        cs.pendingRedeemShares += shares;
        totalPendingRedeemShares += shares;

        // Record the epoch of this redeem request
        cs.redeemRequestEpoch = currentEpoch;

        requestId = REQUEST_ID;

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

        // Earmark the redeemable assets against vault balance. Deposits and claimable redeems
        // coexist in the vault's underlying balance; this counter partitions the two.
        totalClaimableRedeemAssets += redeemingAssets;

        if (_snapshot.depositingAssets >= redeemingAssets) {
            // Deposits cover redeems; push the surplus to the FundManager for investment.
            uint256 surplus = _snapshot.depositingAssets - redeemingAssets;
            if (surplus > 0) {
                underlyingAsset.safeTransfer(address(fundManager), surplus);
            }
        } else {
            // Deposits fall short; pull the deficit from the FundManager to cover redeems.
            // FM downgrades its super-token and transfers underlying into this vault.
            uint256 deficit = redeemingAssets - _snapshot.depositingAssets;
            fundManager.move(address(this), deficit);
        }

        // Track unclaimed positions for effective supply adjustment in future closeEpoch calls
        _unclaimedDepositShares += _snapshot.depositingAssets.mulDiv(1e18, _snapshot.rate);
        _unclaimedRedeemShares += _snapshot.redeemingShares;

        // Commit the epoch rate for the settled epoch
        _epochRate[settlingEpoch] = _snapshot.rate;
        _epochSettled[settlingEpoch] = true;

        /// FIXME : verify below formula (should this account for unclaimed redeeming/depositing shares?)
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

    /// @inheritdoc IERC20
    /// @dev Overrides the ERC20 implementation to disable share transfers, making shares non-transferable by design
    function transfer(address, uint256) public pure override(ERC20, IERC20) returns (bool) {
        revert SHARES_NON_TRANSFERABLE();
    }

    /// @inheritdoc IERC20
    /// @dev Overrides the ERC20 implementation to disable share transfers, making shares non-transferable by design
    function transferFrom(address, address, uint256) public pure override(ERC20, IERC20) returns (bool) {
        revert SHARES_NON_TRANSFERABLE();
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
        ControllerState memory cs = _controllerStates[controller];
        // If the epoch has been settled, the deposit is claimable and not pending
        assets = isEpochSettled(cs.depositRequestEpoch) ? 0 : cs.pendingDepositAssets;
    }

    /// @inheritdoc IERC7540Redeem
    function pendingRedeemRequest(uint256, address controller) external view returns (uint256 shares) {
        ControllerState memory cs = _controllerStates[controller];

        // If the epoch has been settled, the redeem is claimable and not pending
        shares = isEpochSettled(cs.redeemRequestEpoch) ? 0 : cs.pendingRedeemShares;
    }

    /// @inheritdoc IERC7540Deposit
    function claimableDepositRequest(uint256, address controller) external view returns (uint256 assets) {
        assets = _effectiveClaimableDepositAssets(controller);
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
        return interfaceId == type(IERC7540Operator).interfaceId || interfaceId == type(IERC7575).interfaceId
            || interfaceId == type(IERC7540Deposit).interfaceId || interfaceId == type(IERC7540Redeem).interfaceId;
    }

    //      ____      __                        __   ______                 __  _
    //     /  _/___  / /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //     / // __ \/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   _/ // / / / /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /___/_/ /_/\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    function _deposit(uint256 assets, address receiver, address controller) internal returns (uint256 shares) {
        if (assets == 0) revert INVALID_PARAMETERS();
        (uint256 claimableAssets, uint256 claimableShares) = _resolveClaimableDeposit(controller);
        shares = assets.mulDiv(claimableShares, claimableAssets);
        if (shares == 0) revert INVALID_PARAMETERS();
        _claimDeposit(assets, shares, receiver, controller);
    }

    function _mintShares(uint256 shares, address receiver, address controller) internal returns (uint256 assets) {
        if (shares == 0) revert INVALID_PARAMETERS();
        (uint256 claimableAssets, uint256 claimableShares) = _resolveClaimableDeposit(controller);
        assets = shares.mulDiv(claimableAssets, claimableShares, Math.Rounding.Ceil);
        _claimDeposit(assets, shares, receiver, controller);
    }

    function _redeem(uint256 shares, address receiver, address controller) internal returns (uint256 assets) {
        if (shares == 0) revert INVALID_PARAMETERS();
        (uint256 claimableAssets, uint256 claimableShares) = _resolveClaimableRedeem(controller);
        assets = shares.mulDiv(claimableAssets, claimableShares);
        if (assets == 0) revert INVALID_PARAMETERS();
        _claimRedeem(assets, shares, receiver, controller);
    }

    function _withdraw(uint256 assets, address receiver, address controller) internal returns (uint256 shares) {
        if (assets == 0) revert INVALID_PARAMETERS();
        (uint256 claimableAssets, uint256 claimableShares) = _resolveClaimableRedeem(controller);
        // Round up so at least 1 share is burned per non-zero withdrawal (favors vault)
        shares = assets.mulDiv(claimableShares, claimableAssets, Math.Rounding.Ceil);
        _claimRedeem(assets, shares, receiver, controller);
    }

    /// @dev Lazy-settles any pending deposit and returns the controller's claimable deposit balances.
    function _resolveClaimableDeposit(address controller)
        internal
        returns (uint256 claimableAssets, uint256 claimableShares)
    {
        _settleDepositIfNeeded(controller);
        ControllerState storage cs = _controllerStates[controller];
        claimableAssets = cs.claimableDepositAssets;
        if (claimableAssets == 0) revert NOTHING_TO_CLAIM();
        claimableShares = cs.claimableDepositShares;
    }

    /// @dev Lazy-settles any pending redeem and returns the controller's claimable redeem balances.
    function _resolveClaimableRedeem(address controller)
        internal
        returns (uint256 claimableAssets, uint256 claimableShares)
    {
        _settleRedeemIfNeeded(controller);
        ControllerState storage cs = _controllerStates[controller];
        claimableAssets = cs.claimableRedeemAssets;
        if (claimableAssets == 0) revert NOTHING_TO_CLAIM();
        claimableShares = cs.claimableRedeemShares;
    }

    /// @dev Executes a deposit claim: deducts from claimable, mints shares, notifies FM.
    function _claimDeposit(uint256 assets, uint256 shares, address receiver, address controller) internal {
        ControllerState storage cs = _controllerStates[controller];
        cs.claimableDepositAssets -= assets;
        cs.claimableDepositShares -= shares;
        _unclaimedDepositShares -= shares;
        _mint(receiver, shares);
        fundManager.onClaimDeposit(receiver, assets);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @dev Executes a redeem claim: deducts from claimable, burns shares, transfers assets.
    function _claimRedeem(uint256 assets, uint256 shares, address receiver, address controller) internal {
        ControllerState storage cs = _controllerStates[controller];
        cs.claimableRedeemShares -= shares;
        cs.claimableRedeemAssets -= assets;
        _unclaimedRedeemShares -= shares;
        totalClaimableRedeemAssets -= assets;
        _burn(address(this), shares);
        underlyingAsset.safeTransfer(receiver, assets);
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
        ControllerState storage cs = _controllerStates[controller];

        // If the controller has no pending assets deposited, return
        uint256 pendingAssets = cs.pendingDepositAssets;
        if (pendingAssets == 0) return;

        // If the epoch is not yet settled, return
        uint256 depositRequestEpoch = cs.depositRequestEpoch;
        if (!isEpochSettled(depositRequestEpoch)) return;

        // Calculate the shares to be claimed using the epoch's settlement rate
        uint256 epochRate = _epochRate[depositRequestEpoch];
        uint256 pendingShares = pendingAssets.mulDiv(1e18, epochRate);

        // Update the controller's claimable and pending amounts
        cs.claimableDepositAssets += pendingAssets;
        cs.claimableDepositShares += pendingShares;
        cs.pendingDepositAssets = 0;
    }

    /// @dev If the controller has a pending redeem from a settled (past) epoch,
    ///      convert pending shares → claimable (both shares and assets) at the epoch's settlement rate.
    function _settleRedeemIfNeeded(address controller) internal {
        ControllerState storage cs = _controllerStates[controller];

        // If the controller has no pending redeeming shares, return
        uint256 pendingShares = cs.pendingRedeemShares;
        if (pendingShares == 0) return;

        // If the epoch is not yet settled, return
        uint256 redeemRequestEpoch = cs.redeemRequestEpoch;
        if (!isEpochSettled(redeemRequestEpoch)) return;

        // Calculate the assets to be claimed using the epoch's settlement rate
        uint256 epochRate = _epochRate[redeemRequestEpoch];
        uint256 pendingAssets = pendingShares.mulDiv(epochRate, 1e18);

        // Update the controller's claimable and pending amounts
        cs.claimableRedeemShares += pendingShares;
        cs.claimableRedeemAssets += pendingAssets;
        cs.pendingRedeemShares = 0;
    }

    function _effectiveClaimableDepositAssets(address controller) internal view returns (uint256 assets) {
        ControllerState memory cs = _controllerStates[controller];

        // Accumulate the assets already claimable
        assets = cs.claimableDepositAssets;

        // Accumulate the pending assets if the request epoch has been settled (i.e. they are now claimable)
        uint256 pending = cs.pendingDepositAssets;
        if (pending > 0 && isEpochSettled(cs.depositRequestEpoch)) {
            assets += pending;
        }
    }

    function _effectiveClaimableDepositShares(address controller) internal view returns (uint256 shares) {
        ControllerState memory cs = _controllerStates[controller];

        // Accumulate the shares already claimable
        shares = cs.claimableDepositShares;

        uint256 pending = cs.pendingDepositAssets;
        uint256 depositRequestEpoch = cs.depositRequestEpoch;

        // Accumulate the converted pending assets if the request epoch has been settled (i.e. they are now claimable)
        if (pending > 0 && isEpochSettled(depositRequestEpoch)) {
            uint256 epochRate = _epochRate[depositRequestEpoch];
            shares += pending.mulDiv(1e18, epochRate);
        }
    }

    function _effectiveClaimableRedeemShares(address controller) internal view returns (uint256 shares) {
        ControllerState memory cs = _controllerStates[controller];

        // Accumulate the shares already claimable
        shares = cs.claimableRedeemShares;

        // Accumulate the pending shares if the request epoch has been settled (i.e. they are now claimable)
        uint256 pending = cs.pendingRedeemShares;
        if (pending > 0 && isEpochSettled(cs.redeemRequestEpoch)) {
            shares += pending;
        }
    }

    function _effectiveClaimableRedeemAssets(address controller) internal view returns (uint256 assets) {
        ControllerState memory cs = _controllerStates[controller];

        // Accumulate the assets already claimable
        assets = cs.claimableRedeemAssets;

        uint256 pending = cs.pendingRedeemShares;
        uint256 redeemRequestEpoch = cs.redeemRequestEpoch;

        // Accumulate the converted pending assets if the request epoch has been settled (i.e. they are now claimable)
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
