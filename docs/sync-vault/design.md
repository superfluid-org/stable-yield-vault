# Stable Yield Sync Vault — Design

A synchronous ERC-4626 vault that pays a **stable, streamed yield**. Users deposit
and withdraw instantly. Their principal is routed into an external ERC-4626 vault
(Morpho, Beefy, …) where it earns the real market yield; a smooth promised yield is
paid to them out-of-band as a Superfluid stream.

It is the synchronous sibling of `StableYieldAsyncVault`. Both share one Superfluid
streaming engine (`FundManagerBase`); this vault drops the async epoch lifecycle
entirely.

This document covers the **model, the design decisions, the contracts, and the
security considerations**. For the property catalogue see
[`invariants.md`](./invariants.md); for step-by-step operation walk-throughs see
[`flow/deposit-flow.md`](./flow/deposit-flow.md) and
[`flow/withdraw-flow.md`](./flow/withdraw-flow.md).

---

## The model

A holder gets two things from a deposit:

1. **A streamed yield** at the operator's promised rate (the *stable* part). The
   stream is paid in a super-token (e.g. USDCx) from a reserve the FundManager holds,
   and is sized to the **principal the holder contributed**.
2. **A floating share** in the external vault's real performance. The share is a
   standard ERC-4626 share priced at `totalAssets / totalSupply`. It rises when the
   external vault out-earns the promised rate and falls when it under-earns.

A holder's **total return** is therefore the external vault's real yield, delivered as
the promised stream **plus** share-price appreciation for the excess
(`external − promised`). The two are not double-counted: the stream is funded by
pulling assets out of the external position, which lowers the share price by exactly
the streamed amount, and the appreciation is whatever is left over.

> *Alice deposits 100 USDC at a 5% promised rate. Over one year she receives 5 USDCx
> as a stream. If the external vault earned 10%, her shares are worth 105 USDC when she
> exits.*

### Who holds what

The **FundManager** is the sole custodian of all capital and the only authority on
value:

- the external-vault shares (the deployed principal),
- the super-token reserve that funds the stream,
- the GDA pool that streams the yield.

The **vault** holds no assets. It is a thin ERC-4626 face: it pulls underlying from the
caller, forwards it to the FundManager, mints/burns shares, and reads its `totalAssets`
and limits from FundManager views.

### NAV (net asset value)

```
totalAssets = EXTERNAL_VAULT.maxWithdraw(FM)   // recoverable from the external position
            + scaledYieldAssetsBalance()        // the super-token reserve, in underlying terms
            + UNDERLYING_ASSET.balanceOf(FM)     // any raw underlying held by the FM
```

It is a **plain sum of what the FundManager can recover**, with no clamp and no
smoothing. Consequences:

- A deposit only changes the *form* of the FM's assets (underlying → external shares +
  reserve), so it is **NAV-neutral**: the share price is unchanged at entry.
- The external surplus is included, so it accrues to holders as share appreciation.
- A loss in the external vault shows up **immediately and honestly** in the share
  price. There is no buffer to absorb it — that is the trade for giving holders the
  upside.

