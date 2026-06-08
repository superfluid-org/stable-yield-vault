# Stable Yield Vault Glossary

## Periods

**epoch** : the unit of settlement cadence. Each epoch is closed by a `closeEpoch` call (which snapshots and locks the rate) and finalised by a matching `settleEpoch` call. Tracked on-chain as `currentEpoch`; only one epoch can be open at a time.

**era** : the unit of yield-rate cadence. The annualised `stableYieldRate` (basis points) is the rate committed for the current era; the operator can update it at era boundaries via `setStableYieldRate`, which recomputes `_flowRatePerUnit` and recalibrates the GDA flow.

## Assets

**underlying asset** : the ERC-20 token the vault accepts (e.g. USDC). Held in three places at any time: investor wallets, the vault's pending/claimable balance, and the FundManager's unutilized balance.

**yield asset** : the wrapped Superfluid super-token of the underlying (e.g. USDCx). The FundManager holds a reserve of this super-token to fund the GDA flow. Tracked by `yieldAssetsBalance()` (super-token decimals, i.e. 18) and `scaledYieldAssetsBalance()` (rescaled to underlying decimals).

**working assets (WA)** : underlying that has been removed from the FundManager via `take()` and deployed into an external/offchain investment. Reported back at the next `closeEpoch` as the `workingAssets` argument.

**unutilized assets (UA)** : underlying held directly inside the FundManager and not yet deployed. Equals `unutilizedAssetsBalance()`. Available to cover redeem deficits or to be taken out for investment.

**pending deposit assets** : underlying transferred from an investor on `requestDeposit` and custodied by the vault until the request's epoch is settled. Tracked by `totalPendingDepositAssets` (vault-wide) and `_controllerStates[controller].pendingDepositAssets` (per-controller). Not part of NAV.

**claimable redeem assets** : underlying earmarked inside the vault's balance for redeemers whose epoch has settled but who have not yet claimed. Tracked by `totalClaimableRedeemAssets` (vault-wide) and per-controller in `_controllerStates`. The operator has no pathway to touch these.

## Shares

**share** : the ERC-20 token minted by the vault to depositors at claim time, denominated in `1e18`. Freely transferable — the vault's `_update` hook notifies `FundManager.onShareTransfer`, which moves a proportional slice of GDA pool units from sender to receiver so the yield stream tracks share ownership.

**pending redeem shares** : shares transferred from an owner to the vault on `requestRedeem` and locked there until the request's epoch is settled. Tracked by `totalPendingRedeemShares` and `_controllerStates[controller].pendingRedeemShares`.

**unclaimed deposit shares** : shares that have been priced (epoch settled) but not yet minted to the controller. Tracked by `_unclaimedDepositShares`. Added to `effectiveSupply` at the next `closeEpoch` to keep pricing consistent.

**unclaimed redeem shares** : shares still in `totalSupply` whose backing assets have already left NAV at settlement. Tracked by `_unclaimedRedeemShares`. Subtracted from `effectiveSupply` at the next `closeEpoch`.

**effective supply** : `totalSupply() + unclaimedDepositShares − unclaimedRedeemShares`. The denominator used to compute the epoch rate at `closeEpoch`.

**epoch rate / assets-per-share** : the rate locked at `closeEpoch` for the closing epoch, equal to `totalAssets * ASSETS_PER_SHARE_SCALE / effectiveSupply` (or `ASSETS_PER_SHARE_SCALE` if `effectiveSupply == 0`; currently `1e18`). Stored in `_epochRate[epoch]` once settled. Forward pricing — every request in an epoch settles at the same rate.

## Snapshot

**snapshot** : the `{ epoch, depositingAssets, redeemingShares, rate }` struct stored on the vault at `closeEpoch` and consumed by `settleEpoch`. Returned by `getSnapshot()` (used by the FM and by the `canSettleEpoch` view). While `snap.epoch != 0`, deposit/redeem requests revert with `EPOCH_SETTLEMENT_IN_PROGRESS`.

## Streaming / GDA

**GDA Pool** : the Superfluid General Distribution Agreement pool created and owned by the FundManager. Streams the yield super-token to unit holders; not transferable, single-distributor (FM only).

**unit** : a member's share of the pool's total flow. Pool units are denominated in micro-tokens: one whole underlying token maps to `1e6` units. The FM computes units with `_toUnit(amount) = amount / RAW_PER_UNIT`, where `RAW_PER_UNIT = 10 ** (underlyingDecimals - 6)`. Units belong to the FM until claimed at `deposit` / `mint`.

**flow rate per unit** : `_flowRatePerUnit = 1e12 * stableYieldRate / (YEAR * BP_DENOMINATOR)`, recomputed when `stableYieldRate` changes. The `1e12` factor is decimals-independent for supported underlyings because `SCALING_FACTOR * RAW_PER_UNIT == 1e12`.

**total flow rate** : `_flowRatePerUnit * POOL.getTotalUnits()`, set on the pool by `_recalibrateFlow()`.

