// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";
import { IStableYieldAsyncVault } from "src/interfaces/vault/IStableYieldAsyncVault.sol";

interface IFundManager {

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
     * @notice Emitted when the operator deposits underlying assets into the FundManager.
     * @param from The address providing the assets.
     * @param amount The amount of underlying asset given.
     */
    event Gave(address indexed from, uint256 amount);

    /**
     * @notice Emitted when the operator withdraws underlying assets from the FundManager.
     * @param to The address receiving the assets.
     * @param amount The amount of underlying asset taken.
     */
    event Took(address indexed to, uint256 amount);

    //    ______
    //   / ____/_____________  __________
    //  / __/ / ___/ ___/ __ \/ ___/ ___/
    // / /___/ /  / /  / /_/ / /  (__  )
    // /_____/_/  /_/   \____/_/  /____/

    /**
     * @notice Thrown when the vault's redeem hook is called with incoherent share arguments.
     */
    error BAD_REDEEM_ARGS();

    /**
     * @notice Thrown when a duration is set below MIN_GUARANTEED_FLOW_DURATION.
     */
    error DURATION_BELOW_FLOOR();

    /**
     * @notice Thrown when settleEpoch is called but the settlement preconditions are not satisfied.
     */
    error SETTLEMENT_PRECONDITIONS_NOT_MET(string reason);

    /**
     * @notice Thrown when constructing the FundManager with a SuperToken contract not wrapping the vault underlying
     * asset
     */
    error ASSET_MISMATCH();

    /**
     * @notice Thrown when there aren't enough unutilized assets to rebalance into yield assets
     */
    error INSUFFICIENT_UNUTILIZED_ASSETS();

    /**
     * @notice Thrown at construction when the underlying asset's decimals are outside the supported range [6, 18].
     */
    error UNSUPPORTED_DECIMALS();

    //      ______     __                        __   ______                 __  _
    //     / ____/  __/ /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //    / __/ | |/_/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / /____>  </ /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /_____/_/|_|\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @notice Close the current epoch in the vault by reporting total fund assets.
     * @dev Only callable by accounts holding FUND_OPERATOR_ROLE.
     *      Total fund assets = `workingAssets` + unutilized balance + scaled yield balance.
     * @param workingAssets Amount of assets invested at the time of settlement (excludes unutilized assets),
     *                      in underlying decimals.
     */
    function closeEpoch(uint256 workingAssets) external;

    /**
     * @notice Finalize settlement of the currently-closed epoch.
     * @dev Only callable by accounts holding FUND_OPERATOR_ROLE.
     *      Reverts with SETTLEMENT_PRECONDITIONS_NOT_MET if {canSettleEpoch} returns false, i.e. if any of:
     *        1. `closeEpoch` has not been called for the epoch being settled;
     *        2. the post-settlement super-token balance cannot sustain the new flow for `guaranteedFlowDuration`;
     *        3. redeeming assets exceed depositing assets and the FundManager does not hold enough unutilized
     *           assets to cover the difference at the epoch rate.
     */
    function settleEpoch() external;

    /**
     * @notice Restart the yield flow if needed and rebalance underlying/yield assets to guarantee the flow duration
     * @dev Only callable by accounts holding FUND_OPERATOR_ROLE.
     */
    function ensureYieldFlowDuration() external;

    /**
     * @notice Deposit underlying assets into the FundManager.
     * @dev Only callable by accounts holding FUND_OPERATOR_ROLE.
     *      Pulls underlying from the caller into the FundManager.
     * @param amount The amount of underlying asset to give.
     */
    function give(uint256 amount) external;

    /**
     * @notice Withdraw underlying assets from the FundManager.
     * @dev Only callable by accounts holding FUND_OPERATOR_ROLE.
     *      Transfers underlying from the FundManager to the caller.
     * @param amount The amount of underlying asset to take.
     */
    function take(uint256 amount) external;

