// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

interface IFundManager {

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
     * @param amount The amount of assets to give.
     */
    function give(uint256 amount) external;

    /**
     * @notice Take assets from the FundManager.
     * @dev This operation can only be performed by an account with the FUND_OPERATOR_ROLE
     * @param amount The amount of assets to take.
     */
    function take(uint256 amount) external;

    /**
     * @notice Move assets from the FundManager.
     * @dev This operation can only be performed by an account with the VAULT_ROLE
     * @param recipient The address to transfer assets to
     * @param amount The amount of assets to move.
     */
    function move(address recipient, uint256 amount) external;

    //   _    ___                 ______                 __  _
    //  | |  / (_)__ _      __   / ____/_  ______  _____/ /_(_)___  ____  _____
    //  | | / / / _ \ | /| / /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //  | |/ / /  __/ |/ |/ /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  |___/_/\___/|__/|__/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @notice Get the balance of unutilized assets held by the FundManager.
     * @return balance The amount of unutilized assets
     */
    function unutilizedAssetsBalance() external view returns (uint256 balance);

}