**guaranteed flow duration** : the minimum forward stream-solvency horizon (in seconds) that the FundManager must maintain. The yield-asset reserve must satisfy `yieldAssetsBalance() >= totalFlowRate * guaranteedFlowDuration`. Floored at `MIN_GUARANTEED_FLOW_DURATION = 1 day`.

**stable yield rate** : the annualised rate committed to per-unit streaming, expressed in basis points (e.g. `100` ↔ 1%). Stored as `stableYieldRate`; updated via `setStableYieldRate`.

**scaling factor** : `SCALING_FACTOR = 10 ** (18 - underlyingDecimals)` — the factor that lifts underlying amounts into the super-token's 18-decimal space. For 6-dec USDC, `SCALING_FACTOR = 10**12`.

**raw per unit** : `RAW_PER_UNIT = 10 ** (underlyingDecimals - 6)` — the number of raw underlying atoms represented by one pool unit. For 6-dec USDC, `RAW_PER_UNIT = 1`; for an 18-dec underlying, `RAW_PER_UNIT = 10**12`.

**rebalance** : `_rebalanceYieldAssets()` — the FM upgrades unutilized underlying into the yield-asset reserve when it is short of `_targetFlowRate * guaranteedFlowDuration`, and downgrades back into underlying when in excess. Called at `settleEpoch` (when there are new deposits), `setStableYieldRate`, `setGuaranteedFlowDuration`, and `ensureYieldFlowDuration`.

## Actors

**investor** : end user. Calls `requestDeposit` / `requestRedeem` and later `deposit` / `mint` / `redeem` / `withdraw` on the vault. Receives the GDA flow once their deposit is claimed.

**controller** (ERC-7540) : the address whose pending and claimable balances are bookkept on the vault. By default the request `owner` is also the controller; an approved ERC-7540 operator can act on the controller's behalf.

**ERC-7540 operator** : a per-controller delegate authorised via `setOperator(operator, true)` to call request/claim entry points on behalf of a controller. Distinct from the *fund operator*.

**fund operator** : EOA/bot holding `FUND_OPERATOR_ROLE` on the FundManager. Responsible for `closeEpoch`, `settleEpoch`, `take`/`give`, `setStableYieldRate`, and `ensureYieldFlowDuration`.

**fund admin** : holder of `DEFAULT_ADMIN_ROLE` on the FundManager. Responsible for `setGuaranteedFlowDuration` and access-control role management.

## Roles

**FUND_OPERATOR_ROLE** : access-control role on the FundManager that gates settlement, capital movement, and yield-rate management.

**DEFAULT_ADMIN_ROLE** : OpenZeppelin admin role on the FundManager; gates `setGuaranteedFlowDuration` and role assignment.

**VAULT_ROLE** : access-control role granted to the vault address at FundManager construction; gates the FM hooks `onRequestRedeem` and `onClaimDeposit`.

## Contracts

**StableYieldAsyncVault** : the ERC-7540 / ERC-7575 / ERC-4626-shaped vault. Custodies pending deposit assets and claimable redeem assets, mints/burns shares at claim time, and exposes the operator-facing `onCloseEpoch` / `onSettleEpoch` hooks (gated by `onlyFundManager`).

**FundManager (FM)** : driver of epoch settlement and GDA streaming. Holds the unutilized underlying and the yield-asset reserve, owns the pool, and exposes the operator-facing entry points (`closeEpoch`, `settleEpoch`, `take`, `give`, `ensureYieldFlowDuration`, `setStableYieldRate`, `setGuaranteedFlowDuration`) and view helpers (`canSettleEpoch`, `evaluateFunding`, `evaluateYieldAssetsDeficit`).

## Sync vault

The synchronous ERC-4626 sibling (`StableYieldSyncVault` + `SyncFundManager`) shares the GDA streaming engine via `FundManagerBase` but drops the entire epoch lifecycle. The FundManager is the sole capital custodian and NAV authority; the stream is pre-funded from each deposit; `totalAssets` is the reserve-inclusive plain sum of recoverable balances; the share floats with the external vault's NAV; and the unified `_rebalanceYieldAssets()` primitive sources from or sinks to the external position on every op. There is no permissionless `harvest()`. See `docs/sync-vault/design.md`. Terms specific to it:

**external vault** : the third-party ERC-4626 (Morpho/Beefy/…) the **FundManager** routes principal into and where the real yield compounds. Immutable `EXTERNAL_VAULT`; its `asset()` must equal the underlying. Its `maxWithdraw(FM)` (the FM is the holder) feeds NAV, the rebalance source, and the withdraw principal leg, so it is trusted (integrate only standard, audited, non-rebasing 4626s).

**reserve-inclusive NAV** : `totalAssets() = EXTERNAL_VAULT.maxWithdraw(FM) + scaledYieldAssetsBalance() + UNDERLYING_ASSET.balanceOf(FM)` — a plain sum of the three recoverable terms (external position + super-token reserve + any raw underlying held by the FM), with no clamp. It is real recoverable value, so external losses pass through immediately and honestly into the share price, and the external surplus is included and accrues to holders as share appreciation. Because a deposit splits `assets` into external principal + super-token reserve (both counted), entry is NAV-neutral; thereafter the share floats. The continuous stream drains the reserve, so NAV ticks slightly between rebalances and recovers at each funded rebalance.

