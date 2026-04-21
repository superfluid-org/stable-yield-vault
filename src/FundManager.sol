// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IFundManager } from "./interfaces/IFundManager.sol";

import { AccessControl } from "@openzeppelin-v5/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin-v5/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin-v5/contracts/utils/ReentrancyGuard.sol";
import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";

import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";
import { IStableYieldAsyncVault } from "src/interfaces/vault/IStableYieldAsyncVault.sol";

contract FundManager is IFundManager, AccessControl, ReentrancyGuard {

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

    /// @notice WAD scale used for `annualRate` (1e18 == 100% APR)
    uint256 public constant WAD = 1e18;

    /// @notice Sanity floor for `guaranteedFlowDuration` to prevent operator-error zeroing-out the buffer
    uint256 public constant MIN_GUARANTEED_FLOW_DURATION = 1 days;

    /// @notice Reference to the StableYieldAsyncVault contract
    IStableYieldAsyncVault public immutable VAULT;

    /// @notice Underlying asset (e.g. USDC)
    IERC20 public immutable ASSET;

    /// @notice Wrapped super-token of the underlying asset (e.g. USDCx)
    ISuperToken public immutable SUPER_TOKEN;

    /// @notice GDA pool distributing the yield stream to shareholders
    ISuperfluidPool public immutable POOL;

    /// @notice Scale factor lifting underlying amounts into super-token (18-dec) amounts.
    ///         = 10 ** (18 - underlyingDecimals). For USDC (6-dec) == 10**12.
    uint256 public immutable SUPER_TOKEN_SCALE;

    //     _____ __        __
    //    / ___// /_____ _/ /____  _____
    //    \__ \/ __/ __ `/ __/ _ \/ ___/
    //   ___/ / /_/ /_/ / /_/  __(__  )
    //  /____/\__/\__,_/\__/\___/____/

    /// @inheritdoc IFundManager
    uint256 public annualRate;

    /// @inheritdoc IFundManager
    uint256 public guaranteedFlowDuration;

    //     ______                 __                  __
    //    / ____/___  ____  _____/ /________  _______/ /_____  _____
    //   / /   / __ \/ __ \/ ___/ __/ ___/ / / / ___/ __/ __ \/ ___/
    //  / /___/ /_/ / / / (__  ) /_/ /  / /_/ / /__/ /_/ /_/ / /
    //  \____/\____/_/ /_/____/\__/_/   \__,_/\___/\__/\____/_/

    /**
     * @notice Constructor for the FundManager contract
     * @param _vault                         StableYieldAsyncVault contract
     * @param _superToken                    Wrapped super-token of the vault's underlying asset
     * @param _admin                         Default admin (role manager)
     * @param _fundOperator                  Operator granted FUND_OPERATOR_ROLE
     * @param _initialAnnualRate             Initial annualRate in WAD (5% == 5e16)
     * @param _initialGuaranteedFlowDuration Initial forward-solvency horizon in seconds
     */
    constructor(
        IStableYieldAsyncVault _vault,
        ISuperToken _superToken,
        address _admin,
        address _fundOperator,
        uint256 _initialAnnualRate,
        uint256 _initialGuaranteedFlowDuration
    ) {
        VAULT = _vault;
        ASSET = IERC20(_vault.asset());

        // Verify super-token wraps the correct underlying
        if (_superToken.getUnderlyingToken() != address(ASSET)) revert NOT_INITIALIZED();
        SUPER_TOKEN = _superToken;

        uint8 underlyingDecimals = _superToken.getUnderlyingDecimals();
        SUPER_TOKEN_SCALE = 10 ** (18 - underlyingDecimals);

        if (_initialGuaranteedFlowDuration < MIN_GUARANTEED_FLOW_DURATION) revert DURATION_BELOW_FLOOR();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FUND_OPERATOR_ROLE, _fundOperator);
        _grantRole(VAULT_ROLE, address(_vault));

        // Create the pool with FM as admin (units are non-transferable by default; any-sender distribution allowed)
        POOL = SUPER_TOKEN.createPool(address(this));

        // Connect FM to the pool
        SUPER_TOKEN.connectPool(POOL);

        annualRate = _initialAnnualRate;
        guaranteedFlowDuration = _initialGuaranteedFlowDuration;
    }

    //      ______     __                        __   ______                 __  _
    //     / ____/  __/ /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //    / __/ | |/_/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / /____>  </ /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /_____/_/|_|\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @inheritdoc IFundManager
    function closeEpoch(uint256 workingAssets) external onlyRole(FUND_OPERATOR_ROLE) {
        // totalFundAssets is reported in underlying decimals
        uint256 totalFundAssets = workingAssets + unutilizedAssetsBalance();
        VAULT.closeEpoch(totalFundAssets);
    }

    /// @inheritdoc IFundManager
    function settleEpoch() external onlyRole(FUND_OPERATOR_ROLE) nonReentrant {
        // Snapshot must be read BEFORE the vault deletes it during settleEpoch
        IStableYieldAsyncVault.Snapshot memory snap = VAULT.getSnapshot();

        // Track underlying balance changes across the settlement call
        uint256 preUnderlying = ASSET.balanceOf(address(this));

        // Drives the vault's settlement; may call back into `FundManager.move` if redeem > deposit
        VAULT.settleEpoch();

        // Wrap any underlying that arrived (net-inflow epoch surplus)
        uint256 postUnderlying = ASSET.balanceOf(address(this));
        if (postUnderlying > preUnderlying) {
            uint256 arrived = postUnderlying - preUnderlying;
            ASSET.forceApprove(address(SUPER_TOKEN), arrived);
            SUPER_TOKEN.upgrade(arrived * SUPER_TOKEN_SCALE);
        }

        // Grant FM units for this epoch's depositors (asset-basis, scaled into super-token decimals)
        if (snap.depositingAssets > 0) {
            uint128 currentFMUnits = POOL.getUnits(address(this));
            uint128 delta = _toU128(snap.depositingAssets * SUPER_TOKEN_SCALE);
            uint128 newFMUnits = _add128(currentFMUnits, delta);
            POOL.updateMemberUnits(address(this), newFMUnits);
            _recalibrateFlow();
        }

        _assertInvariant();
    }

    /// @inheritdoc IFundManager
    function give(uint256 amount) external onlyRole(FUND_OPERATOR_ROLE) nonReentrant {
        ASSET.safeTransferFrom(msg.sender, address(this), amount);
        ASSET.forceApprove(address(SUPER_TOKEN), amount);
        SUPER_TOKEN.upgrade(amount * SUPER_TOKEN_SCALE);
        emit Gave(msg.sender, amount);
    }

    /// @inheritdoc IFundManager
    function take(uint256 amount) external onlyRole(FUND_OPERATOR_ROLE) nonReentrant {
        SUPER_TOKEN.downgrade(amount * SUPER_TOKEN_SCALE);
        ASSET.safeTransfer(msg.sender, amount);
        _assertInvariant();
        emit Took(msg.sender, amount);
    }

    /// @inheritdoc IFundManager
    function setAnnualRate(uint256 newRate) external onlyRole(FUND_OPERATOR_ROLE) nonReentrant {
        uint256 oldRate = annualRate;
        annualRate = newRate;
        _recalibrateFlow();
        _assertInvariant();
        emit AnnualRateChanged(oldRate, newRate);
    }

    /// @inheritdoc IFundManager
    function setGuaranteedFlowDuration(uint256 newDuration) external onlyRole(FUND_OPERATOR_ROLE) nonReentrant {
        if (newDuration < MIN_GUARANTEED_FLOW_DURATION) revert DURATION_BELOW_FLOOR();
        uint256 oldDuration = guaranteedFlowDuration;
        guaranteedFlowDuration = newDuration;
        _assertInvariant();
        emit GuaranteedFlowDurationChanged(oldDuration, newDuration);
    }

    //    _    __             ____     ______      __           __
    //   | |  / /___ ___  __/ / /_   / ____/___ _/ /____  ____/ /
    //   | | / / __ `/ / / / / __/  / / __/ __ `/ __/ _ \/ __  /
    //   | |/ / /_/ / /_/ / / /_   / /_/ / /_/ / /_/  __/ /_/ /
    //   |___/\__,_/\__,_/_/\__/   \____/\__,_/\__/\___/\__,_/

    /// @inheritdoc IFundManager
    function move(address recipient, uint256 amount) external onlyRole(VAULT_ROLE) {
        SUPER_TOKEN.downgrade(amount * SUPER_TOKEN_SCALE);
        ASSET.safeTransfer(recipient, amount);
        _assertInvariant();
    }

    /// @inheritdoc IFundManager
    function onClaimDeposit(address controller, uint256 depositAssets) external onlyRole(VAULT_ROLE) {
        if (depositAssets == 0) return;

        uint128 delta = _toU128(depositAssets * SUPER_TOKEN_SCALE);

        uint128 fmUnits = POOL.getUnits(address(this));
        if (fmUnits < delta) revert UNITS_UNDERFLOW();

        uint128 userUnits = POOL.getUnits(controller);
        POOL.updateMemberUnits(address(this), fmUnits - delta);
        POOL.updateMemberUnits(controller, _add128(userUnits, delta));

        emit UnitsTransferred(address(this), controller, delta);
        // pool.totalUnits unchanged; flowRate unchanged; invariant unchanged
    }

    /// @inheritdoc IFundManager
    function onRequestRedeem(address controller, uint256 sharesRedeemed, uint256 totalSharesOwned)
        external
        onlyRole(VAULT_ROLE)
    {
        if (totalSharesOwned == 0 || sharesRedeemed > totalSharesOwned) revert BAD_REDEEM_ARGS();

        uint128 userUnits = POOL.getUnits(controller);
        if (userUnits == 0) return;

        uint128 delta;
        if (sharesRedeemed == totalSharesOwned) {
            // Full exit: remove every unit explicitly to avoid rounding residue
            delta = userUnits;
        } else {
            delta = uint128((uint256(userUnits) * sharesRedeemed) / totalSharesOwned);
        }

        if (delta == 0) return;

        POOL.updateMemberUnits(controller, userUnits - delta);
        _recalibrateFlow();
        // flowRate decreases; invariant trivially safe
    }

    //   _    ___                 ______                 __  _
    //  | |  / (_)__ _      __   / ____/_  ______  _____/ /_(_)___  ____  _____
    //  | | / / / _ \ | /| / /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //  | |/ / /  __/ |/ |/ /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  |___/_/\___/|__/|__/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @inheritdoc IFundManager
    function unutilizedAssetsBalance() public view returns (uint256 balance) {
        (int256 avail,,,) = SUPER_TOKEN.realtimeBalanceOfNow(address(this));
        if (avail <= 0) return 0;
        // availableBalanceOf is in super-token decimals (18); convert to underlying decimals
        balance = uint256(avail) / SUPER_TOKEN_SCALE;
    }

    //      ____      __                        __   ______                 __  _
    //     /  _/___  / /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //     / // __ \/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   _/ // / / / /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /___/_/ /_/\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @dev Recalibrate the pool's distributeFlow to `totalUnits * annualRate / YEAR` (all in super-token wei).
    function _recalibrateFlow() internal {
        uint128 totalUnits = POOL.getTotalUnits();
        int96 targetRate = _toFlowRate(totalUnits, annualRate);
        SUPER_TOKEN.distributeFlow(POOL, targetRate);
        emit FlowRateRecalibrated(totalUnits, annualRate, targetRate);
    }

    /// @dev Compute flow rate (super-token wei/sec) from total units (super-token decimals) and annualRate (WAD).
    function _toFlowRate(uint128 totalUnits, uint256 rateWad) internal pure returns (int96) {
        if (totalUnits == 0 || rateWad == 0) return int96(0);
        // fr = totalUnits * rateWad / (YEAR * WAD). All in super-token wei/sec.
        uint256 fr = (uint256(totalUnits) * rateWad) / (YEAR * WAD);
        if (fr > uint256(uint96(type(int96).max))) revert FLOW_RATE_OVERFLOW();
        return int96(int256(fr));
    }

    /// @dev Assert the stream-solvency invariant: avail >= actualFlowRate * guaranteedFlowDuration.
    function _assertInvariant() internal view {
        (int256 avail,,,) = SUPER_TOKEN.realtimeBalanceOfNow(address(this));
        if (avail < 0) revert INVARIANT_VIOLATED();
        int96 rate = POOL.getTotalFlowRate();
        // rate is non-negative by construction (we only ever distribute to members at >=0 rates)
        uint256 required = uint256(uint96(rate)) * guaranteedFlowDuration;
        if (uint256(avail) < required) revert INVARIANT_VIOLATED();
    }

    function _add128(uint128 a, uint128 b) internal pure returns (uint128) {
        uint256 s = uint256(a) + uint256(b);
        if (s > type(uint128).max) revert UNITS_OVERFLOW();
        return uint128(s);
    }

    function _toU128(uint256 a) internal pure returns (uint128) {
        if (a > type(uint128).max) revert UNITS_OVERFLOW();
        return uint128(a);
    }

}
