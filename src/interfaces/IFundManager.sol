// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";
import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";

interface IFundManager {

    //    ______                 __
    //   / ____/   _____  ____  / /______
    //  / __/ | | / / _ \/ __ \/ __/ ___/
    // / /___ | |/ /  __/ / / / /_(__  )
    // /_____/ |___/\___/_/ /_/\__/____/

    event AnnualRateChanged(uint256 oldRate, uint256 newRate);
    event GuaranteedFlowDurationChanged(uint256 oldDuration, uint256 newDuration);
    event FlowRateRecalibrated(uint128 totalUnits, uint256 annualRate, int96 flowRate);
    event UnitsTransferred(address indexed from, address indexed to, uint128 amount);
    event Gave(address indexed from, uint256 amount);
    event Took(address indexed to, uint256 amount);

    //    ______
    //   / ____/_____________  __________
    //  / __/ / ___/ ___/ __ \/ ___/ ___/
    // / /___/ /  / /  / /_/ / /  (__  )
    // /_____/_/  /_/   \____/_/  /____/

    error INVARIANT_VIOLATED();
    error FLOW_RATE_OVERFLOW();
    error UNITS_OVERFLOW();
    error UNITS_UNDERFLOW();
    error BAD_REDEEM_ARGS();
    error DURATION_BELOW_FLOOR();
    error NOT_INITIALIZED();

    //      ______     __                        __   ______                 __  _
    //     / ____/  __/ /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //    / __/ | |/_/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / /____>  </ /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /_____/_/|_|\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @notice Commit the settlement of the current epoch in the vault.
     * @dev This operation can only be performed by an account with the FUND_OPERATOR_ROLE
     * @param workingAssets Amount of assets invested at the time of settlement (excludes unutilized assets)
     */
    function closeEpoch(uint256 workingAssets) external;

    /**
     * @notice Finalize the settlement of a current epoch in the vault.
     * @dev This operation can only be performed by an account with the FUND_OPERATOR_ROLE
     *      At the time of this call, the FundManager shall :
     *        1. have previously called `closeEpoch` with the workingAssets for the epoch being settled
     *        2. holds sufficient `unutilizedAssets` to cover for redeemable shares at the epoch rate (if needed)
     */
    function settleEpoch() external;

    /**
     * @notice Give assets to the FundManager.
     * @dev This operation can only be performed by an account with the FUND_OPERATOR_ROLE
     *      Underlying is pulled from the caller and upgraded to the super-token internally.
     * @param amount The amount of underlying asset to give.
     */
    function give(uint256 amount) external;

    /**
     * @notice Take assets from the FundManager.
     * @dev This operation can only be performed by an account with the FUND_OPERATOR_ROLE
     *      Super-token is downgraded internally and underlying is transferred to the caller.
     *      Reverts if the post-operation state would violate the stream solvency invariant.
     * @param amount The amount of underlying asset to take.
     */
    function take(uint256 amount) external;

    /**
     * @notice Set the target annualized rate committed to per-unit streaming.
     * @dev This operation can only be performed by an account with the FUND_OPERATOR_ROLE
     *      Reverts if the post-operation state would violate the stream solvency invariant.
     * @param newRate The new annual rate, scaled by 1e18 (WAD). 5% APR == 5e16.
     */
    function setAnnualRate(uint256 newRate) external;

    /**
     * @notice Set the minimum forward stream-solvency horizon FM must maintain.
     * @dev This operation can only be performed by an account with the FUND_OPERATOR_ROLE
     *      Reverts if below the minimum floor or if the post-operation state would violate the invariant.
     * @param newDuration The new guaranteed flow duration, in seconds.
     */
    function setGuaranteedFlowDuration(uint256 newDuration) external;

    //    _    __             ____     ______      __           __
    //   | |  / /___ ___  __/ / /_   / ____/___ _/ /____  ____/ /
    //   | | / / __ `/ / / / / __/  / / __/ __ `/ __/ _ \/ __  /
    //   | |/ / /_/ / /_/ / / /_   / /_/ / /_/ / /_/  __/ /_/ /
    //   |___/\__,_/\__,_/_/\__/   \____/\__,_/\__/\___/\__,_/

    /**
     * @notice Move assets from the FundManager to a recipient, settling any required unwrap.
     * @dev This operation can only be performed by an account with the VAULT_ROLE
     *      The amount is specified in underlying-asset decimals. Super-token is downgraded
     *      internally and underlying is transferred to `recipient`. Asserts the invariant.
     * @param recipient The address to transfer assets to
     * @param amount The amount of underlying asset to move.
     */
    function move(address recipient, uint256 amount) external;

    /**
     * @notice Hook invoked by the vault when a controller claims their settled deposit.
     * @dev This operation can only be performed by an account with the VAULT_ROLE
     *      Transfers units from FM's pending-member slot to the controller's slot.
     *      Pool total units are unchanged; flow rate is unchanged.
     * @param controller The controller claiming deposit shares.
     * @param depositAssets The originally-deposited underlying assets being claimed (underlying decimals).
     */
    function onClaimDeposit(address controller, uint256 depositAssets) external;

    /**
     * @notice Hook invoked by the vault when a controller requests a redeem.
     * @dev This operation can only be performed by an account with the VAULT_ROLE
     *      Decrements controller's units proportionally and recalibrates flow downward.
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
     * @notice Get the balance of unutilized assets held by the FundManager, in underlying decimals.
     * @dev Derived from the super-token's realtime available balance and scaled to underlying decimals.
     * @return balance The amount of unutilized assets (underlying-denominated)
     */
    function unutilizedAssetsBalance() external view returns (uint256 balance);

    /**
     * @notice The GDA pool whose flow distributes yield to shareholders.
     */
    function POOL() external view returns (ISuperfluidPool);

    /**
     * @notice The super-token wrapping the underlying asset.
     */
    function SUPER_TOKEN() external view returns (ISuperToken);

    /**
     * @notice The current annualized rate committed to per-unit streaming, scaled by 1e18.
     */
    function annualRate() external view returns (uint256);

    /**
     * @notice The minimum forward stream-solvency horizon FM maintains, in seconds.
     */
    function guaranteedFlowDuration() external view returns (uint256);

}
