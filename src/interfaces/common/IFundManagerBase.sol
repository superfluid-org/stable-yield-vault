// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";

/**
 * @title IFundManagerBase
 * @notice Shared surface of the Superfluid GDA streaming engine common to every FundManager
 *         variant (async epoch-based, sync ERC-4626). Concrete managers extend this with their
 *         vault-specific hooks (epoch settlement for the async vault, synchronous
 *         deposit/withdraw for the sync vault).
 */
interface IFundManagerBase {

    //    ______                 __
    //   / ____/   _____  ____  / /______
    //  / __/ | | / / _ \/ __ \/ __/ ___/
    // / /___ | |/ /  __/ / / / /_(__  )
    // /_____/ |___/\___/_/ /_/\__/____/

    /**
     * @notice Emitted when the operator updates the committed annualized streaming rate.
     * @param oldRate Previous annualized era rate, expressed in basis points
     * @param newRate New annualized era rate, expressed in basis points
     */
    event StableYieldRateChanged(uint256 oldRate, uint256 newRate);

    /**
     * @notice Emitted when the operator updates the minimum forward stream-solvency horizon.
     * @param oldDuration Previous guaranteed flow duration, in seconds.
     * @param newDuration New guaranteed flow duration, in seconds.
     */
    event GuaranteedFlowDurationChanged(uint256 oldDuration, uint256 newDuration);

