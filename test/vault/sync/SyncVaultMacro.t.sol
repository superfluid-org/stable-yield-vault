// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { SyncVaultTestBase } from "./SyncVaultTestBase.t.sol";
import { SyncVaultMacro } from "src/vault/sync/SyncVaultMacro.sol";

import { IGeneralDistributionAgreementV1 } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/IGeneralDistributionAgreementV1.sol";
import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";
import { ISuperfluid } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IClearMacroForwarderV1 } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/utils/IClearMacroForwarderV1.sol";

/**
 * @title SyncVaultMacroTest
 * @notice Unit + integration coverage for {SyncVaultMacro}: the deposit-and-connect 2-op batch shape
 *         (`depositWithPermit` via ERC-2771 + `connectPool`), the single-op redeem, the clear-signing
 *         views, and full runs through the real Host op-loop (`batchCall`, the same path
 *         `forwardBatchCall` uses). See `docs/sync-vault/plan/eip2771-batched-deposit.md`.
 */
contract SyncVaultMacroTest is SyncVaultTestBase {

    SyncVaultMacro internal _macro;

    bytes32 internal constant LANG_EN = bytes32("en");
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public virtual override {
        super.setUp();
        _macro = new SyncVaultMacro(_vault);
    }

    //    __  __      _ __
    //   / / / /___  (_) /_
    //  / / / / __ \/ / __/
    // / /_/ / / / / / /_
    // \____/_/ /_/_/\__/

    function test_macro_pinsVaultAndPool() public view {
        assertEq(address(_macro.VAULT()), address(_vault), "vault pinned");
        assertEq(address(_macro.POOL()), address(_fundManager.YIELD_POOL()), "pool pinned");
    }

    /// @dev The action builds exactly two ops: a 302 `depositWithPermit` to the vault (raw calldata,
    ///      sender appended by the forwarder) and a 201 `connectPool` to the GDA (ctx-wrapped).
    function test_buildOps_shape() public view {
        uint256 assets = 100e6;
        uint256 deadline = 123;
        uint8 v = 27;
        bytes32 r = bytes32(uint256(1));
        bytes32 s = bytes32(uint256(2));

        bytes memory params = _macro.encodeDepositAndConnect(LANG_EN, assets, deadline, v, r, s);
        ISuperfluid.Operation[] memory ops = _macro.buildBatchOperations(_sf.host, params, ALICE);

        assertEq(ops.length, 2, "two ops");

        // Op0 — ERC2771_FORWARD_CALL (302) → vault, raw `depositWithPermit` calldata.
        assertEq(uint256(ops[0].operationType), 302, "op0 = ERC2771_FORWARD_CALL");
        assertEq(ops[0].target, address(_vault), "op0 -> vault");
        assertEq(
            ops[0].data,
            abi.encodeCall(_vault.depositWithPermit, (assets, ALICE, deadline, v, r, s)),
            "op0 raw depositWithPermit calldata (receiver == account)"
        );

        // Op1 — SUPERFLUID_CALL_AGREEMENT (201) → GDA, ctx-wrapped `connectPool`.
        IGeneralDistributionAgreementV1 gda = _gda();
        assertEq(uint256(ops[1].operationType), 201, "op1 = SUPERFLUID_CALL_AGREEMENT");
        assertEq(ops[1].target, address(gda), "op1 -> gda");
        assertEq(
            ops[1].data,
            abi.encode(abi.encodeCall(gda.connectPool, (_fundManager.YIELD_POOL(), new bytes(0))), new bytes(0)),
            "op1 wrapped connectPool calldata"
        );
    }

    function test_views_primaryTypeAndDefinition() public view {
        bytes memory encodedPayload =
            _wrapPayload(_macro.encodeDepositAndConnect(LANG_EN, 100e6, 0, 0, bytes32(0), bytes32(0)));
        assertEq(_macro.getPrimaryTypeName(encodedPayload), "SyncVaultDepositAndConnect", "primary type name");
        assertEq(
            _macro.getActionTypeDefinition(encodedPayload),
            "Action(string description,uint256 assets,uint256 deadline)",
            "action type definition"
        );
    }

    function test_description_nonEmpty_and_langGated() public {
        assertGt(bytes(_macro.describeDepositAndConnect(LANG_EN, 100e6)).length, 0, "non-empty description");
        vm.expectRevert(); // UnsupportedLanguage
        _macro.describeDepositAndConnect(bytes32("xx"), 100e6);
    }

    function test_description_formatsDecimals() public view {
        // 6-dec USDC: whole amount renders without a fractional part.
        assertEq(
            _macro.describeDepositAndConnect(LANG_EN, 100e6),
            "Deposit 100 USDC (incl. fee) and connect to the yield pool",
            "whole amount"
        );
        // Fractional amount renders with left-padded fraction, trailing zeros preserved.
        assertEq(
            _macro.describeDepositAndConnect(LANG_EN, 100_500_000),
            "Deposit 100.500000 USDC (incl. fee) and connect to the yield pool",
            "fractional amount"
        );
        // Sub-unit amount renders a zero integer part with left-padded fraction.
        assertEq(
            _macro.describeDepositAndConnect(LANG_EN, 1),
            "Deposit 0.000001 USDC (incl. fee) and connect to the yield pool",
            "single atom"
        );
    }

    function test_structHash_isDeterministic() public view {
        bytes memory params = _macro.encodeDepositAndConnect(LANG_EN, 100e6, 42, 1, bytes32(0), bytes32(0));
        assertEq(_macro.getActionStructHash(params), _macro.getActionStructHash(params), "deterministic struct hash");
    }

    function test_postCheck_revertsWithoutUnits() public {
        bytes memory params = _macro.encodeDepositAndConnect(LANG_EN, 100e6, 0, 0, bytes32(0), bytes32(0));
        vm.expectRevert(SyncVaultMacro.PoolUnitsNotGranted.selector);
        _macro.postCheck(_sf.host, params, makeAddr("nobody"));
    }

    //    ____      __                       __  _
    //   /  _/___  / /____  ____ __________ _/ /_(_)___  ____
    //   / // __ \/ __/ _ \/ __ `/ ___/ __ `/ __/ / __ \/ __ \
    // _/ // / / / /_/  __/ /_/ / /  / /_/ / /_/ / /_/ / / / /
    // /___/_/ /_/\__/\___/\__, /_/   \__,_/\__/_/\____/_/ /_/
    //                    /____/

    /// @dev Full batch through the real Host op-loop (`batchCall` as the user — same execution path
    ///      `forwardBatchCall` uses): one tx does permit + deposit + connect, with the deposit pulling
    ///      from / minting to the user via ERC-2771 and the connect run as the user.
    function test_integration_depositAndConnect(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        (address user, uint256 pk) = makeAddrAndKey("macro-user");
        uint256 fee = _vault.DEPOSIT_FEE();
        uint256 gross = amount + fee;
        _dealUSDC(user, gross); // fund only — the permit grants the allowance

        uint256 deadline = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, user, address(_vault), gross, deadline);

        bytes memory params = _macro.encodeDepositAndConnect(LANG_EN, gross, deadline, v, r, s);
        ISuperfluid.Operation[] memory ops = _macro.buildBatchOperations(_sf.host, params, user);

        ISuperfluidPool pool = _fundManager.YIELD_POOL();
        uint256 treasuryBefore = _usdc.balanceOf(TREASURY);

        vm.prank(user);
        _sf.host.batchCall(ops);

        assertEq(_vault.balanceOf(user), amount * 1e12, "shares minted to user on net principal");
        assertEq(_usdc.balanceOf(user), 0, "gross pulled via the permit allowance");
        assertEq(_usdc.balanceOf(TREASURY) - treasuryBefore, fee, "flat fee to treasury");
        assertGt(pool.getUnits(user), 0, "yield units granted to user");
        assertTrue(_gda().isMemberConnected(pool, user), "user connected to the yield pool");
    }

    //    ____           __                    __  _ __
    //   / __ \___  ____/ /__  ___  ____ ___  / /_(_) /_
    //  / /_/ / _ \/ __  / _ \/ _ \/ __ `__ \/ __/ / __ \
    // / _, _/  __/ /_/ /  __/  __/ / / / / / /_/ / / / /
    ///_/ |_|\___/\__,_/\___/\___/_/ /_/ /_/\__/_/_/ /_/

    /// @dev The redeem action builds exactly one op: a 302 `redeem(shares, signer, signer)` to the
    ///      vault (raw calldata, sender appended by the forwarder). No permit, no connect op.
    function test_buildOps_redeem_shape() public view {
        uint256 shares = 100e18;
        uint256 deadline = 123;

        bytes memory params = _macro.encodeRedeem(LANG_EN, shares, deadline);
        ISuperfluid.Operation[] memory ops = _macro.buildBatchOperations(_sf.host, params, ALICE);

        assertEq(ops.length, 1, "one op");
        assertEq(uint256(ops[0].operationType), 302, "op0 = ERC2771_FORWARD_CALL");
        assertEq(ops[0].target, address(_vault), "op0 -> vault");
        assertEq(
            ops[0].data,
            abi.encodeCall(_vault.redeem, (shares, ALICE, ALICE)),
            "op0 raw redeem calldata (receiver == owner == account)"
        );
    }

    function test_views_redeem_primaryTypeAndDefinition() public view {
        bytes memory encodedPayload = _wrapPayload(_macro.encodeRedeem(LANG_EN, 100e18, 0));
        assertEq(_macro.getPrimaryTypeName(encodedPayload), "SyncVaultRedeem", "primary type name");
        assertEq(
            _macro.getActionTypeDefinition(encodedPayload),
            "Action(string description,uint256 shares,uint256 deadline)",
            "action type definition"
        );
    }

    function test_describeRedeem_nonEmpty_and_langGated() public {
        assertGt(bytes(_macro.describeRedeem(LANG_EN, 100e18)).length, 0, "non-empty description");
        vm.expectRevert(); // UnsupportedLanguage
        _macro.describeRedeem(bytes32("xx"), 100e18);
    }

    function test_describeRedeem_formatsDecimals() public view {
        // 18-dec shares: whole amount renders without a fractional part.
        assertEq(_macro.describeRedeem(LANG_EN, 100e18), "Redeem 100 SYSVS shares", "whole amount");
        // Fractional amount renders with left-padded fraction, trailing zeros preserved.
        assertEq(_macro.describeRedeem(LANG_EN, 1.5e18), "Redeem 1.500000000000000000 SYSVS shares", "fractional");
    }

    function test_structHash_redeem_isDeterministic() public view {
        bytes memory params = _macro.encodeRedeem(LANG_EN, 100e18, 42);
        assertEq(_macro.getActionStructHash(params), _macro.getActionStructHash(params), "deterministic struct hash");
    }

    /// @dev Full redeem through the real Host op-loop (`batchCall` as the user — same path
    ///      `forwardBatchCall` uses): the forwarder appends the user, so the vault burns the user's own
    ///      shares (no allowance) and pays the proceeds back to the user.
    function test_integration_redeem(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        address user = makeAddr("redeem-user");
        uint256 shares = _deposit(user, amount);

        // `maxRedeem` (≤ owned shares; capped by the recoverable NAV, a few dust atoms below the
        // balance right after deposit) is the largest immediately-redeemable amount.
        uint256 toRedeem = _vault.maxRedeem(user);

        bytes memory params = _macro.encodeRedeem(LANG_EN, toRedeem, type(uint256).max);
        ISuperfluid.Operation[] memory ops = _macro.buildBatchOperations(_sf.host, params, user);

        uint256 usdcBefore = _usdc.balanceOf(user);
        uint128 unitsBefore = _fundManager.YIELD_POOL().getUnits(user);

        vm.prank(user);
        _sf.host.batchCall(ops);

        assertEq(_vault.balanceOf(user), shares - toRedeem, "exactly the redeemed shares burned");
        assertGt(_usdc.balanceOf(user) - usdcBefore, 0, "proceeds paid to user");
        assertLt(_fundManager.YIELD_POOL().getUnits(user), unitsBefore, "yield units reduced");
    }

    //    __  __     __
    //   / / / /__  / /___  ___  ___________
    //  / /_/ / _ \/ / __ \/ _ \/ ___/ ___/
    // / __  /  __/ / /_/ /  __/ /  (__  )
    // /_/ /_/\___/_/ .___/\___/_/  /____/
    //             /_/

    function _gda() internal view returns (IGeneralDistributionAgreementV1) {
        return IGeneralDistributionAgreementV1(
            address(
                _sf.host.getAgreementClass(
                    keccak256("org.superfluid-finance.agreements.GeneralDistributionAgreement.v1")
                )
            )
        );
    }

    function _wrapPayload(bytes memory actionParams) internal pure returns (bytes memory) {
        IClearMacroForwarderV1.Payload memory p;
        p.action.params = actionParams;
        return abi.encode(p);
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