    /**
     * @notice Set the target annualized era stable yield rate
     * @dev Only callable by accounts holding FUND_OPERATOR_ROLE.
     *      Recalibrates the distribution flow; reverts with INVARIANT_VIOLATED if the new rate would break
     *      the stream-solvency invariant.
     * @param newRate The new annualized stable yield rate, expressed in basis points (e.g. 100 <=> 1%)
     */
    function setStableYieldRate(uint256 newRate) external;

    /**
     * @notice Set the minimum forward stream-solvency horizon the FundManager must maintain.
     * @dev Only callable by accounts holding DEFAULT_ADMIN_ROLE.
     *      Reverts with DURATION_BELOW_FLOOR if `newDuration` is below MIN_GUARANTEED_FLOW_DURATION,
     *      or with INVARIANT_VIOLATED if the post-operation state would break the invariant.
     * @param newDuration The new guaranteed flow duration, in seconds.
     */
    function setGuaranteedFlowDuration(uint256 newDuration) external;

    //    _    __             ____     ______      __           __
    //   | |  / /___ ___  __/ / /_   / ____/___ _/ /____  ____/ /
    //   | | / / __ `/ / / / / __/  / / __/ __ `/ __/ _ \/ __  /
    //   | |/ / /_/ / /_/ / / /_   / /_/ / /_/ / /_/  __/ /_/ /
    //   |___/\__,_/\__,_/_/\__/   \____/\__,_/\__/\___/\__,_/

    /**
     * @notice Hook invoked by the vault when a controller claims their settled deposit.
     * @dev Only callable by accounts holding VAULT_ROLE.
     *      Transfers pool units from the FundManager's pending-member slot to the controller's slot.
     *      Pool total units and flow rate are unchanged.
     * @param controller The controller claiming deposit shares.
     * @param depositAssets The originally-deposited underlying assets being claimed, in underlying decimals.
     */
    function onClaimDeposit(address controller, uint256 depositAssets) external;

    /**
     * @notice Hook invoked by the vault when a controller requests a redeem.
     * @dev Only callable by accounts holding VAULT_ROLE.
     *      Decrements the controller's pool units proportionally to `sharesRedeemed / totalSharesOwned`
     *      and recalibrates the pool flow downward.
     * @param controller The controller requesting redeem.
     * @param sharesRedeemed The number of shares being redeemed.
     * @param totalSharesOwned The controller's total share balance before the redeem lock.
     */
    function onRequestRedeem(address controller, uint256 sharesRedeemed, uint256 totalSharesOwned) external;

    //   _    ___                 ______                 __  _
    //  | |  / (_)__ _      __   / ____/_  ______  _____/ /_(_)___  ____  _____
    //  | | / / / _ \ | /| / /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //  | |/ / /  __/ |/ |/ /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  |___/_/\___/|__/|__/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @notice Unutilized underlying assets held by the FundManager (available to cover redeem deficits).
     * @return balance The amount of unutilized assets, in underlying decimals.
     */
    function unutilizedAssetsBalance() external view returns (uint256 balance);

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
     * @notice Evaluate the current FundManager current funding situation
     * @return funding amount that can be taken if negative, or that must be given if positive
     */
    function evaluateFunding() external view returns (int256 funding);

    /**
     * @notice Amount of super-token the FundManager is short of to sustain the target flow for the
     *         full `guaranteedFlowDuration` horizon.
     * @return deficit deficit amount of yield assets if positive, excess if negative
     */
    function evaluateYieldAssetsDeficit() external view returns (int256 deficit);

    /**
     * @notice Whether the current epoch satisfies all preconditions required to call {settleEpoch}.
     * @return canSettle True if {settleEpoch} can be called without reverting on preconditions.
     * @return reason The reason for which precondition is not satisfied
     * @return snap The settling epoch snapshot
     */
    function canSettleEpoch()
        external
        view
        returns (bool canSettle, string memory reason, IStableYieldAsyncVault.Snapshot memory snap);

    /**
     * @notice The GDA pool whose flow distributes yield to shareholders.
     */
    function POOL() external view returns (ISuperfluidPool);

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
