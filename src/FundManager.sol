// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    IERC4626,
    IERC7540Deposit,
    IERC7540Operator,
    IERC7540Redeem,
    IERC7575,
    IStableYieldAsyncVault
} from "./interfaces/IStableYieldAsyncVault.sol";

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract FundManager is IFundManager, AccessControl {

    /// @notice Role identifier for fund operators
    byte32 public constant FUND_OPERATOR_ROLE = keccak256("FUND_OPERATOR_ROLE");

    /// @notice Reference to the StableYieldAsyncVault contract
    IStableYieldAsyncVault public immutable VAULT;

    IERC20 public immutable ASSET;

    /**
     * @notice Constructor for the FundManager contract
     * @param _vault The address of the StableYieldAsyncVault contract
     * @param _admin The address to be granted the default admin role
     * @param _fundOperator The address to be granted the fund operator role
     */
    constructor(IStableYieldAsyncVault _vault, address _admin, address _fundOperator) {
        VAULT = _vault;
        ASSET = IERC20(_vault.asset());

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FUND_OPERATOR_ROLE, _fundOperator);
    }

    //      ______     __                        __   ______                 __  _
    //     / ____/  __/ /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //    / __/ | |/_/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / /____>  </ /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /_____/_/|_|\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @inheritdoc IFundManager
    function closeEpoch(uint256 workingAssets) external onlyRole(FUND_OPERATOR_ROLE) {
        // Total Fund Assets is the sum of working assets and unutilized assets (held in this contract)
        uint256 totalFundAssets = workingAssets + unutilizedAssetsBalance();

        // Commit the settlement of the current epoch in the vault with the total fund assets
        VAULT.closeEpoch(totalFundAssets);
    }

    /// @inheritdoc IFundManager
    function settleEpoch() external onlyRole(FUND_OPERATOR_ROLE) {
        // Call settleEpoch on the vault to finalize the settlement of the current epoch
        VAULT.settleEpoch();
    }

    /// @inheritdoc IFundManager
    function give(uint256 amount) external onlyRole(FUND_OPERATOR_ROLE) {
        // Transfer the specified amount of assets from the caller to this contract
        ASSET.transferFrom(msg.sender, address(this), amount);
    }

    /// @inheritdoc IFundManager
    function take(uint256 amount) external onlyRole(FUND_OPERATOR_ROLE) {
        // Transfer the specified amount of assets from this contract to the caller
        ASSET.transfer(msg.sender, amount);
    }

    //   _    ___                 ______                 __  _
    //  | |  / (_)__ _      __   / ____/_  ______  _____/ /_(_)___  ____  _____
    //  | | / / / _ \ | /| / /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //  | |/ / /  __/ |/ |/ /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  |___/_/\___/|__/|__/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @inheritdoc IFundManager
    function unutilizedAssetsBalance() public view returns (uint256 balance) {
        // Return the balance of unutilized assets held by this FundManager
        return ASSET.balanceOf(address(this));
    }

}
