// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IFundManagerBase } from "src/interfaces/common/IFundManagerBase.sol";

import { AccessControl } from "@openzeppelin-v5/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin-v5/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin-v5/contracts/utils/ReentrancyGuard.sol";
import {
    PoolConfig,
    SuperTokenV1Library
} from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";

/**
 * @title FundManagerBase
 * @notice Shared Superfluid GDA streaming engine for every FundManager variant. Holds the
 *         super-token reserve, the yield/fee GDA pools, the operator-committed stable rate, and
 *         the forward-solvency rebalancing logic. Concrete managers (async epoch-based, sync
 *         ERC-4626) extend this with their vault-specific deposit/withdraw/settlement hooks.
 * @dev    Extracted verbatim from `AsyncFundManager`; behaviour is unchanged. The vault is pinned
 *         at construction via `msg.sender` (no factory/proxy); read the concrete vault first.
 */
abstract contract FundManagerBase is IFundManagerBase, AccessControl, ReentrancyGuard {

    using Math for uint256;
    using SafeERC20 for IERC20;
    using SuperTokenV1Library for ISuperToken;

    //      ____                          __        __    __        _____ __        __
    //     /  _/___ ___  ____ ___  __  __/ /_____ _/ /_  / /__     / ___// /_____ _/ /____  _____
    //     / // __ `__ \/ __ `__ \/ / / / __/ __ `/ __ \/ / _ \    \__ \/ __/ __ `/ __/ _ \/ ___/
    //   _/ // / / / / / / / / / / /_/ / /_/ /_/ / /_/ / /  __/   ___/ / /_/ /_/ / /_/  __(__  )
    //  /___/_/ /_/ /_/_/ /_/ /_/\__,_/\__/\__,_/_.___/_/\___/   /____/\__/\__,_/\__/\___/____/

    /// @notice Role identifier for fund operators
    bytes32 public constant FUND_OPERATOR_ROLE = keccak256("FUND_OPERATOR_ROLE");

    /// @notice Role identifier for the vault contract
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    /// @notice Seconds in a year (365 * 24 * 3600)
    uint256 public constant YEAR = 365 days;

    // /// @notice Basis Point denominator for annualized stable yield rate calculations (e.g. 10_000 = 100%)
    uint256 internal constant _BP_DENOMINATOR = 10_000;

    /// @notice Sanity floor for `guaranteedFlowDuration` to prevent operator-error zeroing-out the buffer
    uint256 public constant MIN_GUARANTEED_FLOW_DURATION = 1 days;

    /// @notice Underlying asset (e.g. USDC)
    IERC20 public immutable UNDERLYING_ASSET;

    /// @notice Wrapped super-token of the underlying asset (e.g. USDCx)
    ISuperToken public immutable YIELD_ASSET;

    /// @notice Reference to the paired vault contract (the share token), pinned at construction
    IERC20 public immutable VAULT;

    /// @notice GDA pool distributing the yield stream to shareholders
    ISuperfluidPool public immutable YIELD_POOL;

    /// @notice GDA pool distributing the fee stream to the treasury
    ISuperfluidPool public immutable FEE_POOL;

    /// @notice Treasury address collecting the fees
    address public immutable TREASURY;

    /// @notice Scale factor lifting underlying amounts into super-token (18-dec) amounts.
    ///         = 10 ** (18 - underlyingDecimals). For USDC (6-dec) == 10**12.
    uint256 public immutable SCALING_FACTOR;

    /// @notice Raw underlying atoms per pool unit. = 10 ** (underlyingDecimals - 6).
    ///         Pool units are denominated in micro-tokens regardless of underlying decimals,
    ///         so 1 whole token always corresponds to 1e6 pool units.
    ///         For USDC (6-dec) == 1; for DAI (18-dec) == 1e12.
    uint256 public immutable RAW_PER_UNIT;

    /// @notice Fee units percentage (expressed in basis points)
    uint256 public constant FEE_BPS = 100; // 1% fee in units (100 bps)

    /// @notice The asset per share exchange rate scale
    uint256 public constant ASSETS_PER_SHARE_SCALE = 1e18;

    //     _____ __        __
    //    / ___// /_____ _/ /____  _____
    //    \__ \/ __/ __ `/ __/ _ \/ ___/
    //   ___/ / /_/ /_/ / /_/  __(__  )
    //  /____/\__/\__,_/\__/\___/____/

    /// @inheritdoc IFundManagerBase
    uint256 public stableYieldRate;

    int96 internal _flowRatePerUnit;

    /// @inheritdoc IFundManagerBase
    uint256 public guaranteedFlowDuration;

    //     ______                 __                  __
    //    / ____/___  ____  _____/ /________  _______/ /_____  _____
    //   / /   / __ \/ __ \/ ___/ __/ ___/ / / / ___/ __/ __ \/ ___/
    //  / /___/ /_/ / / / (__  ) /_/ /  / /_/ / /__/ /_/ /_/ / /
    //  \____/\____/_/ /_/____/\__/_/   \__,_/\___/\__/\____/_/

    /**
     * @notice FundManager base constructor
     * @param _treasury Treasury address collecting the fees
     * @param _asset Underlying asset (e.g. USDC) address
     * @param _yieldAsset Yield asset shall be a wrapped super-token of the underlying asset
     * @param _fundOperator Operator granted with the FUND_OPERATOR_ROLE
     * @param _fundAdmin Admin granted with the DEFAULT_ADMIN_ROLE
     * @param _initialStableYieldRate Initial era stable yield rate (in basis points, e.g. 100% <=> 1)
     * @param _initialGuaranteedFlowDuration Initial forward-solvency horizon in seconds
     */
    constructor(
        address _treasury,
        address _asset,
        address _yieldAsset,
        address _fundOperator,
        address _fundAdmin,
        uint256 _initialStableYieldRate,
        uint256 _initialGuaranteedFlowDuration
    ) {
        if (_treasury == address(0)) revert ZERO_ADDRESS();
        if (_initialStableYieldRate * _initialGuaranteedFlowDuration > YEAR * _BP_DENOMINATOR) {
            revert INVALID_YIELD_DURATION_COMBINATION();
        }

        UNDERLYING_ASSET = IERC20(_asset);
        VAULT = IERC20(msg.sender);
        TREASURY = _treasury;

        // Grant underlying asset unlimited approval to the vault
        UNDERLYING_ASSET.forceApprove(msg.sender, type(uint256).max);

        // Verify super-token wraps the correct underlying
        if (ISuperToken(_yieldAsset).getUnderlyingToken() != _asset) revert ASSET_MISMATCH();
        YIELD_ASSET = ISuperToken(_yieldAsset);

        // Calculate scaling factors. Underlying decimals must be in [6, 18]:
        //   - upper bound: 18-dec super-token cannot represent fractional sub-atoms.
        //   - lower bound: keeping the units conversion as a divisor (raw → units) requires d ≥ 6.
        uint8 underlyingDecimals = ISuperToken(_yieldAsset).getUnderlyingDecimals();
        if (underlyingDecimals < 6 || underlyingDecimals > 18) revert UNSUPPORTED_DECIMALS();
        SCALING_FACTOR = 10 ** (18 - underlyingDecimals);
        RAW_PER_UNIT = 10 ** (underlyingDecimals - 6);

        // Grant access control permissions
        _grantRole(FUND_OPERATOR_ROLE, _fundOperator);
        _grantRole(DEFAULT_ADMIN_ROLE, _fundAdmin);
        _grantRole(VAULT_ROLE, msg.sender);

        // Pool Configuration : units are non-transferable; any-sender distribution not allowed
        PoolConfig memory poolConfig =
            PoolConfig({ transferabilityForUnitsOwner: false, distributionFromAnyAddress: false });

        // Create the yield pool with FM as pool admin
        YIELD_POOL = YIELD_ASSET.createPool(address(this), poolConfig);

        // Create the fee pool with FM as pool admin
        FEE_POOL = YIELD_ASSET.createPool(address(this), poolConfig);

        // Grant 1 unit to the treasury
        FEE_POOL.increaseMemberUnits(TREASURY, 1);

        // Connect FM to the pool
        YIELD_ASSET.connectPool(YIELD_POOL);

        stableYieldRate = _initialStableYieldRate;

        // Decimals-independent: SCALING_FACTOR · RAW_PER_UNIT = 10^(18-d) · 10^(d-6) = 10^12.
        _flowRatePerUnit = int96(int256(1e12 * _initialStableYieldRate / (YEAR * _BP_DENOMINATOR)));

        if (_initialGuaranteedFlowDuration < MIN_GUARANTEED_FLOW_DURATION) revert DURATION_BELOW_FLOOR();
        guaranteedFlowDuration = _initialGuaranteedFlowDuration;
    }

    //      ______     __                        __   ______                 __  _
    //     / ____/  __/ /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //    / __/ | |/_/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / /____>  </ /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /_____/_/|_|\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @inheritdoc IFundManagerBase
    function ensureYieldFlowDuration() external onlyRole(FUND_OPERATOR_ROLE) nonReentrant {
        // Rebalance underlying vs. yield assets
        _rebalanceYieldAssets();

        // Check if the yield flow needs to be restarted
        if (YIELD_POOL.getTotalFlowRate() == 0 && YIELD_POOL.getTotalUnits() > 0) {
            // Restart the distribution flow if necessary
            _recalibrateFlow();
        }
    }

    /// @inheritdoc IFundManagerBase
    function setStableYieldRate(uint256 newRate) external onlyRole(FUND_OPERATOR_ROLE) nonReentrant {
        // Ensure the new rate and the current guaranteed flow duration are a valid combination
        if (newRate * guaranteedFlowDuration > YEAR * _BP_DENOMINATOR) {
            revert INVALID_YIELD_DURATION_COMBINATION();
        }

        uint256 oldRate = stableYieldRate;
        stableYieldRate = newRate;

        // Recalculate flow rate based on the new annualized era stable yield rate.
        // Decimals-independent: SCALING_FACTOR · RAW_PER_UNIT = 10^12.
        _flowRatePerUnit = int96(int256(1e12 * newRate / (YEAR * _BP_DENOMINATOR)));

        _rebalanceYieldAssets();
        _recalibrateFlow();

        emit StableYieldRateChanged(oldRate, newRate);
    }

    /// @inheritdoc IFundManagerBase
    function setGuaranteedFlowDuration(uint256 newDuration) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (newDuration < MIN_GUARANTEED_FLOW_DURATION) revert DURATION_BELOW_FLOOR();

        // Ensure the new rate and the current guaranteed flow duration are a valid combination
        if (newDuration * stableYieldRate > YEAR * _BP_DENOMINATOR) {
            revert INVALID_YIELD_DURATION_COMBINATION();
        }

        uint256 oldDuration = guaranteedFlowDuration;

        // Update the guaranteed flow duration
        guaranteedFlowDuration = newDuration;

        // Rebalance the yield assets reserve to match new duration
        // Either downgrade yield assets if the duration is decreased
        // or upgrade underlying assets if the duration is increased
        _rebalanceYieldAssets();

        emit GuaranteedFlowDurationChanged(oldDuration, newDuration);
    }

    /// @inheritdoc IFundManagerBase
    function emergencyWithdraw(address token, uint256 amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(token, msg.sender, amount);
    }

    //    _    __             ____     ______      __           __
    //   | |  / /___ ___  __/ / /_   / ____/___ _/ /____  ____/ /
    //   | | / / __ `/ / / / / __/  / / __/ __ `/ __/ _ \/ __  /
    //   | |/ / /_/ / /_/ / / /_   / /_/ / /_/ / /_/  __/ /_/ /
    //   |___/\__,_/\__,_/_/\__/   \____/\__,_/\__/\___/\__,_/

    /// @inheritdoc IFundManagerBase
    function onShareTransfer(address sender, address receiver, uint256 shares)
        external
        onlyRole(VAULT_ROLE)
        nonReentrant
    {
        uint128 senderUnits = YIELD_POOL.getUnits(sender);
        // A dust position can hold shares but zero units due to the units/shares conversion rounding
        if (senderUnits == 0) return;

        uint128 delta = uint128(uint256(senderUnits).mulDiv(shares, VAULT.balanceOf(sender), Math.Rounding.Ceil));

        YIELD_POOL.increaseMemberUnits(receiver, delta);
        YIELD_POOL.decreaseMemberUnits(sender, delta);
    }

    //   _    ___                 ______                 __  _
    //  | |  / (_)__ _      __   / ____/_  ______  _____/ /_(_)___  ____  _____
    //  | | / / / _ \ | /| / /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //  | |/ / /  __/ |/ |/ /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  |___/_/\___/|__/|__/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @inheritdoc IFundManagerBase
    function yieldAssetsBalance() public view returns (uint256 balance) {
        balance = YIELD_ASSET.balanceOf(address(this));
    }

    /// @inheritdoc IFundManagerBase
    function scaledYieldAssetsBalance() public view returns (uint256 balance) {
        balance = yieldAssetsBalance() / SCALING_FACTOR;
    }

    /// @inheritdoc IFundManagerBase
    function evaluateYieldAssetsDeficit() public view returns (int256 deficit) {
        int96 targetYieldFlowRate = _targetFlowRate();
        int96 targetFeeFlowRate = targetYieldFlowRate * int96(int256(FEE_BPS)) / int96(int256(_BP_DENOMINATOR));

        uint256 requiredBalance = uint256(uint96(targetYieldFlowRate + targetFeeFlowRate)) * guaranteedFlowDuration;
        uint256 actualBalance = yieldAssetsBalance();

        deficit = int256(requiredBalance) - int256(actualBalance);
    }

    //      ____      __                        __   ______                 __  _
    //     /  _/___  / /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //     / // __ \/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   _/ // / / / /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /___/_/ /_/\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    function _upgrade(uint256 underlyingAmount) internal {
        UNDERLYING_ASSET.forceApprove(address(YIELD_ASSET), underlyingAmount);
        YIELD_ASSET.upgrade(underlyingAmount * SCALING_FACTOR);
    }

    function _downgrade(uint256 superTokenAmount) internal {
        YIELD_ASSET.downgrade(superTokenAmount);
    }

    function _recalibrateFlow() internal {
        int96 targetYieldFlowRate = _targetFlowRate();
        YIELD_ASSET.distributeFlow(YIELD_POOL, targetYieldFlowRate);

        int96 feeFlowRate = targetYieldFlowRate * int96(int256(FEE_BPS)) / int96(int256(_BP_DENOMINATOR));
        YIELD_ASSET.distributeFlow(FEE_POOL, feeFlowRate);
    }

    function _rebalanceYieldAssets() internal virtual;

    function _targetFlowRate() internal view returns (int96 flowRate) {
        flowRate = _flowRatePerUnit * int96(int128(YIELD_POOL.getTotalUnits()));
    }

    function _toUnit(uint256 underlyingAmount) internal view returns (uint128 units) {
        units = uint128(underlyingAmount / RAW_PER_UNIT);
    }

}
