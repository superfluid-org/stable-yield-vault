// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IStableYieldSyncVault } from "src/interfaces/vault/sync/IStableYieldSyncVault.sol";
import { ISyncFundManager } from "src/interfaces/vault/sync/ISyncFundManager.sol";
import { SyncFundManager } from "src/vault/sync/SyncFundManager.sol";

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title StableYieldSyncVault
 * @notice Synchronous ERC-4626 stable-yield vault — a thin share/accounting face. It holds no
 *         assets: the paired {SyncFundManager} (deployed and pinned here at construction) is
 *         the sole capital custodian (external-vault shares, yield assets
 *         reserve) and NAV authority. The vault pulls underlying from the caller,
 *         forwards it to the FundManager, mints/burns shares. The stable yield is streamed via
 *         Superfluid Distribution pool, pre-funded from each deposit.
 * @dev    Read this contract before {SyncFundManager}
 */
contract StableYieldSyncVault is ERC4626, ReentrancyGuard, IStableYieldSyncVault {

    using Math for uint256;
    using SafeERC20 for IERC20;

    //      ____                          __        __    __        _____ __        __
    //     /  _/___ ___  ____ ___  __  __/ /_____ _/ /_  / /__     / ___// /_____ _/ /____  _____
    //     / // __ `__ \/ __ `__ \/ / / / __/ __ `/ __ \/ / _ \    \__ \/ __/ __ `/ __/ _ \/ ___/
    //   _/ // / / / / / / / / / / /_/ / /_/ /_/ / /_/ / /  __/   ___/ / /_/ /_/ / /_/  __(__  )
    //  /___/_/ /_/ /_/_/ /_/ /_/\__,_/\__/\__,_/_.___/_/\___/   /____/\__/\__,_/\__/\___/____/

    /// @inheritdoc IStableYieldSyncVault
    ISyncFundManager public immutable FUND_MANAGER;

    //     ______                 __                  __
    //    / ____/___  ____  _____/ /________  _______/ /_____  _____
    //   / /   / __ \/ __ \/ ___/ __/ ___/ / / / ___/ __/ __ \/ ___/
    //  / /___/ /_/ / / / (__  ) /_/ /  / /_/ / /__/ /_/ /_/ / /
    //  \____/\____/_/ /_/____/\__/_/   \__,_/\___/\__/\____/_/

    /**
     * @notice Initializes the vault, validates the external vault, and deploys {SyncFundManager}
     * @param _treasury Treasury address collecting fees
     * @param _underlyingAsset Underlying ERC-20 asset (e.g. USDC)
     * @param _yieldAsset Wrapped super-token of the underlying asset (e.g. USDCx)
     * @param _externalVault External ERC-4626 vault whose `asset()` is `_underlyingAsset`
     * @param _fundOperator FundManager operator (FUND_OPERATOR_ROLE)
     * @param _fundAdmin FundManager admin (DEFAULT_ADMIN_ROLE)
     * @param _initialStableYieldRate Initial era stable yield rate (basis points, e.g. 100% <=> 1)
     * @param _initialGuaranteedFlowDuration Initial forward-solvency horizon in seconds
     * @param name The name of the share token
     * @param symbol The symbol of the share token
     */
    constructor(
        address _treasury,
        address _underlyingAsset,
        address _yieldAsset,
        address _externalVault,
        address _fundOperator,
        address _fundAdmin,
        uint256 _initialStableYieldRate,
        uint256 _initialGuaranteedFlowDuration,
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) ERC4626(IERC20(_underlyingAsset)) {
        if (IERC4626(_externalVault).asset() != _underlyingAsset) revert EXTERNAL_ASSET_MISMATCH();

        FUND_MANAGER = new SyncFundManager(
            _treasury,
            _underlyingAsset,
            _yieldAsset,
            _externalVault,
            _fundOperator,
            _fundAdmin,
            _initialStableYieldRate,
            _initialGuaranteedFlowDuration
        );
    }

    //      ______     __                        __   ______                 __  _
    //     / ____/  __/ /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //    / __/ | |/_/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   / /____>  </ /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /_____/_/|_|\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /// @inheritdoc ERC4626
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    /// @inheritdoc ERC4626
    function mint(uint256 shares, address receiver) public override(ERC4626, IERC4626) nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    /// @inheritdoc ERC4626
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    /// @inheritdoc ERC4626
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    //    _    ___                 ______                 __  _
    //   | |  / (_)__ _      __   / ____/_  ______  _____/ /_(_)___  ____  _____
    //   | | / / / _ \ | /| / /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   | |/ / /  __/ |/ |/ /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //   |___/_/\___/|__/|__/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @inheritdoc ERC4626
     * @dev Yield asset inclusive NAV, delegated to the FundManager
     */
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return FUND_MANAGER.totalManagedAssets();
    }

    /**
     * @dev First-deposit inflation-attack resistance via OZ virtual shares. With the NAV clamp
     *      dropped (floating share, 2026-05-26), donations are no longer absorbed by the price, so
     *      the empty-vault bootstrap is the one genuinely exploitable surface; a positive offset
     *      makes it economically infeasible (the donation needed to round a victim to zero, and the
     *      attacker's unrecoverable loss on it, both scale by `10 ** offset`).
     *
     *      Hardcoded `12` targets the 6-dec USDC deployment: it yields a `10 ** 12` attack-cost
     *      multiplier and `6 + 12 = 18`-decimal shares (the conventional 18-dec presentation).
     *      Note: 18-dec shares coincide with the 18-dec `YIELD_ASSET` (USDCx) purely by arithmetic
     *      — shares track NAV in underlying terms and are unrelated to the super-token reserve.
     *      The offset only scales the share <-> `totalAssets` conversion; it does not touch the FM's
     *      super-token reserve, `SCALING_FACTOR`, or the GDA units (computed off `assets`).
     *      For a non-6-dec underlying, revisit this value (see `docs/sync-vault/open-questions.md`).
     */
    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }

    /**
     * @inheritdoc ERC4626
     * @dev Additionally capped by the external vault's own deposit limit (FM as holder). Returns
     *      `0` under terminal external impairment (see {_isExternallyPaused}): we never route a
     *      user into a vault they cannot withdraw from.
     */
    function maxDeposit(address) public view override(ERC4626, IERC4626) returns (uint256) {
        if (_isExternallyPaused()) return 0;
        return FUND_MANAGER.maxExternalDeposit();
    }

    /**
     * @inheritdoc ERC4626
     * @dev Additionally capped by the external vault's own deposit limit (in share terms). Returns
     *      `0` under terminal external impairment (see {_isExternallyPaused}).
     */
    function maxMint(address) public view override(ERC4626, IERC4626) returns (uint256) {
        if (_isExternallyPaused()) return 0;
        uint256 externalMax = FUND_MANAGER.maxExternalDeposit();
        if (externalMax == type(uint256).max) return type(uint256).max;
        return _convertToShares(externalMax, Math.Rounding.Floor);
    }

    /**
     * @inheritdoc ERC4626
     * @dev Returns `0` under terminal external impairment (see {_isExternallyPaused}); the surviving
     *      reserve is reserved for the yield stream, not for withdrawal. Otherwise capped by the
     *      reserve-inclusive NAV.
     */
    function maxWithdraw(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        if (_isExternallyPaused()) return 0;
        uint256 byShares = _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
        uint256 serviceable = FUND_MANAGER.totalManagedAssets();
        return byShares < serviceable ? byShares : serviceable;
    }

    /**
     * @inheritdoc ERC4626
     * @dev Returns `0` under terminal external impairment (see {_isExternallyPaused}). Otherwise
     *      capped by the reserve-inclusive NAV (in share terms).
     */
    function maxRedeem(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        if (_isExternallyPaused()) return 0;
        uint256 ownerShares = balanceOf(owner);
        uint256 redeemableByLiquidity = _convertToShares(FUND_MANAGER.totalManagedAssets(), Math.Rounding.Floor);
        return ownerShares < redeemableByLiquidity ? ownerShares : redeemableByLiquidity;
    }

    /**
     * @dev Terminal external impairment ⇒ full pause. When `EXTERNAL_VAULT.maxWithdraw(FM) == 0`
     *      the deployed principal cannot be recovered through the external vault, so all four
     *      `max*` return `0` (OZ then reverts any deposit/mint/withdraw/redeem with
     *      `ERC4626ExceededMax*`). The vault simply waits for the external position to unfreeze;
     *      meanwhile the Superfluid stream keeps paying existing holders out of the reserve until
     *      it is naturally liquidated. `maxWithdraw(FM) == 0` does not distinguish a permanent loss
     *      from a temporary liquidity freeze — both are treated as a pause;
     *
     *      The pause is gated on the FM actually *holding* an external position: an empty external
     *      balance also reads `maxWithdraw(FM) == 0` but is the healthy bootstrap state (no principal
     *      deployed yet), not impairment — pausing it would brick the first deposit.
     */
    function _isExternallyPaused() internal view returns (bool) {
        return FUND_MANAGER.maxExternalVaultWithdraw() == 0
            && FUND_MANAGER.EXTERNAL_VAULT().balanceOf(address(FUND_MANAGER)) > 0;
    }

    //      ____      __                        __   ______                 __  _
    //     /  _/___  / /____  _________  ____ _/ /  / ____/_  ______  _____/ /_(_)___  ____  _____
    //     / // __ \/ __/ _ \/ ___/ __ \/ __ `/ /  / /_  / / / / __ \/ ___/ __/ / __ \/ __ \/ ___/
    //   _/ // / / / /_/  __/ /  / / / / /_/ / /  / __/ / /_/ / / / / /__/ /_/ / /_/ / / / (__  )
    //  /___/_/ /_/\__/\___/_/  /_/ /_/\__,_/_/  /_/    \__,_/_/ /_/\___/\__/_/\____/_/ /_/____/

    /**
     * @dev Deposit workflow: pull underlying from `caller` straight to the FundManager (the
     *      custodian), mint shares, then notify the FM — which bumps principal, replenishes the
     *      yield assets, pre-funds and update the distribution flow, deploys the remainder into
     *      the external vault.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        IERC20(asset()).safeTransferFrom(caller, address(FUND_MANAGER), assets);

        _mint(receiver, shares);

        FUND_MANAGER.onDeposit(receiver, assets);

        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Withdraw workflow: spend allowance, snapshot balance/supply, burn shares, then
     *      hand off to the FundManager — which decrements the holder's units proportionally and
     *      funds the payout from a shares-proportional reserve slice + the external vault (R-shares
     *      sourcing). There is no principal counter; `assets` is the OZ pro-rata `shares · NAV /
     *      supply` (floor), so stayers stay whole automatically.
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        uint256 totalSharesOwned = balanceOf(owner);
        uint256 supplyBeforeBurn = totalSupply();

        _burn(owner, shares);

        FUND_MANAGER.onWithdraw(owner, shares, totalSharesOwned, supplyBeforeBurn, receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /**
     * @dev Mirrors the async vault: notify the FundManager to move a proportional slice of
     *      GDA yield units on shareholder↔shareholder transfers (skips mint/burn legs).
     */
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && from != address(this) && to != address(this)) {
            FUND_MANAGER.onShareTransfer(from, to, value);
        }
        super._update(from, to, value);
    }

}
