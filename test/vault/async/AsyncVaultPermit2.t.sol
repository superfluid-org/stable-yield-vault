// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { AsyncVaultTestBase } from "./AsyncVaultTestBase.t.sol";

import { IStableYieldAsyncVault } from "src/interfaces/vault/async/IStableYieldAsyncVault.sol";

/**
 * @title AsyncVaultPermit2Test
 * @notice Covers `requestDepositWithPermit2` — the Permit2 `SignatureTransfer` deposit-request
 *         entry: the caller's signature (spender = vault, witness = `depositWitness(controller)`)
 *         is the only authorization, so no prior ERC-20 approval of the vault is needed. Verifies
 *         the happy path, the witness/spender/owner bindings, replay protection, and parity with
 *         the plain `requestDeposit` lifecycle.
 */
contract AsyncVaultPermit2Test is AsyncVaultTestBase {

    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );

    uint256 internal constant USDCX_SEED = 100 ether; // Covers flow recalibration security deposits

    address internal _user;
    uint256 internal _userPk;

    function setUp() public override {
        super.setUp();
        _etchPermit2();
        _dealUSDCx(address(_fundManager), USDCX_SEED);
        (_user, _userPk) = makeAddrAndKey("permit2-user");
    }

    function test_requestDepositWithPermit2_happyPath(uint256 amount) public {
        amount = bound(amount, 1, ONE_BILLION * 1e6);
        _fundForPermit2(_user, amount);

        bytes memory sig = _signPermit2Deposit(_userPk, amount, _user, 1, type(uint256).max);

        vm.expectEmit(true, true, true, true, address(_vault));
        emit DepositRequest(_user, _user, 0, _user, amount);

        vm.prank(_user);
        uint256 requestId = _vault.requestDepositWithPermit2(amount, _user, 1, type(uint256).max, sig);

        assertEq(requestId, 0, "requestId is always 0");
        assertEq(_vault.pendingDepositRequest(0, _user), amount, "pending recorded");
        assertEq(_vault.totalPendingDepositAssets(), amount, "total pending recorded");
        assertEq(_usdc.balanceOf(_user), 0, "assets pulled from the signer");
        assertEq(_usdc.balanceOf(address(_vault)), amount, "assets escrowed in the vault");
    }

    /// @dev The witness binds the controller but does not force `controller == owner`: a signer can
    ///      credit a third-party controller, mirroring `requestDeposit(assets, controller, owner)`.
    function test_requestDepositWithPermit2_thirdPartyController(uint256 amount) public {
        amount = bound(amount, 1, ONE_BILLION * 1e6);
        _fundForPermit2(_user, amount);

        bytes memory sig = _signPermit2Deposit(_userPk, amount, BOB, 7, type(uint256).max);

        vm.prank(_user);
        _vault.requestDepositWithPermit2(amount, BOB, 7, type(uint256).max, sig);

        assertEq(_vault.pendingDepositRequest(0, BOB), amount, "pending credited to the witnessed controller");
        assertEq(_vault.pendingDepositRequest(0, _user), 0, "nothing credited to the signer");
        assertEq(_usdc.balanceOf(_user), 0, "assets pulled from the signer");
    }

    /// @dev Full parity with the plain requestDeposit lifecycle: settle then claim mints shares.
    function test_requestDepositWithPermit2_fullLifecycle(uint256 amount) public {
        amount = bound(amount, 1, ONE_BILLION * 1e6);
        _fundForPermit2(_user, amount);

        bytes memory sig = _signPermit2Deposit(_userPk, amount, _user, 1, type(uint256).max);
        vm.prank(_user);
        _vault.requestDepositWithPermit2(amount, _user, 1, type(uint256).max, sig);

        _vaultCloseEpoch(_vault.totalSupply() / 1e12);
        _vaultSettleAndGrantUnits();

        vm.prank(_user);
        _vault.deposit(amount, _user);

        assertEq(_vault.balanceOf(_user), amount * 1e12, "shares minted at the bootstrap rate");
        assertGt(_fundManager.YIELD_POOL().getUnits(_user), 0, "yield units granted at claim");
    }

    function test_requestDepositWithPermit2_revertsOnZeroAssets() public {
        vm.prank(_user);
        vm.expectRevert(IStableYieldAsyncVault.INVALID_PARAMETERS.selector);
        _vault.requestDepositWithPermit2(0, _user, 1, type(uint256).max, new bytes(65));
    }

    function test_requestDepositWithPermit2_revertsWhenEpochSettlementInProgress(uint256 amount) public {
        amount = bound(amount, 1, ONE_BILLION * 1e6);
        _fundForPermit2(_user, amount);
        bytes memory sig = _signPermit2Deposit(_userPk, amount, _user, 1, type(uint256).max);

        // Open a snapshot (close without settle) — requests must be rejected in this window.
        _vaultCloseEpoch(0);

        vm.prank(_user);
        vm.expectRevert(IStableYieldAsyncVault.EPOCH_SETTLEMENT_IN_PROGRESS.selector);
        _vault.requestDepositWithPermit2(amount, _user, 1, type(uint256).max, sig);
    }

    /// @dev The Permit2 nonce is consumed on use: replaying the same signature reverts in Permit2.
    function test_requestDepositWithPermit2_revertsOnReplay(uint256 amount) public {
        amount = bound(amount, 1, (ONE_BILLION / 2) * 1e6);
        _fundForPermit2(_user, amount * 2);
        bytes memory sig = _signPermit2Deposit(_userPk, amount, _user, 1, type(uint256).max);

        vm.prank(_user);
        _vault.requestDepositWithPermit2(amount, _user, 1, type(uint256).max, sig);

        vm.prank(_user);
        vm.expectRevert(); // Permit2: InvalidNonce
        _vault.requestDepositWithPermit2(amount, _user, 1, type(uint256).max, sig);
    }

    /// @dev The witness pins the controller: submitting the signature with a different controller
    ///      changes the witness and invalidates the signature.
    function test_requestDepositWithPermit2_revertsOnControllerMismatch(uint256 amount) public {
        amount = bound(amount, 1, ONE_BILLION * 1e6);
        _fundForPermit2(_user, amount);
        bytes memory sig = _signPermit2Deposit(_userPk, amount, _user, 1, type(uint256).max);

        vm.prank(_user);
        vm.expectRevert(); // Permit2: InvalidSigner (witness mismatch)
        _vault.requestDepositWithPermit2(amount, BOB, 1, type(uint256).max, sig);
    }

    /// @dev The vault constructs the permitted amount from `assets`: submitting a different amount
    ///      than the signed one invalidates the signature.
    function test_requestDepositWithPermit2_revertsOnAmountMismatch(uint256 amount) public {
        amount = bound(amount, 2, ONE_BILLION * 1e6);
        _fundForPermit2(_user, amount);
        bytes memory sig = _signPermit2Deposit(_userPk, amount, _user, 1, type(uint256).max);

        vm.prank(_user);
        vm.expectRevert(); // Permit2: InvalidSigner (TokenPermissions mismatch)
        _vault.requestDepositWithPermit2(amount - 1, _user, 1, type(uint256).max, sig);
    }

    /// @dev Only the signer can consume their permit: the vault resolves the Permit2 `owner` from
    ///      `_msgSender()`, so a third party relaying the raw signature fails verification.
    function test_requestDepositWithPermit2_revertsForNonSignerCaller(uint256 amount) public {
        amount = bound(amount, 1, ONE_BILLION * 1e6);
        _fundForPermit2(_user, amount);
        bytes memory sig = _signPermit2Deposit(_userPk, amount, _user, 1, type(uint256).max);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(); // Permit2: InvalidSigner (owner = attacker, signature by _user)
        _vault.requestDepositWithPermit2(amount, _user, 1, type(uint256).max, sig);

        assertEq(_usdc.balanceOf(_user), amount, "signer untouched");
    }

    function test_requestDepositWithPermit2_revertsOnExpiredDeadline(uint256 amount) public {
        amount = bound(amount, 1, ONE_BILLION * 1e6);
        _fundForPermit2(_user, amount);
        uint256 deadline = block.timestamp;
        bytes memory sig = _signPermit2Deposit(_userPk, amount, _user, 1, deadline);

        vm.warp(block.timestamp + 1);

        vm.prank(_user);
        vm.expectRevert(); // Permit2: SignatureExpired
        _vault.requestDepositWithPermit2(amount, _user, 1, deadline, sig);
    }

    /// @dev Two requests in the same epoch aggregate, each consuming its own nonce.
    function test_requestDepositWithPermit2_aggregatesWithinEpoch(uint256 amount) public {
        amount = bound(amount, 1, (ONE_BILLION / 2) * 1e6);
        _fundForPermit2(_user, amount * 2);

        vm.startPrank(_user);
        _vault.requestDepositWithPermit2(
            amount, _user, 1, type(uint256).max, _signPermit2Deposit(_userPk, amount, _user, 1, type(uint256).max)
        );
        _vault.requestDepositWithPermit2(
            amount, _user, 2, type(uint256).max, _signPermit2Deposit(_userPk, amount, _user, 2, type(uint256).max)
        );
        vm.stopPrank();

        assertEq(_vault.pendingDepositRequest(0, _user), amount * 2, "requests aggregated");
    }

}
