# Integration guide

For developers building a front-end, a bot, or a contract on top of a Stable Yield Vault.
It covers what you call, in which order, what to expect back, and how to surface the yield
stream to users. For the *why*, read [`architecture.md`](./architecture.md).

Contents

1. [The 60-second model](#1-the-60-second-model)
2. [Addresses and ABIs](#2-addresses-and-abis)
3. [Receiving the yield stream (both families)](#3-receiving-the-yield-stream-both-families)
4. [Sync vault — `StableYieldSyncVault`](#4-sync-vault--stableyieldsyncvault)
5. [Async vault — `StableYieldAsyncVault`](#5-async-vault--stableyieldasyncvault)
6. [Gasless / one-signature UX — the ClearMacros](#6-gasless--one-signature-ux--the-clearmacros)
7. [Reading state for a dashboard](#7-reading-state-for-a-dashboard)
8. [Error catalogue](#8-error-catalogue)
9. [Events](#9-events)
10. [Deploying your own instance](#10-deploying-your-own-instance)

---

## 1. The 60-second model

- A user deposits the **underlying** (a 6-decimal stablecoin, USDC) and receives **shares**
  (18 decimals).
- From that moment the user's balance of the **yield asset** — the Superfluid super-token
  wrapping the underlying, USDCx — grows continuously at the vault's promised annual rate
  (`stableYieldRate`, basis points), proportionally to the principal they deposited.
- The stream is delivered through a Superfluid **GDA pool** owned by the vault's
  **FundManager**. The user must be *connected* to that pool for the stream to show in their
  balance (§3).
- Exiting burns shares and pays out underlying. In the sync vault the share price floats with
  the external yield source; in the async vault it is locked per epoch.

Every vault is a pair: the **vault** (share token + user entry points) and its **FundManager**
(capital custody, streaming). The vault deploys the FundManager in its constructor and exposes
it as `FUND_MANAGER()`. You will mostly talk to the vault, and read a few views on the FM.

## 2. Addresses and ABIs

Live addresses: [`deployments.md`](./deployments.md). ABIs come out of `forge build`
(`out/<Contract>.sol/<Contract>.json`); the interfaces you want are:

| Contract | Interface |
|---|---|
| `StableYieldSyncVault` | `src/interfaces/vault/sync/IStableYieldSyncVault.sol` (+ OZ `IERC4626`) |
| `SyncFundManager` | `src/interfaces/vault/sync/ISyncFundManager.sol` (+ `IFundManagerBase`) |
| `StableYieldAsyncVault` | `src/interfaces/vault/async/IStableYieldAsyncVault.sol` (+ `IERC7540Deposit/Redeem/Operator`, `IERC7575`) |
| `AsyncFundManager` | `src/interfaces/vault/async/IAsyncFundManager.sol` (+ `IFundManagerBase`) |
| `SyncVaultMacro` / `AsyncVaultMacro` | the contracts themselves (`src/vault/{sync,async}/*Macro.sol`) |
| GDA pool | Superfluid `ISuperfluidPool` |

Discover everything else from the vault:

```solidity
IStableYieldSyncVault vault = IStableYieldSyncVault(VAULT);
IERC20         usdc  = IERC20(vault.asset());
ISyncFundManager fm  = vault.FUND_MANAGER();
ISuperToken    usdcx = fm.YIELD_ASSET();
ISuperfluidPool pool = fm.YIELD_POOL();
```

## 3. Receiving the yield stream (both families)

The FundManager streams USDCx into `YIELD_POOL`; each shareholder holds pool **units** equal to
the underlying atoms they contributed (`1 USDC = 1e6 units`). Superfluid semantics that matter
to you:

- **Connected members** see the stream in `usdcx.balanceOf(user)` in real time.
- **Non-connected members** still earn: the amount accrues as *claimable* inside the pool
  (`pool.getClaimable(user, uint32(block.timestamp))`) and lands in their balance when they
  connect or call `pool.claimAll()`.
- Connecting is a one-time, per-user, per-pool action. It must be signed by the user (or done
  for them through a macro — §6).

Connect with the canonical **GDAv1Forwarder** (deployed on every Superfluid network; address on
the [Superfluid protocol addresses page](https://docs.superfluid.org/docs/protocol/contract-addresses)):

```solidity
IGDAv1Forwarder(GDA_FORWARDER).connectPool(pool, "");        // msg.sender connects
bool ok = IGDAv1Forwarder(GDA_FORWARDER).isMemberConnected(pool, user);
```

Or through the Host (what the macros do): `host.callAgreement(gda, abi.encodeCall(gda.connectPool, (pool, "")), "")`.

Read a user's stream:

```solidity
uint128 units   = pool.getUnits(user);            // == underlying atoms of principal contributed
int96   perSec  = pool.getMemberFlowRate(user);   // USDCx (18-dec) per second
// annualised, for display:  perSec * 365 days / 1e18  ≈ units/1e6 * stableYieldRate/10_000
```

USDCx is a plain ERC-20 super-token: users can hold it, transfer it, stream it onward, or
`usdcx.downgrade(amount)` back to USDC at any time.

**Share transfers move the stream.** Transferring vault shares moves a proportional slice of the
sender's pool units to the receiver (`onShareTransfer`), so the yield follows the shares. The
receiver still needs to connect to the pool to see it in their balance.

## 4. Sync vault — `StableYieldSyncVault`

Standard ERC-4626 with three vault-specific behaviours: a flat entry fee, a binary
`maxDeposit`, and an automatic pause tied to the external yield source (Morpho Vault V2).

### 4.1 Deposit

```solidity
uint256 assets = 100e6;                                // 100 USDC, GROSS (fee-inclusive)
require(vault.maxDeposit(user) > 0, "deposits closed"); // binary: max or 0
uint256 sharesOut = vault.previewDeposit(assets);       // includes the fee
usdc.approve(address(vault), assets);
uint256 shares = vault.deposit(assets, user);           // shares minted on assets - DEPOSIT_FEE
```

- `DEPOSIT_FEE()` = `0.2e6` (0.2 USDC) is skimmed from `assets` and sent to `TREASURY()`. Reverts
  `DEPOSIT_BELOW_FEE` if `assets <= DEPOSIT_FEE`. `mint(shares, receiver)` charges the fee *on top*
  of the assets needed for `shares` (`previewMint` includes it).
- `depositWithPermit(assets, receiver, deadline, v, r, s)` folds an EIP-2612 permit for `assets`
  in front of the same path (front-run-tolerant: a permit that was already consumed is ignored
  and the existing allowance is used).
- The stream starts **in the same transaction** — units are granted, the reserve is pre-funded
  from the deposit, and the GDA flow is recalibrated. The user just needs to be connected (§3).
- Very small deposits onto an empty reserve cannot fund the GDA buffer and revert; in practice
  deposit at least a few USDC.

### 4.2 Withdraw / redeem

```solidity
uint256 maxA = vault.maxWithdraw(user);   // 0 under the external pause
uint256 maxS = vault.maxRedeem(user);
vault.withdraw(assets, receiver, owner);  // burns ceil(assets → shares)
vault.redeem(shares, receiver, owner);    // pays floor(shares → assets)
```

- Payout = the shares' pro-rata of NAV (`shares · totalAssets / totalSupply`, floor). No exit fee.
- Units are decreased proportionally, so the remaining stream matches the remaining shares.
- `maxWithdraw` / `maxRedeem` are capped by the FundManager's NAV — the position's **value**, not
  Morpho's instant liquidity (Morpho V2 has no liquidity view). A withdrawal within `max*` can
  still revert at the external leg during a liquidity crunch; retry later or surface "external
  liquidity temporarily unavailable" to the user.
- Withdrawals remain open after the admin `terminate()`s the vault (only deposits close).

### 4.3 `max*` and pauses

| State | `maxDeposit` / `maxMint` | `maxWithdraw` / `maxRedeem` | Cause |
|---|---|---|---|
| Normal | `type(uint256).max` | NAV-capped | — |
| `terminated() == true` | `0` (`deposit` reverts `VAULT_TERMINATED`) | NAV-capped | Admin closed the deposit leg for good |
| Morpho deposit gates block the FM | `0` | NAV-capped | `FUND_MANAGER.canDepositExternal() == false` |
| **External pause** | `0` | `0` | `totalSupply() > 0 && (externalPositionValue() == 0 \|\| !canWithdrawExternal())` — total loss or Morpho exit gates blocking the FM |

A curator-set Morpho gate that *reverts* makes the `can*External` views — and therefore the
vault's `max*` — revert too (accepted). `preview*` never revert and include the fee.

### 4.4 Share price

`totalAssets()` = external position value (`EXTERNAL_VAULT.previewRedeem(balanceOf(FM))`) +
USDCx reserve (scaled to 6 dec) + any raw USDC in the FM. There is no clamp: the share
appreciates while Morpho earns more than the promised rate and declines under impairment. The
price ticks down slightly between rebalances (the stream drains the reserve) and recovers at each
one. Display `convertToAssets(1e18)` as the price.

## 5. Async vault — `StableYieldAsyncVault`

ERC-7540: deposits and redeems are **requests** that the operator prices and settles per epoch,
then the user **claims**. The single request id is always `0` (fungible requests per
controller). `previewDeposit/Mint/Redeem/Withdraw` **revert** — use the request views instead.

Roles in a request: `owner` (who supplies assets/shares), `controller` (whose pending/claimable
balances are credited; usually the same address), and optionally an ERC-7540 **operator**
approved by the controller via `setOperator(operator, true)` to act on their behalf.

### 5.1 Deposit lifecycle

```solidity
// 1. request
usdc.approve(address(vault), assets);
vault.requestDeposit(assets, controller, owner);         // assets escrowed in the vault
uint256 pending = vault.pendingDepositRequest(0, controller);

// 2. wait: the operator runs closeEpoch() then settleEpoch() — poll
uint256 claimable = vault.claimableDepositRequest(0, controller);   // > 0 once settled

// 3. claim (any amount up to claimable; shares priced at the epoch's locked rate)
uint256 shares = vault.deposit(claimable, receiver, controller);     // or mint(shares, receiver, controller)
```

- Requests revert `EPOCH_SETTLEMENT_IN_PROGRESS` while an epoch is closed but not yet settled
  (between `closeEpoch` and `settleEpoch`). Check `vault.getSnapshot().epoch == 0` before
  submitting, or retry.
- **Shares are minted, and the yield stream starts, at claim time** — not at settlement.
  Prompt users to claim (or claim for them through a macro / operator).
- `requestDepositWithPermit2(assets, controller, nonce, deadline, signature)` pulls the escrow via
  a Uniswap Permit2 `permitWitnessTransferFrom` instead of a prior approval. The vault builds the
  permit itself (`token = asset()`, `amount = assets`, `spender = vault`, `owner = caller`) and the
  witness is `depositWitness(controller)` (typed by `DEPOSIT_WITNESS_TYPE_STRING()`), so the
  signature cannot be redirected. See
  [`async-vault/flow/batched-request-flow.md`](./async-vault/flow/batched-request-flow.md) for
  the exact typed-data layout.

### 5.2 Redeem lifecycle

```solidity
// 1. request — shares are pulled from `owner` into the vault; the stream stops for those shares now
vault.requestRedeem(shares, controller, owner);
uint256 pendingS = vault.pendingRedeemRequest(0, controller);

// 2. wait for settlement
uint256 claimableS = vault.claimableRedeemRequest(0, controller);

// 3. claim underlying at the epoch's locked rate
vault.redeem(claimableS, receiver, controller);            // or withdraw(assets, receiver, controller)
```

`maxWithdraw(controller)` / `maxRedeem(controller)` return the claimable amounts.

### 5.3 Pricing

- The epoch rate (assets per share) is locked at `closeEpoch` from
  `NAV = workingAssets + unutilizedAssetsBalance() + scaledYieldAssetsBalance()` over an
  *effective supply* that corrects for settled-but-unclaimed shares. It is computed with OZ-style
  virtual shares (`VIRTUAL_SHARES = 1e12`), so the bootstrap rate is 1 USDC atom = `1e12` share
  atoms (1 USDC = 1e18 shares) and first-deposit inflation is not profitable.
- `convertToShares` / `convertToAssets` use the **last settled** rate — good for display, not a
  quote for a request in flight.
- `currentEpoch()`, `isEpochSettled(epoch)`, `getSnapshot()` expose the lifecycle; the
  `EpochClosed` / `EpochSettled` events are the things to index.

## 6. Gasless / one-signature UX — the ClearMacros

Each vault ships a stateless Superfluid **ClearMacro** that lets a user authorise a whole batch
(permit → deposit → connect to the pool) with **one EIP-712 signature**, submitted by any relayer
through Superfluid's Clear macro forwarder. The vault sees the *user* as the caller because both
vaults are `ERC2771Context` contracts trusting the Superfluid Host's forwarder.

| Macro | Actions | Notes |
|---|---|---|
| `SyncVaultMacro` | `DepositAndConnect` (EIP-2612 permit + `depositWithPermit` + `connectPool`), `Redeem` | The permit `v, r, s` ride in the action params; `assets` is gross |
| `AsyncVaultMacro` | `RequestDeposit` (Permit2 witness pull + optional `setOperator` + `connectPool`), `RequestRedeem`, `Deposit` (claim), `Withdraw` (claim) | `RequestDeposit` needs **two** signatures: the Permit2 witness signature and the Clear payload signature |

Flow (relayer or front-end):

```solidity
// 1. build the action params with the macro's encode* helper
bytes memory actionParams = syncMacro.encodeDepositAndConnect(bytes32("en"), assets, deadline, v, r, s);

// 2. wrap them with the security envelope and get the digest the user signs
IClearMacroForwarderV1.Security memory sec = IClearMacroForwarderV1.Security({
    domain: "...", macroContract: address(syncMacro), provider: "...",
    validAfter: 0, validBefore: block.timestamp + 1 hours, nonce: forwarder.getNonce(user, 0)
});
bytes memory payload = forwarder.encodeParams(actionParams, sec);
bytes32 digest = forwarder.getDigest(syncMacro, payload);   // user signs this (EIP-712)

// 3. anyone submits
forwarder.runMacro(syncMacro, payload, user, signature);
```

The wallet prompt shows the string returned by the matching `describe*` helper (e.g.
`describeDepositAndConnect(lang, assets)`); its hash is bound into the digest, so your UI must
reproduce it byte-for-byte in the typed data. Only `bytes32("en")` is supported as `lang`. The
`deadline` inside redeem / claim actions is display-only; use `Security.validBefore` for an
enforced expiry. Full op-by-op detail:
[`sync-vault/flow/batched-deposit-flow.md`](./sync-vault/flow/batched-deposit-flow.md),
[`async-vault/flow/batched-request-flow.md`](./async-vault/flow/batched-request-flow.md).

## 7. Reading state for a dashboard

| What | Where |
|---|---|
| Promised APR (bps) | `FUND_MANAGER.stableYieldRate()` |
| Forward-solvency horizon (s) | `FUND_MANAGER.guaranteedFlowDuration()` |
| Reserve health | `FUND_MANAGER.evaluateYieldAssetsDeficit()` (`> 0` ⇒ under-reserved), `yieldAssetsBalance()` |
| Total stream | `YIELD_POOL.getTotalUnits()`, `YIELD_ASSET.getFlowRate` / pool flow via the GDA |
| Sync NAV / price | `vault.totalAssets()`, `vault.convertToAssets(1e18)`, `FUND_MANAGER.externalPositionValue()` |
| Sync pause state | `vault.maxDeposit(x) == 0`, `vault.maxWithdraw(x) == 0`, `vault.terminated()`, `FUND_MANAGER.canDepositExternal()` / `canWithdrawExternal()` |
| Async epoch state | `vault.currentEpoch()`, `vault.getSnapshot()` (non-zero `epoch` ⇒ settlement in progress), `FUND_MANAGER.canSettleEpoch()` |
| Async request state | `pendingDepositRequest`, `claimableDepositRequest`, `pendingRedeemRequest`, `claimableRedeemRequest` (request id `0`) |
| Per-user stream | `YIELD_POOL.getUnits(user)`, `getMemberFlowRate(user)`, `getClaimable(user, now)`, `GDAv1Forwarder.isMemberConnected(pool, user)` |
| Fees | `FUND_MANAGER.FEE_BPS()` (1 % of the yield flow, streamed to `TREASURY()` in parallel); sync `vault.DEPOSIT_FEE()` |

## 8. Error catalogue

| Error | Thrown by | Meaning / what to do |
|---|---|---|
| `DEPOSIT_BELOW_FEE()` | sync `deposit` / `depositWithPermit` | `assets <= DEPOSIT_FEE`; deposit more |
| `VAULT_TERMINATED()` | sync `deposit` / `mint` | Admin closed deposits permanently; withdrawals still work |
| `NOT_ADMIN()` | sync `terminate` | Caller lacks the FM's `DEFAULT_ADMIN_ROLE` |
| `ERC4626ExceededMaxDeposit/Mint/Withdraw/Redeem` (OZ) | sync entry points | Amount above `max*` — usually a pause (see §4.3) or an over-withdraw |
| `EXTERNAL_ASSET_MISMATCH()` / `INVALID_CONFIGURATION()` | constructors | External vault's `asset()` ≠ underlying / underlying is not 6-dec |
| `EPOCH_SETTLEMENT_IN_PROGRESS()` | async requests | An epoch is closed but not settled; retry after `settleEpoch` |
| `NOTHING_TO_CLAIM()` | async claims | No claimable request for that controller |
| `INVALID_CALLER()` | async | Caller is neither the controller nor an approved operator |
| `INVALID_PARAMETERS()` | async | Zero amounts, zero addresses, amount above claimable |
| `NOT_SUPPORTED_BY_ASYNC_VAULT()` | async `preview*`, 2-arg `deposit/mint/redeem/withdraw` | Use the request/claim flow and the 3-arg claim overloads |
| `PREVIOUS_EPOCH_NOT_SETTLED()` / `NO_EPOCH_TO_SETTLE()` | async operator hooks | Lifecycle ordering |
| `SETTLEMENT_PRECONDITIONS_NOT_MET(string reason)` | `AsyncFundManager.settleEpoch` | See `canSettleEpoch()` for the reason |
| `INSUFFICIENT_UNUTILIZED_ASSETS()` | `AsyncFundManager.take` / rebalance | FM lacks free underlying |
| `BAD_REDEEM_ARGS()` / `BAD_WITHDRAW_ARGS()` | FM hooks | Internal consistency guard (shares > owned, zero units) |
| `DURATION_BELOW_FLOOR()` | `setGuaranteedFlowDuration` | Below `MIN_GUARANTEED_FLOW_DURATION` (1 day) |
| `INVALID_YIELD_DURATION_COMBINATION()` | constructor / setters | `rate × duration > YEAR × 10_000` |
| `ASSET_MISMATCH()` / `UNSUPPORTED_DECIMALS()` / `ZERO_ADDRESS()` | FM constructor | Super-token doesn't wrap the underlying / decimals ∉ [6, 18] / zero treasury |
| `UnsupportedLanguage`, `PoolUnitsNotGranted`, `PoolNotConnected`, `DepositRequestNotRecorded`, `RedeemRequestNotRecorded`, `OperatorNotSet` | macros (`postCheck`) | The batch did not produce the expected end state; the whole relayed tx reverts |

## 9. Events

- Vault (sync): OZ `Deposit` / `Withdraw` / `Transfer`, `Terminated()`.
- Vault (async): ERC-7540 `DepositRequest` / `RedeemRequest`, `OperatorSet`, OZ `Deposit` /
  `Withdraw`, `EpochClosed(epoch, totalAssets, effectiveSupply, assetsPerShare)`,
  `EpochSettled(...)`.
- FundManager (both): `StableYieldRateChanged`, `GuaranteedFlowDurationChanged`,
  `YieldAssetsRebalanced`, `PoolFlowUpdated(yieldFlowRate, feeFlowRate, totalUnits)`,
  `ShareTransferProcessed`, `EmergencyWithdraw`; async-only `Gave` / `Took`.
- Superfluid: pool `MemberUnitsUpdated`, GDA `FlowDistributionUpdated`, `PoolConnectionUpdated`.

## 10. Deploying your own instance

See [`deployment.md`](./deployment.md). Constructor parameters, for reference:

| Param | Sync | Async | Meaning |
|---|---|---|---|
| `_treasury` | ✓ | ✓ | Receives the 1 % fee stream, `emergencyWithdraw` rescues, and (sync) `DEPOSIT_FEE` |
| `_underlyingAsset` | ✓ | ✓ | ERC-20 with **exactly 6 decimals** (`INVALID_CONFIGURATION` otherwise) |
| `_yieldAsset` | ✓ | ✓ | Superfluid super-token wrapping the underlying (`getUnderlyingToken()` must match); also supplies the Host → trusted forwarder |
| `_externalVault` | ✓ | — | Morpho Vault V2 (ERC-4626, `asset()` must match) |
| `_fundOperator` | ✓ | ✓ | Granted `FUND_OPERATOR_ROLE` |
| `_fundAdmin` | ✓ | ✓ | Granted `DEFAULT_ADMIN_ROLE` — use a multisig / timelock |
| `_initialStableYieldRate` | ✓ | ✓ | Promised APR in basis points (`300` = 3 %) |
| `_initialGuaranteedFlowDuration` | ✓ | ✓ | Forward-solvency horizon in seconds (≥ 1 day; `rate × duration ≤ YEAR × 10_000`) |
| `name`, `symbol` | ✓ | ✓ | Share token metadata |

The FundManager is deployed **by** the vault (it pins `VAULT = msg.sender`); never deploy one
standalone. The macros take the vault address as their only constructor argument.
