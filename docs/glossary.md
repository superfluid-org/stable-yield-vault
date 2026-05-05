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

**share** : the ERC-20 token minted by the vault to depositors at claim time, denominated in `1e18`. Non-transferable by design (D6); the only exit is `requestRedeem` → `redeem`/`withdraw`.

**pending redeem shares** : shares transferred from an owner to the vault on `requestRedeem` and locked there until the request's epoch is settled. Tracked by `totalPendingRedeemShares` and `_controllerStates[controller].pendingRedeemShares`.

**unclaimed deposit shares** : shares that have been priced (epoch settled) but not yet minted to the controller. Tracked by `_unclaimedDepositShares`. Added to `effectiveSupply` at the next `closeEpoch` to keep pricing consistent.

**unclaimed redeem shares** : shares still in `totalSupply` whose backing assets have already left NAV at settlement. Tracked by `_unclaimedRedeemShares`. Subtracted from `effectiveSupply` at the next `closeEpoch`.

**effective supply** : `totalSupply() + unclaimedDepositShares − unclaimedRedeemShares`. The denominator used to compute the epoch rate at `closeEpoch`.

**epoch rate / assets-per-share** : the rate locked at `closeEpoch` for the closing epoch, equal to `totalAssets * 1e18 / effectiveSupply` (or `1e18` if `effectiveSupply == 0`). Stored in `_epochRate[epoch]` once settled. Forward pricing — every request in an epoch settles at the same rate.

## Snapshot

**snapshot** : the `{ epoch, depositingAssets, redeemingShares, rate }` struct stored on the vault at `closeEpoch` and consumed by `settleEpoch`. Returned by `getSnapshot()` (used by the FM and by the `canSettleEpoch` view). While `snap.epoch != 0`, deposit/redeem requests revert with `EPOCH_SETTLEMENT_IN_PROGRESS`.

## Streaming / GDA

**GDA Pool** : the Superfluid General Distribution Agreement pool created and owned by the FundManager. Streams the yield super-token to unit holders; not transferable, single-distributor (FM only).

**unit** : a member's share of the pool's total flow. The vault grants units 1:1 with deposited underlying (`UNIT_PER_ASSET_DEPOSITED = 1`): a deposit of N underlying yields N units. Units belong to the FM until claimed at `deposit` / `mint`.

**flow rate per unit** : `_flowRatePerUnit = SCALING_FACTOR * stableYieldRate / (YEAR * BP_DENOMINATOR)`, recomputed when `stableYieldRate` changes.

**total flow rate** : `_flowRatePerUnit * POOL.getTotalUnits()`, set on the pool by `_recalibrateFlow()`.

**guaranteed flow duration** : the minimum forward stream-solvency horizon (in seconds) that the FundManager must maintain. The yield-asset reserve must satisfy `yieldAssetsBalance() >= totalFlowRate * guaranteedFlowDuration`. Floored at `MIN_GUARANTEED_FLOW_DURATION = 1 day`.

**stable yield rate** : the annualised rate committed to per-unit streaming, expressed in basis points (e.g. `100` ↔ 1%). Stored as `stableYieldRate`; updated via `setStableYieldRate`.

**scaling factor** : `SCALING_FACTOR = 10 ** (18 - underlyingDecimals)` — the factor that lifts underlying amounts into the super-token's 18-decimal space. For 6-dec USDC, `SCALING_FACTOR = 10**12`.

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