NAV reads the external vault's price live, so the external vault must have a
**monotonic, non-manipulable share price** (see [Security](#security-considerations)).

### The stream

The stream is **pre-funded from each deposit**. On deposit the FundManager:

1. tops up the reserve from the external position if it is short, then
2. upgrades a small slice of the incoming deposit into the reserve to cover the new
   holder's promised yield for the `guaranteedFlowDuration` horizon, then
3. deploys the rest of the deposit into the external vault, and
4. (re)starts the stream.

So the stream starts at deposit time, including for the very first deposit. Between
deposits the reserve is replenished from the external position on every user
operation, and by the operator's `ensureYieldFlowDuration()` during quiet periods.

The stream keeps paying at the promised rate as long as the external position has
anything left to pull (`EXTERNAL_VAULT.maxWithdraw(FM) > 0`). It only stops at
**terminal impairment** (`== 0`), at which point the vault pauses (see below).

---

## Design decisions

| # | Decision | Choice |
|---|---|---|
| 1 | **Share / loss model** | Floating ERC-4626 share, priced `totalAssets / totalSupply` (no clamp, no peg). Total return = streamed promised rate + appreciation for `external − promised`. Losses pass through immediately and honestly. |
| 2 | **Surplus handling** | The external surplus stays compounding in the external vault and is counted in NAV (it belongs to shareholders). Rebalances pull only the reserve *deficit*, never the whole surplus. |
| 3 | **Rate model** | Operator sets a promised `stableYieldRate` (basis points), same as the async vault. |
| 4 | **Stream funding** | Pre-funded from each deposit, then replenished from the external position on every op. No on-chain operator subsidy. |
| 5 | **Withdraw sourcing** | The payout is the share's pro-rata of NAV (`shares · NAV / supply`). It is sourced first from any resting raw underlying, then a shares-proportional slice of the reserve, then the external vault. |
| 6 | **Reserve upkeep** | Operator-only via the inherited `ensureYieldFlowDuration()`. There is no permissionless `harvest()`. |
| 7 | **Code reuse** | The Superfluid streaming engine is the shared abstract `FundManagerBase`. |
| 8 | **Trust model** | Operator + ERC-4626 views; no rate cap, no settle gate. The only sustainability lever is `setStableYieldRate`. There is no `fundReserve` injection — the external vault is the vault's own backstop. |
| 9 | **Custody** | The FundManager is the sole custodian and NAV authority; the vault holds nothing. |
| 10 | **First-deposit inflation** | Mitigated by OZ virtual shares: `_decimalsOffset()` returns a hardcoded `12`. |
| 11 | **Capital custody hazard** | Principal never rests in the FundManager as raw underlying across calls. |

---

## Contracts

### `StableYieldSyncVault` — the share/accounting face

OpenZeppelin `ERC4626` + `ReentrancyGuard`. Holds no assets. Read this contract first;
the FundManager is meaningless in isolation.

- **Constructor.** Validates `externalVault.asset() == asset()` (reverts
  `EXTERNAL_ASSET_MISMATCH`), then deploys and pins its `SyncFundManager`
  (`msg.sender == vault`, no factory or proxy).
- **`totalAssets()`** delegates to `FUND_MANAGER.totalManagedAssets()` (the NAV above).
- **`_decimalsOffset()`** returns `12`, giving 18-decimal shares for the 6-decimal USDC
  deployment and a `10 ** 12` first-deposit-inflation attack-cost multiplier. Revisit
  this value for a non-6-decimal underlying.
- **`_deposit`** pulls underlying from the caller straight to the FundManager, mints
  shares, then calls `FUND_MANAGER.onDeposit(receiver, assets)`.
- **`_withdraw`** spends the allowance, snapshots the owner's balance and total supply
  *before* the burn, burns the shares, then calls
  `FUND_MANAGER.onWithdraw(owner, shares, totalSharesOwned, supplyBeforeBurn, receiver, assets)`.
  CEI ordering: vault state is fully updated before the FM touches external contracts.
- **`_update`** calls `FUND_MANAGER.onShareTransfer(from, to, value)` on
  shareholder-to-shareholder transfers (skipping mint/burn legs) so the yield stream
  follows the shares.
- **Limits.** `maxDeposit`/`maxMint` are capped by the external vault's own deposit
  limit (`FUND_MANAGER.maxExternalDeposit()`). `maxWithdraw`/`maxRedeem` are capped by
  the NAV (`FUND_MANAGER.totalManagedAssets()`). All four are forced to `0` under
  terminal impairment (see below).
- **`deposit`/`mint`/`withdraw`/`redeem`** are `nonReentrant`. `preview*` functions
  use the OZ defaults and work synchronously — they do **not** revert (unlike the async
  vault).

#### Terminal-impairment pause

When the external position cannot be recovered at all
(`EXTERNAL_VAULT.maxWithdraw(FM) == 0`) **and there are shares outstanding**
(`totalSupply() > 0`), `_isExternallyPaused()` forces all four `max*` to `0`, so OZ
reverts every deposit/mint/withdraw/redeem with `ERC4626ExceededMax*`. The stream keeps
paying existing holders from the reserve until it is naturally liquidated.

The gate keys on `totalSupply() > 0` — "are there depositors to protect?" — rather than
on the FM's external share balance:

- **An empty vault is never paused**, so the first deposit always works.
- A dust external-share donation cannot force a false pause.
- A total loss (whether the external's price goes to zero or it burns the FM's shares)
  pauses consistently.

`maxWithdraw(FM) == 0` does not distinguish a permanent loss from a temporary freeze;
both pause. If permanent, the remaining reserve simply streams out to holders.

### `SyncFundManager` — the capital custodian

Extends `FundManagerBase`. Holds the immutable `EXTERNAL_VAULT`, the external-vault
shares, and the super-token reserve. There is no principal counter — NAV is read
directly off recoverable balances.

**`onDeposit(receiver, assets)`** (`VAULT_ROLE`):

1. Grant `_toUnit(assets)` GDA units to the receiver (skipped if a sub-unit dust deposit
   maps to 0 units).
2. `_rebalanceYieldAssets()` — clear any pre-existing reserve deficit from the external
   position.
3. Pre-fund the residual: if a deficit remains, upgrade
   `min(deficit / SCALING_FACTOR + 1, assets)` of the incoming underlying into the
   reserve.
4. Deposit the remainder into the external vault. Nothing is left at rest in the FM.
5. `_recalibrateFlow()` — start/raise the stream.

**`onWithdraw(holder, shares, totalSharesOwned, supplyBeforeBurn, receiver, redeemingAssets)`**
(`VAULT_ROLE`). Reverts `BAD_WITHDRAW_ARGS` if `totalSharesOwned == 0` or
`shares > totalSharesOwned`.

1. Decrease the holder's GDA units proportionally to the shares burned
   (`ceil(holderUnits · shares / totalSharesOwned)`; a full exit zeros them). A
   zero-unit dust position is skipped, not reverted.
2. Pay `redeemingAssets` to the receiver, sourced in priority order:
   - any **resting raw underlying** (only ever a donation — see custody hazard), spent
     first;
   - a **shares-proportional reserve slice**,
     `fromReserve = ceil(scaledYieldAssetsBalance() · shares / supplyBeforeBurn)`,
     clamped at `redeemingAssets`, downgraded from the super-token reserve;
   - the **external vault** for the remainder.
3. `_rebalanceYieldAssets()` — restore the reserve to target for the reduced unit count.
4. `_recalibrateFlow()` — the flow rate decreases (units went down), which releases GDA
   buffer and never reverts from a drained reserve.

There is no principal-counter step: `redeemingAssets` is OZ's `shares · NAV / supply`
(floor), so the burn removes exactly the redeemer's pro-rata slice and the share price
is unchanged for the holders who stay.

**`_rebalanceYieldAssets()`** (the override of the abstract base hook) brings the reserve
to the forward-solvency target by moving value through the external vault:

- **Reserve below target** (`deficit > 0`): pull
  `min(deficit / SCALING_FACTOR + 1, EXTERNAL_VAULT.maxWithdraw(FM))` out of the external
  position and upgrade it. Only the *deficit* is pulled, so the surplus keeps
  compounding. The pull is capped at `maxWithdraw(FM)`, so a compliant external never
  reverts it — it can never brick the calling op.
- **Reserve above target** (`deficit < 0`): trim the excess back into the external
  vault, **best-effort**. Sub-`SCALING_FACTOR` excess is ignored. Otherwise, only if
  `EXTERNAL_VAULT.maxDeposit(FM) >= underlyingNeeded`, downgrade and redeposit
  **exactly** `underlyingNeeded` (not `balanceOf(FM)` — that would sweep any in-flight
  raw underlying mid-call). If the external will not accept the deposit, skip the trim
  entirely; the excess stays as above-target reserve slack and the next rebalance
  retries.

**Views the vault proxies:** `totalManagedAssets()` (the NAV), `maxExternalDeposit()`
(`EXTERNAL_VAULT.maxDeposit(FM)`), `maxExternalVaultWithdraw()`
(`EXTERNAL_VAULT.maxWithdraw(FM)`), plus the `EXTERNAL_VAULT` getter.

### `FundManagerBase` — the shared streaming engine

The abstract Superfluid GDA engine shared with the async vault: the super-token reserve,
the yield and fee GDA pools, the operator-committed `stableYieldRate`, the
`guaranteedFlowDuration` horizon, and the rebalance/recalibrate machinery. Key members:

- **Stream sizing.** `_flowRatePerUnit = 1e12 · stableYieldRate / (YEAR · BP_DENOMINATOR)`;
  total flow = `_flowRatePerUnit · YIELD_POOL.getTotalUnits()`. A 1% fee leg streams to
  the treasury in parallel.
- **Units.** `_toUnit(assets) = assets / RAW_PER_UNIT`. One whole token maps to `1e6`
  units, so units are sized to the **nominal underlying contributed**.
- **Reserve target.** `evaluateYieldAssetsDeficit()` reports
  `targetFlowRate · guaranteedFlowDuration − yieldAssetsBalance()` (plus the fee leg).
- **`_rebalanceYieldAssets()` is abstract** — each family supplies its own; the sync
  override is described above.
- **Operator setters** (`setStableYieldRate`, `setGuaranteedFlowDuration`,
  `ensureYieldFlowDuration`) each rebalance and recalibrate the flow.
- **Config guard.** The constructor and both operator setters enforce
  `rate · duration ≤ YEAR · BP_DENOMINATOR` (reverts
  `INVALID_YIELD_DURATION_COMBINATION`), so a single deposit can always afford to
  pre-fund its own promised horizon.
- **`onShareTransfer`** moves a shares-proportional slice of GDA units from sender to
  receiver. A zero-unit sender is skipped (so dust shares stay transferable).

### External vault

The third-party ERC-4626 (Morpho, Beefy, …) that custodies the principal and earns the
real yield. Its `asset()` must equal the underlying. It is **trusted**: its
`maxWithdraw(FM)` feeds NAV, the rebalance source, and the withdraw principal leg.
Integrate only standard, audited, non-rebasing 4626s.

---

## Security considerations

- **NAV reads the external price live — deployment requirement.**
  `totalManagedAssets()` reads `EXTERNAL_VAULT.maxWithdraw(FM)` with no TWAP or clamp,
  so the share price tracks the external vault's valuation within a single block. The
  external ERC-4626 **must have a monotonic, non-manipulable share price** —
  interest-accrual priced (Aave, Morpho, Compound-style), **not** spot/AMM/oracle-priced
  and **not** donation-inflatable. Pairing the vault with a spot-priced external
  re-opens a NAV-manipulation sandwich on every deposit/withdraw. There is no code fix:
  a clamp would reintroduce exactly the ≈1:1 behaviour the floating share removed.

- **First-deposit inflation.** The classic ERC-4626 attack (seed the empty vault, donate
  to inflate the price per share, round the victim's deposit to zero shares). Mitigated
  by OZ virtual shares via `_decimalsOffset() = 12`: the attacker must donate ~`10 ** 12`
  times the victim's deposit and forfeit roughly half of it to the unowned virtual
  shares. For a non-6-decimal underlying the offset must be revisited.

- **Donations are harmless.** A super-token or raw-underlying transfer to the FM raises
  NAV and the share price — but only for existing holders, so the donor strictly loses.
  It is an irrational gift, not an attack. A raw-underlying donation is realized first on
  the next withdrawal (it is counted in NAV and reaches holders rather than being
  stranded).

- **Share price ticks between rebalances.** The stream continuously drains the reserve,
  so NAV decays slightly between rebalances and recovers at each funded one. Timing/MEV
  around the rebalance cadence is bounded by per-op rebalancing, virtual shares,
  vault-favourable rounding, and `nonReentrant`. The operator should call
  `ensureYieldFlowDuration()` during quiet periods to keep the drift small.

- **Loss is signalled by share price, not by liveness.** Under-earning does not stall
  the stream; it shows up as the share price drifting below the entry price as the
  rebalance draws deeper into the external position. Off-chain monitoring should watch
  `convertToAssets(1 share)`, not the flow rate. The only "stream stopped" state is
  terminal impairment.

- **External deposits closed.** If the external vault rejects deposits while still
  servicing withdrawals, the rebalance trim is skipped and the reserve sits above target
  until deposits reopen. This is safe (above-target slack just funds the stream for
  longer). A non-compliant external whose `deposit` reverts despite reporting
  `maxDeposit > 0` would still brick the calling op — an accepted limitation of trusting
  the external's `maxDeposit`.

- **Rate above sustainable yield.** The reserve replenisher draws deeper into the
  external position and the loss passes to the share price honestly. The stream only
  stalls at terminal impairment. The operator's only lever is `setStableYieldRate`;
  `setStableYieldRate(0)` always succeeds (a zero flow needs no reserve).

- **Reentrancy.** `nonReentrant` on `deposit`/`mint`/`withdraw`/`redeem`; CEI ordering;
  the value-bearing FM hooks (`onDeposit`/`onWithdraw`) are reachable only from the
  pinned vault via `VAULT_ROLE`.

- **Decimals.** Supported underlying decimals are `[6, 18]`. The hard-coded
  `1e12 = SCALING_FACTOR · RAW_PER_UNIT` and the share offset assume the 6-decimal USDC
  deployment; a non-6-decimal underlying needs the offset and scaling revisited.

---

## Out of scope (vs the async vault)

The entire epoch lifecycle is dropped: `requestDeposit`/`requestRedeem`, the snapshot,
`closeEpoch`/`settleEpoch`, the effective-supply correction, `canSettleEpoch`, the
ERC-7540/7575 interfaces and operators, and the `take`/`give` off-chain capital movement
(the external ERC-4626 replaces that leg). The async settlement *netting* is not dropped
— it reappears synchronously inside `onDeposit`/`onWithdraw`.
