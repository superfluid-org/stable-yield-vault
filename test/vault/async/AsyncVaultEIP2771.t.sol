// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { AsyncVaultTestBase } from "./AsyncVaultTestBase.t.sol";

import { IStableYieldAsyncVault } from "src/interfaces/vault/async/IStableYieldAsyncVault.sol";

/**
 * @title AsyncVaultEIP2771Test
 * @notice Covers the meta-transaction surface that lets a Superfluid macro relay the async vault's
 *         user entry points: the vault is an EIP-2771 recipient (trusting the Host's
 *         `ERC2771Forwarder`), so a forwarded call resolves the real user from the appended
 *         calldata — `requestDeposit` pulls from the appended owner, `setOperator` records for the
 *         appended controller, and the claim/redeem paths authorize against the appended sender.
 */
contract AsyncVaultEIP2771Test is AsyncVaultTestBase {

    uint256 internal constant USDCX_SEED = 100 ether; // Covers flow recalibration security deposits

    function setUp() public override {
        super.setUp();
        // Seed the FundManager with USDCx so any flow recalibration succeeds.
        _dealUSDCx(address(_fundManager), USDCX_SEED);
    }

    //    ______________   ___ ____  ______ ____
    //   / ____/  _/ __ \ |__ \__  / /__  // /  /
    //  / __/  / // /_/ / __/ //_ <    / // /  /
    // / /____/ // ____/ / __/__/ /   / //_/  /
    // /_____/___/_/     /____/____/  /_/(_)_/

    function test_trustedForwarder_isHostERC2771Forwarder() public view {
        address fwd = _vault.trustedForwarder();
        assertTrue(fwd != address(0), "vault must trust a non-zero forwarder");
        assertTrue(_vault.isTrustedForwarder(fwd), "isTrustedForwarder(forwarder)");
        assertEq(fwd, _sf.host.getERC2771Forwarder(), "trusts the Host's forwarder");
    }

    /// @dev A requestDeposit routed through the trusted forwarder (user appended per ERC-2771)
    ///      passes the owner-authorization check as the *appended* user and pulls from them.
    function test_eip2771_requestDepositResolvesAppendedSender(uint256 amount) public {
        amount = bound(amount, 1, ONE_BILLION * 1e6);
        address user = makeAddr("eip2771-requester");
        _dealUSDC(user, amount);
        vm.prank(user);
        _usdc.approve(address(_vault), type(uint256).max);

        _forwarderCall(abi.encodeCall(_vault.requestDeposit, (amount, user, user)), user);

        assertEq(_vault.pendingDepositRequest(0, user), amount, "pending recorded for the appended user");
        assertEq(_usdc.balanceOf(user), 0, "assets pulled from the appended user");
        assertEq(_usdc.balanceOf(address(_vault)), amount, "assets escrowed in the vault");
    }

    /// @dev A forwarded setOperator records the approval for the appended user — the leg the macro
    ///      uses to batch operator approval with a deposit request.
    function test_eip2771_setOperatorResolvesAppendedSender() public {
        address user = makeAddr("eip2771-controller");
        address operator = makeAddr("eip2771-operator");

        _forwarderCall(abi.encodeCall(_vault.setOperator, (operator, true)), user);

        assertTrue(_vault.isOperator(user, operator), "operator recorded for the appended user");
        assertFalse(_vault.isOperator(_vault.trustedForwarder(), operator), "nothing recorded for the forwarder");
    }

    /// @dev Forwarded requestRedeem + withdraw resolve the appended user across the full redeem leg.
    function test_eip2771_redeemLegResolvesAppendedSender(uint256 amount) public {
        amount = bound(amount, 1, ONE_BILLION * 1e6);
        address user = makeAddr("eip2771-redeemer");
        uint256 shares = _completeDeposit(user, amount);

        _forwarderCall(abi.encodeCall(_vault.requestRedeem, (shares, user, user)), user);
        assertEq(_vault.pendingRedeemRequest(0, user), shares, "pending redeem for the appended user");

        _vaultCloseEpoch(_vault.totalSupply() / 1e12);
        _vaultSettleAndGrantUnits();

        uint256 claimable = _vault.maxWithdraw(user);
        _forwarderCall(abi.encodeCall(_vault.withdraw, (claimable, user, user)), user);
        assertEq(_usdc.balanceOf(user), claimable, "proceeds paid to the appended user");
    }

    /// @dev A direct (non-forwarder) call is unaffected: `_msgSender()` falls back to `msg.sender`.
    function test_eip2771_directCallUnaffected(uint256 amount) public {
        amount = bound(amount, 1, ONE_BILLION * 1e6);
        _dealUSDC(ALICE, amount);
        vm.startPrank(ALICE);
        _usdc.approve(address(_vault), type(uint256).max);
        _vault.requestDeposit(amount, ALICE, ALICE);
        vm.stopPrank();
        assertEq(_vault.pendingDepositRequest(0, ALICE), amount, "direct request unchanged");
    }

    /// @dev A spoofed appended sender from a NON-trusted caller is ignored — `_msgSender()` stays
    ///      the real `msg.sender`, so the attacker fails the owner check and cannot act as the victim.
    function test_eip2771_untrustedCallerCannotSpoofSender(uint256 amount) public {
        amount = bound(amount, 1, ONE_BILLION * 1e6);
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        _dealUSDC(victim, amount);
        vm.prank(victim);
        _usdc.approve(address(_vault), type(uint256).max);

        // Attacker (not the forwarder) appends the victim, trying to request "as" the victim.
        vm.prank(attacker);
        (bool ok, bytes memory ret) = address(_vault).call(
            abi.encodePacked(abi.encodeCall(_vault.requestDeposit, (amount, victim, victim)), victim)
        );

        assertFalse(ok, "spoofed request must revert (attacker is not the victim's operator)");
        assertEq(bytes4(ret), IStableYieldAsyncVault.INVALID_CALLER.selector, "INVALID_CALLER");
        assertEq(_usdc.balanceOf(victim), amount, "victim untouched");
    }

    /// @dev A spoofed setOperator from a non-trusted caller records for the attacker, not the victim.
    function test_eip2771_untrustedCallerCannotSpoofOperator() public {
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");

        vm.prank(attacker);
        (bool ok,) =
            address(_vault).call(abi.encodePacked(abi.encodeCall(_vault.setOperator, (attacker, true)), victim));

        assertTrue(ok, "call itself succeeds, but as the attacker");
        assertFalse(_vault.isOperator(victim, attacker), "victim untouched");
        assertTrue(_vault.isOperator(attacker, attacker), "recorded for the attacker themselves");
    }

    //    __  __     __
    //   / / / /__  / /___  ___  ___________
    //  / /_/ / _ \/ / __ \/ _ \/ ___/ ___/
    // / __  /  __/ / /_/ /  __/ /  (__  )
    // /_/ /_/\___/_/ .___/\___/_/  /____/
    //             /_/

    /// @dev Drive a call through the vault's trusted forwarder with `sender` appended per ERC-2771.
    function _forwarderCall(bytes memory data, address sender) internal {
        vm.prank(_vault.trustedForwarder());
        (bool ok,) = address(_vault).call(abi.encodePacked(data, sender));
        assertTrue(ok, "forwarded call reverted");
    }

    /// @dev Full request → settle → claim deposit cycle for `user`; returns the minted shares.
    function _completeDeposit(address user, uint256 amount) internal returns (uint256 shares) {
        _dealUSDC(user, amount);
        vm.startPrank(user);
        _usdc.approve(address(_vault), type(uint256).max);
        _vault.requestDeposit(amount, user, user);
        vm.stopPrank();

        _vaultCloseEpoch(_vault.totalSupply() / 1e12);
        _vaultSettleAndGrantUnits();

        vm.prank(user);
        _vault.deposit(amount, user);
        shares = _vault.balanceOf(user);
    }

}
