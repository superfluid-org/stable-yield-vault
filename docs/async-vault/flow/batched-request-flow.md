# Async vault — batched (ClearMacro) request & claim flows

The async vault supports gasless / one-signature-per-action relaying through a Superfluid
**ClearMacro** (`src/vault/async/AsyncVaultMacro.sol`), mirroring the sync vault's
`SyncVaultMacro` (see `docs/sync-vault/flow/batched-deposit-flow.md` for the shared
forwarder/EIP-2771 mechanics). Two vault-side capabilities enable it:

1. **EIP-2771 awareness** — `StableYieldAsyncVault is ERC2771Context`, trusting the Host's
   `ERC2771Forwarder` (`host.getERC2771Forwarder()`; `forward2771Call` is `onlyOwner` = Host, so
   the appended sender is always the Host-authenticated batch signer). All user entry points
   (`requestDeposit`, `requestRedeem`, the four claims, `setOperator`) resolve the caller via
   `_msgSender()`.
2. **Permit2-funded deposit requests** — `requestDepositWithPermit2(assets, controller, nonce,
   deadline, signature)` pulls the escrow via a Permit2 `permitWitnessTransferFrom` instead of a
   prior ERC-20 approval:
   - the permit is constructed **by the vault** from its own parameters (`token = underlying`,
     `amount = assets`, `spender = vault`), so a signature cannot be redirected to another token,
     amount, or spender;
   - the Permit2 **owner is `_msgSender()`** — only the signer (directly or through the trusted
     forwarder) can consume their own permit;
   - the **witness** (`depositWitness(controller)`, type
     `AsyncVaultDepositWitness(address controller)`) pins the credited controller into the
     signature;
   - the pull lands directly in the vault's escrow and then runs the exact same accounting tail as
     `requestDeposit` (`_recordDepositRequest`).

## Macro actions

| Action | Ops (in order) | Conditional legs |
|---|---|---|
| `RequestDeposit` | 302 `setOperator(operator, true)` · 302 `requestDepositWithPermit2` · 201 `connectPool` | `setOperator` skipped when `operator == 0`; `connectPool` skipped when the signer is already connected |
| `RequestRedeem` | 302 `requestRedeem(shares, signer, signer)` | — |
| `Deposit` (claim) | 302 `deposit(assets, signer, signer)` | — |
| `Withdraw` (claim) | 302 `withdraw(assets, signer, signer)` | — |

All type-302 ops execute against the vault with the signer appended per ERC-2771; the 201 op runs
`connectPool` as the signer through the Host. Post-checks: request-deposit asserts the pending
request, the operator approval, and the pool connection; claim-deposit asserts pool units were
granted (units — and the stream — start at claim per design decision D2, so connecting at request
time is a persistent no-op until then).

## Signature model (request-deposit)

Two signatures, mirroring the sync macro's `permit + payload` pair:

1. **Permit2 signature** over `PermitWitnessTransferFrom(TokenPermissions permitted,address
   spender,uint256 nonce,uint256 deadline,AsyncVaultDepositWitness witness)` with
   `witness = keccak256(abi.encode(keccak256("AsyncVaultDepositWitness(address controller)"),
   controller))` — authorizes the funds movement. Consumed (nonce burned) inside the vault call.
2. **ClearMacro payload signature** (EIP-712, verified by `ClearMacroForwarderV1.runMacro`) over
   `Action(string description,uint256 assets,address operator,uint256 nonce,uint256 deadline)` +
   the forwarder's `Security` struct — authorizes the batch. The Permit2 signature bytes ride
   along in the action params **outside** this digest (like the sync macro's EIP-2612 `v,r,s`):
   they carry no independent authority, since Permit2 verifies them against the same signer, and
   any substitution either is the same signature or fails verification.

## Caveats

- Relayed requests revert with `EPOCH_SETTLEMENT_IN_PROGRESS` during a close→settle window; a
  relayer should expect to retry after settlement.
- `requestDepositWithPermit2` intentionally has **no operator path** (the caller is always the
  Permit2 owner); operators can still relay plain `requestDeposit` after an ERC-20 approval.
- The claim amounts in the `Deposit` / `Withdraw` actions are signed ahead of execution; if the
  user's claimable balance changed (e.g. a partial earlier claim), the op reverts rather than
  claiming a different amount.