**_rebalanceYieldAssets()** (sync override) : the unified reserve-management primitive. Abstract on `FundManagerBase`; each family implements its own (async upgrades from `unutilizedAssetsBalance()` or reverts; sync sources from or sinks to the external position). The sync implementation: when `deficit > 0`, pull `min(deficit / SCALING_FACTOR + 1, EXTERNAL_VAULT.maxWithdraw(FM))` and `_upgrade` it; when `deficit < 0`, trim best-effort — only if `EXTERNAL_VAULT.maxDeposit(FM) >= underlyingNeeded`, `_downgrade` and redeposit exactly `underlyingNeeded` into the external vault (sub-`SCALING_FACTOR` excess is ignored; otherwise the trim is skipped and retried next call). Best-effort; a residual positive deficit at terminal impairment is tolerated. Runs at the start of `onDeposit`, post-payout in `onWithdraw`, and inside the inherited operator entrypoints `setStableYieldRate`, `setGuaranteedFlowDuration`, `ensureYieldFlowDuration`.

**pre-funded stream** : on every deposit the FM first runs `_rebalanceYieldAssets()` (deficit-only — the external surplus covers the deficit first), then upgrades a residual slice of the incoming underlying (`min(deficit / SCALING_FACTOR + 1, assets)`, 0 if the rebalance cleared it) into the super-token reserve to cover `guaranteedFlowDuration` of the new units' flow (plus the 1% fee leg), so the stream starts at deposit time including the first deposit. Principal funds the stream only transiently and only when the external surplus is insufficient; it is preserved long-run iff external yield ≥ the promised rate (otherwise the loss passes through honestly).

**external surplus** : the compounding external-yield surplus above the promised rate, sitting in the external vault between rebalances. Counted in NAV (part of `maxWithdraw(FM)`) — it accrues to shareholders as share appreciation, not a protocol-owned slice excluded from price. The deficit-only `_rebalanceYieldAssets()` draws from it to top up the super-token reserve, leaving the rest compounding; under impairment the same pull continues deeper into the external position and the loss surfaces directly in the NAV. Never extracted as treasury revenue (the treasury earns only the 1% fee stream).

**floating share** : sync shares are not pegged; they float, priced `totalAssets() / totalSupply` (OZ standard, with a virtual-shares offset). NAV-neutral at entry; thereafter the share appreciates while external yield exceeds the promised rate and declines under impairment (NAV falls). A holder's total return = the external vault's real yield, split into the streamed promised rate + share appreciation for the excess.

**custody hazard invariant** : principal never rests in the FM as raw underlying across calls — it is deployed into the external vault or upgraded into the reserve within the same call; otherwise the base rebalance logic would sweep it into the reserve and silently consume principal. (See `invariants.md` A.2.)

**FundManagerBase** : abstract contract holding the shared Superfluid GDA engine (pools, `_flowRatePerUnit`, `_recalibrateFlow`, `_rebalanceYieldAssets`, `guaranteedFlowDuration`, `setStableYieldRate`, fee pool, scaling, roles, `onShareTransfer`). Extended by `AsyncFundManager` (epoch hooks) and `SyncFundManager`.

**StableYieldSyncVault** : the synchronous ERC-4626 + `ReentrancyGuard` **face**. Holds no assets: pulls underlying from the caller, forwards it to the FM, mints/burns shares, proxies `totalAssets`/`max*` to FM views. Deploys and pins its `SyncFundManager` at construction (`msg.sender == vault`). Overrides `_decimalsOffset()` to `12` for first-deposit-inflation resistance, and pauses all four `max*` under terminal external impairment.

**SyncFundManager** : `FundManagerBase` plus the sole-custodian role — holds `EXTERNAL_VAULT`, the external-vault shares, and the super-token reserve (no principal counter). Implements the abstract `_rebalanceYieldAssets()` with the self-sourcing override (external pull on deficit, downgrade + redeposit on excess). `VAULT_ROLE` hooks: `onDeposit` (grant units → rebalance → pre-fund residual → deploy remainder → recalibrate) and `onWithdraw(holder, shares, totalSharesOwned, supplyBeforeBurn, receiver, redeemingAssets)` (proportional unit decrease → pay from resting raw underlying + a shares-proportional reserve slice + the external vault → post-payout rebalance → recalibrate). No principal-counter step — `redeemingAssets` is OZ's pro-rata `shares · NAV / supply`. No `harvest()` — solvency between user activity is operator-only via the inherited `ensureYieldFlowDuration()`. No `fundReserve` injection path — the sync vault is its own backstop via programmatic `EXTERNAL_VAULT` access (the operator's only sustainability lever is `setStableYieldRate`). `EXTERNAL_VAULT.asset() == underlying` is validated by the vault before the FM is deployed.
