// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { SyncVaultTestBase } from "./SyncVaultTestBase.t.sol";

import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";

/**
 * @title SyncVaultEIP2771Test
 * @notice Covers the meta-transaction surface that lets a Superfluid macro batch
 *         `permit + deposit + connectPool` in one tx: the vault is an EIP-2771 recipient (trusting
 *         the Host's `ERC2771Forwarder`), so a forwarded deposit resolves the real depositor from the
 *         appended calldata; plus the `depositWithPermit` one-call entry. See
 *         `docs/sync-vault/plan/eip2771-batched-deposit.md`.
 */
contract SyncVaultEIP2771Test is SyncVaultTestBase {

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    //    ______________   ___ ____  ______ ____
    //   / ____/  _/ __ \ |__ \__  / /__  // /  /
    //  / __/  / // /_/ / __/ //_ <    / // /  /
    // / /____/ // ____/ / __/__/ /   / //_/  /
    // /_____/___/_/     /____/____/  /_/(_)_/

    function test_trustedForwarder_isHostERC2771Forwarder() public view {
        address fwd = _vault.trustedForwarder();
        assertTrue(fwd != address(0), "vault must trust a non-zero forwarder");
        assertTrue(_vault.isTrustedForwarder(fwd), "isTrustedForwarder(forwarder)");
    }

    /// @dev A deposit routed through the trusted forwarder (depositor appended per ERC-2771) pulls
    ///      from and mints to the *appended* user, not the forwarder — and skims the fee + grants
    ///      units on the net, exactly as a direct call would.
    function test_eip2771_depositResolvesAppendedSender(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        address user = makeAddr("eip2771-depositor");
        uint256 gross = amount + _vault.DEPOSIT_FEE();
        _fund(user, gross); // mints USDC to user + approves the vault to pull it

        ISuperfluidPool pool = _fundManager.YIELD_POOL();
        uint256 treasuryBefore = _usdc.balanceOf(TREASURY);

        // Simulate the Host's type-302 call: msg.sender == trustedForwarder, `user` appended (20 bytes).
        _forwarderCall(abi.encodeCall(_vault.deposit, (gross, user)), user);

        assertEq(_vault.balanceOf(user), amount * 1e12, "shares minted to the appended user");
        assertEq(_usdc.balanceOf(user), 0, "gross pulled from the appended user");
        assertEq(_usdc.balanceOf(TREASURY) - treasuryBefore, _vault.DEPOSIT_FEE(), "fee to treasury");
        assertGt(pool.getUnits(user), 0, "units granted to the appended user");
    }

    /// @dev A direct (non-forwarder) call is unaffected: `_msgSender()` falls back to `msg.sender`.
    function test_eip2771_directCallUnaffected(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        uint256 shares = _deposit(ALICE, amount);
        assertEq(shares, amount * 1e12, "direct deposit unchanged");
        assertEq(_vault.balanceOf(ALICE), shares, "shares to the direct caller");
    }

    /// @dev A spoofed appended sender from a NON-trusted caller is ignored — `_msgSender()` stays the
    ///      real `msg.sender`, so the attacker can only ever act as themselves.
    function test_eip2771_untrustedCallerCannotSpoofSender(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        uint256 gross = amount + _vault.DEPOSIT_FEE();
        _fund(attacker, gross); // only the attacker is funded/approved

        // Attacker (not the forwarder) appends the victim, trying to deposit "as" the victim.
        vm.prank(attacker);
        (bool ok,) = address(_vault).call(abi.encodePacked(abi.encodeCall(_vault.deposit, (gross, attacker)), victim));

        assertTrue(ok, "call itself succeeds, but as the attacker");
        assertEq(_usdc.balanceOf(attacker), 0, "pulled from the attacker, not the victim");
        assertEq(_usdc.balanceOf(victim), 0, "victim untouched");
    }

    //    ____                       _ __ _       ___ __  __  ____                    _ __
    //   / __ \___  ____  ____  _____(_) /_| |     / (_) /_/ /_/ __ \___  _________ ___ (_) /_
    //  / / / / _ \/ __ \/ __ \/ ___/ / __/ | /| / / / __/ __/ /_/ / _ \/ ___/ __ `__ \/ / __/
    // / /_/ /  __/ /_/ / /_/ (__  ) / /_ | |/ |/ / / /_/ /_/ ____/  __/ /  / / / / / / / /_
    // /_____/\___/ .___/\____/____/_/\__/ |__/|__/_/\__/\__/_/    \___/_/  /_/ /_/ /_/_/\__/
    //           /_/

    function test_depositWithPermit_happyPath(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        (address user, uint256 pk) = makeAddrAndKey("permit-depositor");
        uint256 gross = amount + _vault.DEPOSIT_FEE();
        _dealUSDC(user, gross); // fund but DO NOT approve — the permit grants the allowance

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, user, address(_vault), gross, type(uint256).max);

        uint256 treasuryBefore = _usdc.balanceOf(TREASURY);
        vm.prank(user);
        uint256 sharesOut = _vault.depositWithPermit(gross, user, type(uint256).max, v, r, s);

        assertEq(sharesOut, amount * 1e12, "shares minted on the net principal");
        assertEq(_vault.balanceOf(user), sharesOut, "shares to receiver");
        assertEq(_usdc.balanceOf(user), 0, "gross pulled via the permit allowance");
        assertEq(_usdc.balanceOf(TREASURY) - treasuryBefore, _vault.DEPOSIT_FEE(), "fee to treasury");
    }

    /// @dev `depositWithPermit` honours the flat-fee floor: a gross at/below the fee reverts.
    function test_depositWithPermit_belowFee_reverts() public {
        (address user, uint256 pk) = makeAddrAndKey("permit-dust");
        uint256 gross = _vault.DEPOSIT_FEE();
        _dealUSDC(user, gross);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, user, address(_vault), gross, type(uint256).max);

        vm.prank(user);
        vm.expectRevert(); // DEPOSIT_BELOW_FEE (after the permit consumes, inside `_deposit`)
        _vault.depositWithPermit(gross, user, type(uint256).max, v, r, s);
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

    function _signPermit(uint256 pk, address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, _usdc.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _usdc.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

}
