// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IStableYieldAsyncVault } from "src/interfaces/async-vault/IStableYieldAsyncVault.sol";
import { IFundManagerBase } from "src/interfaces/common/IFundManagerBase.sol";

/**
 * @title IAsyncFundManager
 * @notice Epoch-specific surface of the async ERC-7540 vault's FundManager. Extends the shared
 *         {IFundManagerBase} streaming engine with the two-phase epoch settlement lifecycle and
 *         the operator's off-chain working-capital movement (`give`/`take`).
 */
interface IAsyncFundManager is IFundManagerBase {

    //    ______                 __
    //   / ____/   _____  ____  / /______
    //  / __/ | | / / _ \/ __ \/ __/ ___/
    // / /___ | |/ /  __/ / / / /_(__  )
    // /_____/ |___/\___/_/ /_/\__/____/

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

    //      ______
    //     / ____/_____________  __________
    //    / __/ / ___/ ___/ __ \/ ___/ ___/
    //   / /___/ /  / /  / /_/ / /  (__  )
    //  /_____/_/  /_/   \____/_/  /____/

    /**
     * @notice Thrown when the vault's redeem hook is called with incoherent share arguments.
     */
    error BAD_REDEEM_ARGS();

    /**
     * @notice Thrown when settleEpoch is called but the settlement preconditions are not satisfied.
     */
    error SETTLEMENT_PRECONDITIONS_NOT_MET(string reason);

    /**
     * @notice Thrown when there aren't enough unutilized assets to rebalance into yield assets
     */
    error INSUFFICIENT_UNUTILIZED_ASSETS();

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
     * @notice Deposit underlying assets into the FundManager.
     * @dev Only callable by accounts holding FUND_OPERATOR_ROLE.
     *      Pulls underlying from the caller into the FundManager. This function is not gated by the
     *      epoch settlement lifecycle and does not itself rebalance the yield-asset reserve; operators
     *      should coordinate calls with `evaluateFunding`, `canSettleEpoch`, or `ensureYieldFlowDuration`.
     * @param amount The amount of underlying asset to give.
     */
    function give(uint256 amount) external;

    /**
     * @notice Withdraw underlying assets from the FundManager.
     * @dev Only callable by accounts holding FUND_OPERATOR_ROLE.
     *      Transfers underlying from the FundManager to the caller. This function is not gated by the
     *      epoch settlement lifecycle and performs no solvency check against pending redeems or the
     *      yield-asset reserve; operators must coordinate calls with `evaluateFunding` and
     *      `canSettleEpoch` before settlement.
     * @param amount The amount of underlying asset to take.
     */
    function take(uint256 amount) external;

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
     * @notice Evaluate the current FundManager current funding situation
     * @return funding amount that can be taken if negative, or that must be given if positive
     */
    function evaluateFunding() external view returns (int256 funding);

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

}