    /**
     * @notice Emitted when the admin sweeps tokens out of the FundManager via {emergencyWithdraw}.
     * @param token The token swept out.
     * @param to The recipient of the swept tokens (the calling admin).
     * @param amount The amount transferred.
     */
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Emitted by {onShareTransfer} after the FM moves GDA pool units from sender to receiver.
     * @dev Lets indexers reconstruct yield-stream ownership without binding to the Superfluid pool
     *      contract. Fires only on user-to-user share transfers (vault custody legs of the redeem
     *      cycle don't reach {onShareTransfer}).
     * @param from Share sender
     * @param to Share receiver
     * @param shares Number of vault shares moved
     * @param unitsMoved GDA pool units transferred (proportional to the sender's pre-transfer balance)
     */
    event ShareTransferProcessed(address indexed from, address indexed to, uint256 shares, uint128 unitsMoved);

    /**
     * @notice Emitted by {_rebalanceYieldAssets} when the FM upgrades underlying into super-token or
     *         downgrades super-token back to underlying to keep the forward-solvency reserve sized.
     * @dev Fires from any call path that rebalances: {setStableYieldRate}, {setGuaranteedFlowDuration},
     *      {ensureYieldFlowDuration}, and (indirectly) every {settleEpoch}. No event fires when the
     *      yield-asset deficit is exactly zero (no-op path).
     * @param newYieldAssetsBalance Yield-asset balance after the rebalance, in super-token decimals (18).
     * @param amount Absolute super-token amount moved by the rebalance.
     * @param wasUpgrade True if underlying was upgraded into yield assets (reserve grew); false if
     *                   excess yield assets were downgraded back to underlying (reserve shrunk).
     */
    event YieldAssetsRebalanced(uint256 newYieldAssetsBalance, uint256 amount, bool wasUpgrade);

    /**
     * @notice Emitted by {_recalibrateFlow} whenever the GDA pool's distribution rate is restated.
     * @dev Triggered by any path that calls {_recalibrateFlow}: rate change, epoch settle, redeem
     *      hook, and {ensureYieldFlowDuration}. Indexers can use this as the canonical source of
     *      truth for per-second flow rates without binding to the Superfluid pool contract.
     * @param newYieldFlowRate Per-second yield flow rate (super-token decimals), post-recalibration.
     * @param newFeeFlowRate Per-second fee flow rate (super-token decimals), post-recalibration.
     * @param totalUnits Total pool units after the recalibration.
     */
    event PoolFlowUpdated(int96 newYieldFlowRate, int96 newFeeFlowRate, uint128 totalUnits);

    //    ______
    //   / ____/_____________  __________
    //  / __/ / ___/ ___/ __ \/ ___/ ___/
    // / /___/ /  / /  / /_/ / /  (__  )
    // /_____/_/  /_/   \____/_/  /____/

    /**
     * @notice Thrown when a duration is set below MIN_GUARANTEED_FLOW_DURATION.
     */
    error DURATION_BELOW_FLOOR();

    /**
     * @notice Thrown when constructing the FundManager with a SuperToken contract not wrapping the vault underlying
     * asset
     */
    error ASSET_MISMATCH();

    /**
     * @notice Thrown at construction when the underlying asset's decimals are outside the supported range [6, 18].
     */
    error UNSUPPORTED_DECIMALS();

    /**
     * @notice Thrown when a zero address is provided for a required parameter.
     */
    error ZERO_ADDRESS();

    /**
     * @notice Thrown when the combination of yield rate and duration is invalid.
     */
    error INVALID_YIELD_DURATION_COMBINATION();

    //      ______     __                        __   ______                 __  _
    //     / ____/  __/ /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //    / __/ | |/_/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / /____>  </ /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /_____/_/|_|\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @notice Restart the yield flow if needed and rebalance underlying/yield assets to guarantee the flow duration
     * @dev Only callable by accounts holding FUND_OPERATOR_ROLE.
     */
    function ensureYieldFlowDuration() external;

    /**
     * @notice Set the target annualized era stable yield rate
     * @dev Only callable by accounts holding FUND_OPERATOR_ROLE.
     *      Rebalance the yield assets (subject to unutilized asset balance) and recalibrates the distribution flow;
     * @param newRate The new annualized stable yield rate, expressed in basis points (e.g. 100 <=> 1%)
     */
    function setStableYieldRate(uint256 newRate) external;

    /**
     * @notice Set the minimum forward stream-solvency horizon the FundManager must maintain.
     * @dev Only callable by accounts holding DEFAULT_ADMIN_ROLE.
     *      Reverts with DURATION_BELOW_FLOOR if `newDuration` is below MIN_GUARANTEED_FLOW_DURATION
     * @param newDuration The new guaranteed flow duration, in seconds.
     */
    function setGuaranteedFlowDuration(uint256 newDuration) external;

    /**
     * @notice Withdraw tokens from the FundManager to the treasury in case of emergency.
     * @dev Only callable by accounts holding DEFAULT_ADMIN_ROLE.
     * @param token The address of the token to withdraw.
     * @param amount The amount of tokens to withdraw.
     */
    function emergencyWithdraw(address token, uint256 amount) external;

    //    _    __             ____     ______      __           __
    //   | |  / /___ ___  __/ / /_   / ____/___ _/ /____  ____/ /
    //   | | / / __ `/ / / / / __/  / / __/ __ `/ __/ _ \/ __  /
    //   | |/ / /_/ / /_/ / / /_   / /_/ / /_/ / /_/  __/ /_/ /
    //   |___/\__,_/\__,_/_/\__/   \____/\__,_/\__/\___/\__,_/

    /**
     * @notice Hook invoked by the vault when a share holder transfers their shares.
     * @dev Only callable by accounts holding VAULT_ROLE.
     *      Decrements the sender's pool units proportionally to the amount of shares they transfer
     *      and increments the receiver's pool units by the same amount.
     * @param sender The address of the share sender.
     * @param receiver The address of the share receiver.
     * @param shares The amount of shares being transferred.
     */
    function onShareTransfer(address sender, address receiver, uint256 shares) external;

    //   _    ___                 ______                 __  _
    //  | |  / (_)__ _      __   / ____/_  ______  _____/ /_(_)___  ____  _____
    //  | | / / / _ \ | /| / /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //  | |/ / /  __/ |/ |/ /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  |___/_/\___/|__/|__/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @notice Super-token balance funding the yield stream to the pool.
     * @return balance The amount of yield assets, in super-token decimals (18).
     */
    function yieldAssetsBalance() external view returns (uint256 balance);

    /**
     * @notice Super-token balance funding the yield stream, rescaled to underlying decimals.
     * @return balance The amount of yield assets, in underlying decimals.
     */
    function scaledYieldAssetsBalance() external view returns (uint256 balance);

    /**
     * @notice Amount of super-token the FundManager is short of to sustain the target flow for the
     *         full `guaranteedFlowDuration` horizon.
     * @return deficit deficit amount of yield assets if positive, excess if negative
     */
    function evaluateYieldAssetsDeficit() external view returns (int256 deficit);

    /**
     * @notice The GDA pool whose flow distributes yield to shareholders.
     */
    function YIELD_POOL() external view returns (ISuperfluidPool);

    /**
     * @notice The GDA pool whose flow distributes fees to the treasury.
     */
    function FEE_POOL() external view returns (ISuperfluidPool);

    /**
     * @notice The fee rate applied to yield flow rate to calculate the fee flow rate.
     */
    function FEE_BPS() external view returns (uint256);

    /**
     * @notice The treasury address receiving the fee flow.
     */
    function TREASURY() external view returns (address);

    /**
     * @notice Scale factor lifting underlying amounts into super-token (18-dec) amounts.
     * @dev `= 10 ** (18 - underlyingDecimals)`. For USDC (6-dec) == 10**12.
     */
    function SCALING_FACTOR() external view returns (uint256);

    /**
     * @notice The super-token wrapping the underlying asset.
     */
    function YIELD_ASSET() external view returns (ISuperToken);

    /**
     * @notice The current era's annualized rate committed to per-unit streaming
     * @dev Expressed in basis point (e.g. 100 <=> 1%)
     */
    function stableYieldRate() external view returns (uint256);

    /**
     * @notice The minimum forward stream-solvency horizon the FundManager maintains
     * @dev Expressed in seconds
     */
    function guaranteedFlowDuration() external view returns (uint256);

}
