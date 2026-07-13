// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { AsyncVaultTestBase } from "./AsyncVaultTestBase.t.sol";

import { AsyncVaultMacro } from "src/vault/async/AsyncVaultMacro.sol";

import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import { IGeneralDistributionAgreementV1 } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/IGeneralDistributionAgreementV1.sol";
import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";
import { ISuperfluid } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IClearMacroForwarderV1 } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/utils/IClearMacroForwarderV1.sol";

/**
 * @title AsyncVaultMacroTest
 * @notice Unit + integration coverage for {AsyncVaultMacro}: the request-deposit batch shape
 *         (`[setOperator] + requestDepositWithPermit2 + [connectPool]` with both conditional legs),
 *         the single-op request-redeem / claim actions, the clear-signing views, and full runs
 *         through the real Host op-loop (`batchCall`, the same path `forwardBatchCall` uses).
 */
contract AsyncVaultMacroTest is AsyncVaultTestBase {

    using SuperTokenV1Library for ISuperToken;

    AsyncVaultMacro internal _macro;

    bytes32 internal constant LANG_EN = bytes32("en");
    uint256 internal constant USDCX_SEED = 100 ether; // Covers flow recalibration security deposits

    address internal _user;
    uint256 internal _userPk;

    function setUp() public virtual override {
        super.setUp();
        _etchPermit2();
        _macro = new AsyncVaultMacro(_vault);
        _dealUSDCx(address(_fundManager), USDCX_SEED);
        (_user, _userPk) = makeAddrAndKey("macro-user");
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

    /// @dev With an operator requested and a not-yet-connected signer, the request-deposit action
    ///      builds exactly three ops: 302 `setOperator`, 302 `requestDepositWithPermit2`, and a
    ///      201 ctx-wrapped `connectPool`.
    function test_buildOps_requestDeposit_fullShape() public view {
        uint256 assets = 100e6;
        uint256 nonce = 1;
        uint256 deadline = 123;
        address operator = FUND_OPERATOR;
        bytes memory sig = new bytes(65);

        bytes memory params = _macro.encodeRequestDeposit(LANG_EN, assets, operator, nonce, deadline, sig);
        ISuperfluid.Operation[] memory ops = _macro.buildBatchOperations(_sf.host, params, ALICE);

        assertEq(ops.length, 3, "three ops");

        assertEq(uint256(ops[0].operationType), 302, "op0 = ERC2771_FORWARD_CALL");
        assertEq(ops[0].target, address(_vault), "op0 -> vault");
        assertEq(ops[0].data, abi.encodeCall(_vault.setOperator, (operator, true)), "op0 raw setOperator calldata");

        assertEq(uint256(ops[1].operationType), 302, "op1 = ERC2771_FORWARD_CALL");
        assertEq(ops[1].target, address(_vault), "op1 -> vault");
        assertEq(
            ops[1].data,
            abi.encodeCall(_vault.requestDepositWithPermit2, (assets, ALICE, nonce, deadline, sig)),
            "op1 raw requestDepositWithPermit2 calldata (controller == account)"
        );

        IGeneralDistributionAgreementV1 gda = _gda();
        assertEq(uint256(ops[2].operationType), 201, "op2 = SUPERFLUID_CALL_AGREEMENT");
        assertEq(ops[2].target, address(gda), "op2 -> gda");
        assertEq(
            ops[2].data,
            abi.encode(abi.encodeCall(gda.connectPool, (_fundManager.YIELD_POOL(), new bytes(0))), new bytes(0)),
            "op2 wrapped connectPool calldata"
        );
    }

    /// @dev `operator == address(0)` skips the setOperator op.
    function test_buildOps_requestDeposit_skipsZeroOperator() public view {
        bytes memory params = _macro.encodeRequestDeposit(LANG_EN, 100e6, address(0), 1, 123, new bytes(65));
        ISuperfluid.Operation[] memory ops = _macro.buildBatchOperations(_sf.host, params, ALICE);

        assertEq(ops.length, 2, "two ops");
        assertEq(
            ops[0].data,
            abi.encodeCall(_vault.requestDepositWithPermit2, (100e6, ALICE, 1, 123, new bytes(65))),
            "op0 = requestDepositWithPermit2"
        );
        assertEq(uint256(ops[1].operationType), 201, "op1 = connectPool");
    }

    /// @dev An already-connected signer skips the connectPool op.
    function test_buildOps_requestDeposit_skipsConnectWhenConnected() public {
        vm.startPrank(ALICE);
        _usdcx.connectPool(_fundManager.YIELD_POOL());
        vm.stopPrank();

        bytes memory params = _macro.encodeRequestDeposit(LANG_EN, 100e6, FUND_OPERATOR, 1, 123, new bytes(65));
        ISuperfluid.Operation[] memory ops = _macro.buildBatchOperations(_sf.host, params, ALICE);

        assertEq(ops.length, 2, "two ops");
        assertEq(ops[0].data, abi.encodeCall(_vault.setOperator, (FUND_OPERATOR, true)), "op0 = setOperator");
        assertEq(
            ops[1].data,
            abi.encodeCall(_vault.requestDepositWithPermit2, (100e6, ALICE, 1, 123, new bytes(65))),
            "op1 = requestDepositWithPermit2"
        );
    }

    /// @dev Both conditional legs skipped → the batch degenerates to the single Permit2 request op.
    function test_buildOps_requestDeposit_minimalShape() public {
        vm.startPrank(ALICE);
        _usdcx.connectPool(_fundManager.YIELD_POOL());
        vm.stopPrank();

        bytes memory params = _macro.encodeRequestDeposit(LANG_EN, 100e6, address(0), 1, 123, new bytes(65));
        ISuperfluid.Operation[] memory ops = _macro.buildBatchOperations(_sf.host, params, ALICE);

        assertEq(ops.length, 1, "one op");
        assertEq(
            ops[0].data,
            abi.encodeCall(_vault.requestDepositWithPermit2, (100e6, ALICE, 1, 123, new bytes(65))),
            "op0 = requestDepositWithPermit2"
        );
    }

    function test_buildOps_requestRedeem_shape() public view {
        bytes memory params = _macro.encodeRequestRedeem(LANG_EN, 100e18, 123);
        ISuperfluid.Operation[] memory ops = _macro.buildBatchOperations(_sf.host, params, ALICE);

        assertEq(ops.length, 1, "one op");
        assertEq(uint256(ops[0].operationType), 302, "op0 = ERC2771_FORWARD_CALL");
        assertEq(ops[0].target, address(_vault), "op0 -> vault");
        assertEq(
            ops[0].data,
            abi.encodeCall(_vault.requestRedeem, (100e18, ALICE, ALICE)),
            "op0 raw requestRedeem calldata (controller == owner == account)"
        );
    }

    function test_buildOps_deposit_shape() public view {
        bytes memory params = _macro.encodeDeposit(LANG_EN, 100e6, 123);
        ISuperfluid.Operation[] memory ops = _macro.buildBatchOperations(_sf.host, params, ALICE);

        assertEq(ops.length, 1, "one op");
        assertEq(uint256(ops[0].operationType), 302, "op0 = ERC2771_FORWARD_CALL");
        assertEq(ops[0].target, address(_vault), "op0 -> vault");
        assertEq(
            ops[0].data,
            abi.encodeWithSignature("deposit(uint256,address,address)", 100e6, ALICE, ALICE),
            "op0 raw 3-param deposit calldata (receiver == controller == account)"
        );
    }

    function test_buildOps_withdraw_shape() public view {
        bytes memory params = _macro.encodeWithdraw(LANG_EN, 100e6, 123);
        ISuperfluid.Operation[] memory ops = _macro.buildBatchOperations(_sf.host, params, ALICE);

        assertEq(ops.length, 1, "one op");
        assertEq(uint256(ops[0].operationType), 302, "op0 = ERC2771_FORWARD_CALL");
        assertEq(ops[0].target, address(_vault), "op0 -> vault");
        assertEq(
            ops[0].data,
            abi.encodeCall(_vault.withdraw, (100e6, ALICE, ALICE)),
            "op0 raw withdraw calldata (receiver == controller == account)"
        );
    }

    //   _    ___
    //  | |  / (_)__ _      _______
    //  | | / / / _ \ | /| / / ___/
    //  | |/ / /  __/ |/ |/ (__  )
    //  |___/_/\___/|__/|__/____/

    function test_views_primaryTypesAndDefinitions() public view {
        bytes memory p;

        p = _wrapPayload(_macro.encodeRequestDeposit(LANG_EN, 100e6, address(0), 1, 0, new bytes(65)));
        assertEq(_macro.getPrimaryTypeName(p), "AsyncVaultRequestDeposit", "request-deposit primary type");
        assertEq(
            _macro.getActionTypeDefinition(p),
            "Action(string description,uint256 assets,address operator,uint256 nonce,uint256 deadline)",
            "request-deposit typedef"
        );

        p = _wrapPayload(_macro.encodeRequestRedeem(LANG_EN, 100e18, 0));
        assertEq(_macro.getPrimaryTypeName(p), "AsyncVaultRequestRedeem", "request-redeem primary type");
        assertEq(
            _macro.getActionTypeDefinition(p),
            "Action(string description,uint256 shares,uint256 deadline)",
            "request-redeem typedef"
        );

        p = _wrapPayload(_macro.encodeDeposit(LANG_EN, 100e6, 0));
        assertEq(_macro.getPrimaryTypeName(p), "AsyncVaultDeposit", "deposit primary type");
        assertEq(
            _macro.getActionTypeDefinition(p),
            "Action(string description,uint256 assets,uint256 deadline)",
            "deposit typedef"
        );

        p = _wrapPayload(_macro.encodeWithdraw(LANG_EN, 100e6, 0));
        assertEq(_macro.getPrimaryTypeName(p), "AsyncVaultWithdraw", "withdraw primary type");
        assertEq(
            _macro.getActionTypeDefinition(p),
            "Action(string description,uint256 assets,uint256 deadline)",
            "withdraw typedef"
        );
    }

    function test_descriptions_format() public view {
        assertEq(
            _macro.describeRequestDeposit(LANG_EN, 100e6, address(0)),
            "Request a deposit of 100 USDC and connect to the yield pool",
            "request-deposit without operator"
        );
        assertEq(
            _macro.describeRequestDeposit(LANG_EN, 100_500_000, address(0xBEEF)),
            "Request a deposit of 100.500000 USDC, approve operator "
            "0x000000000000000000000000000000000000beef and connect to the yield pool",
            "request-deposit with operator"
        );
        assertEq(
            _macro.describeRequestRedeem(LANG_EN, 1.5e18),
            "Request a redemption of 1.500000000000000000 SYAVS shares",
            "request-redeem"
        );
        assertEq(
            _macro.describeDeposit(LANG_EN, 100e6),
            "Claim vault shares for 100 USDC of settled deposits",
            "claim deposit"
        );
        assertEq(_macro.describeWithdraw(LANG_EN, 1), "Withdraw 0.000001 USDC of settled redemptions", "withdraw");
    }

    function test_descriptions_langGated() public {
        vm.expectRevert(); // UnsupportedLanguage
        _macro.describeRequestDeposit(bytes32("xx"), 100e6, address(0));
        vm.expectRevert(); // UnsupportedLanguage
        _macro.describeRequestRedeem(bytes32("xx"), 100e18);
        vm.expectRevert(); // UnsupportedLanguage
        _macro.describeDeposit(bytes32("xx"), 100e6);
        vm.expectRevert(); // UnsupportedLanguage
        _macro.describeWithdraw(bytes32("xx"), 100e6);
    }

    function test_structHash_isDeterministic() public view {
        bytes memory params = _macro.encodeRequestDeposit(LANG_EN, 100e6, FUND_OPERATOR, 1, 42, new bytes(65));
        assertEq(_macro.getActionStructHash(params), _macro.getActionStructHash(params), "deterministic struct hash");
    }

    /// @dev The Permit2 signature bytes ride along OUTSIDE the EIP-712 action digest (Permit2
    ///      verifies them independently) — differing signatures must not change the struct hash.
    function test_structHash_excludesPermit2Signature() public view {
        bytes memory a = _macro.encodeRequestDeposit(LANG_EN, 100e6, FUND_OPERATOR, 1, 42, new bytes(65));
        bytes memory b = _macro.encodeRequestDeposit(LANG_EN, 100e6, FUND_OPERATOR, 1, 42, bytes("different"));
        assertEq(_macro.getActionStructHash(a), _macro.getActionStructHash(b), "signature-independent struct hash");
    }

    function test_postCheck_requestDeposit_revertsWithoutPending() public {
        bytes memory params = _macro.encodeRequestDeposit(LANG_EN, 100e6, address(0), 1, 0, new bytes(65));
        vm.expectRevert(AsyncVaultMacro.DepositRequestNotRecorded.selector);
        _macro.postCheck(_sf.host, params, makeAddr("nobody"));
    }

    function test_postCheck_deposit_revertsWithoutUnits() public {
        bytes memory params = _macro.encodeDeposit(LANG_EN, 100e6, 0);
        vm.expectRevert(AsyncVaultMacro.PoolUnitsNotGranted.selector);
        _macro.postCheck(_sf.host, params, makeAddr("nobody"));
    }

    //    ____      __                       __  _
    //   /  _/___  / /____  ____ __________ _/ /_(_)___  ____
    //   / // __ \/ __/ _ \/ __ `/ ___/ __ `/ __/ / __ \/ __ \
    // _/ // / / / /_/  __/ /_/ / /  / /_/ / /_/ / /_/ / / / /
    // /___/_/ /_/\__/\___/\__, /_/   \__,_/\__/_/\____/_/ /_/
    //                    /____/

    /// @dev Full request-deposit batch through the real Host op-loop (`batchCall` as the user —
    ///      same execution path `forwardBatchCall` uses): one tx approves the operator, pulls the
    ///      assets via the Permit2 signature, records the request, and connects to the yield pool.
    function test_integration_requestDeposit(uint256 amount) public {
        amount = bound(amount, 1, ONE_BILLION * 1e6);
        address operator = makeAddr("designated-operator");
        _fundForPermit2(_user, amount);

        bytes memory sig = _signPermit2Deposit(_userPk, amount, _user, 1, type(uint256).max);
        bytes memory params = _macro.encodeRequestDeposit(LANG_EN, amount, operator, 1, type(uint256).max, sig);
        ISuperfluid.Operation[] memory ops = _macro.buildBatchOperations(_sf.host, params, _user);

        vm.prank(_user);
        _sf.host.batchCall(ops);

        assertEq(_vault.pendingDepositRequest(0, _user), amount, "pending recorded for the signer");
        assertEq(_usdc.balanceOf(_user), 0, "assets pulled via the Permit2 signature");
        assertEq(_usdc.balanceOf(address(_vault)), amount, "assets escrowed in the vault");
        assertTrue(_vault.isOperator(_user, operator), "operator approved for the signer");
        assertTrue(_gda().isMemberConnected(_fundManager.YIELD_POOL(), _user), "signer connected to the yield pool");

        // The macro's own post-check passes on this end state.
        _macro.postCheck(_sf.host, params, _user);
    }

    /// @dev Full lifecycle through the macro: request deposit → settle → claim shares →
    ///      request redeem → settle → withdraw, each user leg running through the Host op-loop.
    function test_integration_fullLifecycle(uint256 amount) public {
        amount = bound(amount, 1e6, ONE_BILLION * 1e6);
        ISuperfluidPool pool = _fundManager.YIELD_POOL();
        _fundForPermit2(_user, amount);

        // 1. Request deposit (Permit2 pull + connect; no operator).
        bytes memory sig = _signPermit2Deposit(_userPk, amount, _user, 1, type(uint256).max);
        bytes memory params = _macro.encodeRequestDeposit(LANG_EN, amount, address(0), 1, type(uint256).max, sig);
        _macroBatchCallAs(_user, params);

        // 2. Operator settles the epoch.
        _vaultCloseEpoch(_vault.totalSupply() / 1e12);
        _vaultSettleAndGrantUnits();

        // 3. Claim the settled deposit — shares mint and the yield stream starts here.
        params = _macro.encodeDeposit(LANG_EN, amount, type(uint256).max);
        _macroBatchCallAs(_user, params);

        uint256 shares = _vault.balanceOf(_user);
        assertEq(shares, amount * 1e12, "shares minted at the bootstrap rate");
        assertGt(pool.getUnits(_user), 0, "yield units granted at claim");
        _macro.postCheck(_sf.host, params, _user);

        // 4. Request redemption of the full position.
        params = _macro.encodeRequestRedeem(LANG_EN, shares, type(uint256).max);
        _macroBatchCallAs(_user, params);

        assertEq(_vault.pendingRedeemRequest(0, _user), shares, "pending redeem recorded");
        _macro.postCheck(_sf.host, params, _user);

        // 5. Operator settles the redemption epoch.
        _vaultCloseEpoch(_vault.totalSupply() / 1e12);
        _vaultSettleAndGrantUnits();

        // 6. Withdraw the settled proceeds.
        uint256 claimable = _vault.maxWithdraw(_user);
        assertGt(claimable, 0, "settled redemption is claimable");
        params = _macro.encodeWithdraw(LANG_EN, claimable, type(uint256).max);
        _macroBatchCallAs(_user, params);

        assertEq(_usdc.balanceOf(_user), claimable, "proceeds paid to the signer");
        assertEq(_vault.balanceOf(_user), 0, "full position redeemed");
    }

    //    __  __     __
    //   / / / /__  / /___  ___  ___________
    //  / /_/ / _ \/ / __ \/ _ \/ ___/ ___/
    // / __  /  __/ / /_/ /  __/ /  (__  )
    // /_/ /_/\___/_/ .___/\___/_/  /____/
    //             /_/

    /// @dev Build the ops OUTSIDE the prank (the view call would otherwise consume it), then run
    ///      the batch through the Host as `user`.
    function _macroBatchCallAs(address user, bytes memory params) internal {
        ISuperfluid.Operation[] memory ops = _macro.buildBatchOperations(_sf.host, params, user);
        vm.prank(user);
        _sf.host.batchCall(ops);
    }

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

}
