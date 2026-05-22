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

The synchronous ERC-4626 sibling (`StableYieldVault` + `SyncFundManager`) shares the GDA streaming engine via `FundManagerBase` but drops the entire epoch lifecycle. **Revised 2026-05-22 (unified rebalance primitive):** the FundManager is the sole capital custodian and NAV authority, the stream is pre-funded from each deposit, `totalAssets` is reserve-inclusive (clamp folds super-token AND raw-underlying donations symmetrically), and the unified `_rebalanceYieldAssets()` primitive sources from / sinks to the external position on every op (per-op + operator `ensureYieldFlowDuration()`). No permissionless `harvest()`. See `docs/sync-vault/design.md §Revision 2026-05-22`. Terms specific to it:

**external vault** : the third-party ERC-4626 (Morpho/Beefy/…) the **FundManager** routes principal into and where the real yield compounds. Immutable `EXTERNAL_VAULT`; its `asset()` must equal the underlying. Its `maxWithdraw(FM)` (the FM is the holder) feeds the NAV floor, the rebalance source, and the withdraw principal leg, so it is trusted (integrate only standard, audited, non-rebasing 4626s).

**trackedPrincipal** : explicit **FM-owned** storage counter of net deposited principal. `+= assets` on deposit (in `onDeposit`); `-= trackedPrincipal · sharesBurned / totalSupplyBeforeBurn` (floor) on withdraw (in `onWithdraw`). Forms the NAV floor `min(trackedPrincipal, EXTERNAL_VAULT.maxWithdraw(FM))` — the on-chain honest analog of the async vault's operator-reported `workingAssets`.

**reserve-inclusive NAV** : `totalAssets() = min(trackedPrincipal, EXTERNAL_VAULT.maxWithdraw(FM) + scaledYieldAssetsBalance() + UNDERLYING_ASSET.balanceOf(FM))`. All three recoverable terms (external position + super-token reserve + raw underlying transiently held by the FM) live INSIDE the clamp. The `min(…)` excludes the compounding external buffer **and every donation path** (super-token OR raw underlying transferred to the FM) from share price — donation-resistant by construction in the solvent state. Under impairment the clamp goes the other way (clamped at the lower recoverable) and the share takes the loss honestly. Because a deposit splits `assets` into external principal + super-token reserve (both counted in recoverable), entry is NAV-neutral and the share is ≈1:1. The continuous stream drains the reserve so NAV ticks slightly below par between rebalances (by the GDA buffer slice) and recovers at each funded rebalance — the async forward-priced property, now continuously observable.

**_rebalanceYieldAssets()** (sync override) : the unified reserve-management primitive. Abstract on `FundManagerBase`; each family implements its own (async upgrades from `unutilizedAssetsBalance()` or reverts; sync sources from / sinks to the external position). The sync impl: when `deficit > 0` pull `min(need, EXTERNAL_VAULT.maxWithdraw(FM))` and `_upgrade`; when `deficit < 0` `_downgrade(excess)` and redeposit underlying into the external vault. Best-effort; residual positive deficit at terminal impairment is tolerated (callers guard their `_recalibrateFlow()`). Runs at the start of every deposit/withdraw, at the end of every withdraw (post-payout trim of residual freed excess), and inside the inherited operator entrypoints `setStableYieldRate`, `setGuaranteedFlowDuration`, `ensureYieldFlowDuration`.

**pre-funded stream** : on every deposit the FM first runs `_replenishReserveFromBuffer()` (the buffer covers the deficit first), then upgrades a residual slice of the incoming underlying (`min(ceil(deficit/SCALING_FACTOR)+1, assets)`, 0 if the buffer cleared it) into the super-token reserve to cover `guaranteedFlowDuration` of the new units' flow (+ the 1% fee leg), so the stream starts at deposit time including the first deposit. Principal funds the stream only transiently and only when the buffer is insufficient; it is preserved long-run iff external yield ≥ the promised rate (else honest pass-through). Replaces the original "stream never draws principal" model.

**buffer** : the compounding external-yield surplus, `EXTERNAL_VAULT.maxWithdraw(FM) − trackedPrincipal`. A protocol-owned solvency reserve left inside the external vault — excluded from share price, drawn down by `_rebalanceYieldAssets()` (per-op + operator `ensureYieldFlowDuration()`) to top the super-token reserve. The pull is uncapped at the surplus from 2026-05-21 — once exhausted it continues into the principal-backing slice and the loss is reflected by the NAV clamp. Absorbs external losses before any user-facing dip; never extracted as treasury revenue.

**share peg** : sync shares are principal receipts **≈**1:1 with the underlying — *not* a hard peg. NAV-neutral at entry; ticks below par between rebalances as the stream drains the reserve; impairment (`EXTERNAL_VAULT.maxWithdraw(FM) < trackedPrincipal`) prices it further below par (honest pass-through).

**custody hazard invariant** : principal never rests in the FM as raw underlying across calls — it is deployed into the external vault or upgraded into the reserve within the same call; otherwise the base rebalance logic would sweep it into the reserve and silently consume principal. (`design.md` Invariant 7.)

**FundManagerBase** : abstract contract holding the shared Superfluid GDA engine (pools, `_flowRatePerUnit`, `_recalibrateFlow`, `_rebalanceYieldAssets`, `guaranteedFlowDuration`, `setStableYieldRate`, fee pool, scaling, roles, `onShareTransfer`). Unchanged by the pivot. Extended by `AsyncFundManager` (epoch hooks) and `SyncFundManager`.

**StableYieldVault** : the synchronous ERC-4626 + `ReentrancyGuard` **face**. Holds no assets: pulls underlying from the caller, forwards it to the FM, mints/burns shares, proxies `totalAssets`/`max*` to FM views. Deploys & pins its `SyncFundManager` at construction (`msg.sender == vault`).

**SyncFundManager** : `FundManagerBase` plus the sole-custodian role — holds `EXTERNAL_VAULT`, the external-vault shares, `trackedPrincipal`, and the super-token reserve. Implements the abstract `_rebalanceYieldAssets()` with the self-sourcing override (external pull on deficit, downgrade + redeposit on excess). `VAULT_ROLE` hooks `onDeposit` (grant units + `_rebalanceYieldAssets` + bump principal + pre-fund residual + deploy remainder + guarded recalibrate) and `onWithdraw(holder, shares, totalSharesOwned, supplyBeforeBurn, receiver, redeemingAssets)` (pre-`_rebalanceYieldAssets` + proportional unit decrease + guarded recalibrate + reserve slice from the **recalibration-freed excess** `min(freedExcess, redeemingAssets)` + external remainder + post-payout `_rebalanceYieldAssets` (trim residual) + proportional principal decrement). **No `harvest()`** — solvency between user activity is operator-only via the inherited `ensureYieldFlowDuration()`. No `fundReserve` injection path — the sync vault is its own backstop via programmatic `EXTERNAL_VAULT` access (operator's only sustainability lever is `setStableYieldRate`). `EXTERNAL_VAULT.asset()==underlying` is validated by the vault before the FM is deployed (no FM re-validation).
