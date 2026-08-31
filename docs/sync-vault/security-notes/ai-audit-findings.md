# 🔐 Security Review — stable-yield-vault (sync family)

> **Internal AI-assisted security review — not a third-party audit.** This document was produced in-house (AI-assisted review / fuzzing) as pre-audit preparation and is published for transparency. It is a point-in-time snapshot (2026-06-22); findings marked *Status* below have been reconciled against the current code, everything else may be stale (line numbers in particular). It has not been reviewed by an independent security firm. See [`SECURITY.md`](../../../SECURITY.md).

_Generated 2026-06-22 · AI-assisted parallel audit (8 agents)_

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | filename subset (sync + shared base; async excluded per request) |
| **Files reviewed**               | `src/common/FundManagerBase.sol` · `src/vault/sync/StableYieldSyncVault.sol`<br>`src/vault/sync/SyncFundManager.sol` · `src/vault/sync/SyncVaultMacro.sol` |
| **Confidence threshold (1-100)** | 80                                                     |

---

## Bottom line on the audit question

> *"I want to make sure that the contract cannot be exploited to steal user's funds."*

**No unprivileged fund-theft path was found.** Across 8 parallel agents (attack-vector scan, math/precision, access control, economic, execution-trace, invariants, periphery, first-principles), every value-flow path traced is either correctly guarded or maps to an explicitly documented, accepted tradeoff. Specifically confirmed safe:

- The `onWithdraw` three-leg payout (donation → reserve slice → external) provably sums to exactly `redeemingAssets` (OZ floor-priced), so a withdrawer cannot pull more than their pro-rata NAV; stayers are protected.
- `onShareTransfer` conserves total GDA pool units — wash transfers between owned wallets **cannot** inflate a holder's unit fraction to siphon the yield stream.
- First-deposit inflation is mitigated by `_decimalsOffset() == 12`; donations only ever gift existing holders (irrational, not an attack).
- All FM/vault external entrypoints are `nonReentrant`.

**The one way user funds CAN be fully taken is via the admin key** — see Lead #1. This is the single most important item for the deployment decision, so it leads the Leads section even though the rubric classifies trusted-role issues as Leads rather than Findings.

---

## Findings

[35] **1. `maxMint`/`maxDeposit` advertise `type(uint256).max` but minting that amount reverts**

`StableYieldSyncVault.maxMint` · Confidence: 35

**Description**
`maxMint`/`maxDeposit` return `type(uint256).max` when `canDepositExternal()`, but `previewMint(shares) = super.previewMint(shares) + DEPOSIT_FEE` overflows long before that, so an op at the advertised limit reverts — a spec deviation, not a fund-theft path (caller's own tx reverts; no victim). This is also OZ's standard `ERC4626` behavior. Below threshold, informational only.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [35] | `maxMint`/`maxDeposit` sentinel-value reverts on execution (ERC-4626 deviation) |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed (or is trusted-role / documented-tradeoff gated). Not scored._

- **🔑 Admin can drain 100% of custodied funds via `emergencyWithdraw`** — `FundManagerBase.emergencyWithdraw` — Code smells: `onlyRole(DEFAULT_ADMIN_ROLE)` + `IERC20(token).safeTransfer(TREASURY, amount)` for *any* token, no accounting hook. *(Status: confirmed as designed — the recipient is the immutable `TREASURY`, not `msg.sender` as an earlier draft of this note said; the admin cannot redirect funds to an arbitrary address, but can still move all custodied assets out of the vault's accounting.)* The FM is the sole capital custodian, so `emergencyWithdraw(address(EXTERNAL_VAULT), …)` + `emergencyWithdraw(address(YIELD_ASSET), …)` empties all principal and reserve in two calls; NAV is a live balance read, so `totalAssets → 0` and every holder's `maxWithdraw → 0` with no recovery. **This is the answer to "can funds be stolen": yes, by whoever holds `DEFAULT_ADMIN_ROLE`.** Demoted to Lead because it is a trusted-role, explicitly-named emergency escape hatch — but its safety depends entirely on `DEFAULT_ADMIN_ROLE` being a timelock/multisig, **not an EOA**. _Action: verify the deployment's admin is a multisig/timelock before going live._

- **External full-exit rounding can brick the last redemption** — `SyncFundManager.onWithdraw` — Code smells: `EXTERNAL_VAULT.withdraw(fromExternal, FM, FM)` requests an exact asset amount; on a near-full last-holder exit `fromExternal` approaches `previewRedeem(balanceOf(FM))` (rounded *down*), while ERC-4626 `withdraw(assets)` burns `previewWithdraw(assets)` shares (rounded *up*) — a 1-share asymmetry that can revert the final redeem until a dust top-up. Unverified against Morpho V2's exact rounding; OZ virtual-offset floor pricing mitigates but doesn't provably eliminate. Consider `redeem(balanceOf(FM), …)` (share-denominated) for the terminal pull. DoS, not theft.

- **Bootstrap self-pause if a first deposit is fully absorbed into the GDA buffer** — `StableYieldSyncVault._isExternallyPaused` — Code smells: if `onDeposit` pre-fund consumes the whole deposit (`toExternal == 0`) on an empty external position, the deposit completes with `externalPositionValue() == 0 && totalSupply() > 0`, latching the external pause (all four `max*` → 0) and freezing the vault. Team documents this as precluded by the `rate × guaranteedFlowDuration ≤ YEAR × BP_DENOMINATOR` guard; worth a targeted unit test at the guard boundary. Liveness, not theft.

- **Unchecked uint128→int96 narrowing in the flow-rate math** — `FundManagerBase._targetFlowRate` / `evaluateYieldAssetsDeficit` — Code smells: `_flowRatePerUnit * int96(int128(YIELD_POOL.getTotalUnits()))` and the `uint96(...)` cast in the deficit calc silently wrap above ~1.3e28 pool units (~1.3e22 USDC). Threshold is far beyond any plausible TVL, so latent only. _[converged: 2 agents]_

- **Cosmetic `deadline` in the redeem macro** — `SyncVaultMacro._buildRedeemOps` — Code smells: `deadline` is bound into the EIP-712 digest and shown to the user, but no op enforces it; real expiry comes from the forwarder's `validBefore`/nonce. A signed redeem can be relayed after the user-visible deadline. Bounded by `ClearMacroForwarderV1`'s nonce + `validBefore` window, so not free replay — confirm the relayer always sets a sane `validBefore`.

- **Reserve-slice Ceil drift / donatable NAV / `max*` liquidity overestimate / unused max approval** — `SyncFundManager`, `FundManagerBase.constructor` — Code smells: (a) `fromYieldAssets` Ceil over-downgrades the reserve by ≤1 atom per withdraw (self-correcting, NAV-neutral); (b) `totalManagedAssets` counts raw `balanceOf(FM)` donations (documented gift); (c) `maxWithdraw`/`maxRedeem` cap by position *value* not instant liquidity, so a within-`max*` redeem can revert at the external leg (documented `forceDeallocate` deviation); (d) the constructor's `forceApprove(vault, max)` underlying allowance is unused in the sync flow — harmless (only the trusted immutable vault holds it) but widens blast radius. All documented accepted tradeoffs or non-exploitable.

---

## Deployment recommendation

The contracts hold up well against external attackers — the math, custody, and accounting are carefully done and match the design docs. The one thing that determines whether user funds are safe is **who controls `DEFAULT_ADMIN_ROLE`**. If that's an EOA, `emergencyWithdraw` is a single-key total-loss button. Make it a multisig (ideally timelocked) and the only complete fund-extraction path this audit surfaced is closed.

---

## Coverage notes

8 agents ran in parallel over the 4 in-scope contracts. Each agent's verified-safe conclusions:

- **Access control** — role wiring correct: `VAULT_ROLE` granted only to the deploying vault; `onShareTransfer`/`onDeposit`/`onWithdraw` all `onlyRole(VAULT_ROLE)`; setters split correctly between `FUND_OPERATOR_ROLE` and `DEFAULT_ADMIN_ROLE`. No init hijack (constructor-only, immutable pinning, no proxy).
- **Math/precision** — three-leg payout sums exactly; `_downgrade` never underflows (`fromYieldAssets ≤ scaledYieldAssetsBalance()`); unit-transfer Ceil conserves total pool units (no wash-trade inflation); `uint128` downcasts bounded by `shares ≤ balance`; decimals identity `SCALING_FACTOR · RAW_PER_UNIT = 1e12` holds for `[6,18]`.
- **Economic** — donation socialized-then-realized (no theft); deposit-fee/preview/mint consistent; first-deposit inflation mitigated by offset 12; NAV spot-read manipulation bounded by Morpho V2's accrual-priced, non-spikable share price.
- **Execution-trace** — all FM/vault entrypoints `nonReentrant`; `_upgrade` approval/amount match; in-flight `net` not swept by rebalance trim (deposit-brick fix in place).
- **Invariants** — withdraw conservation, unit conservation, reserve-slice bound, custody hazard A.2, and deficit pre-fund all hold within documented bounds.
- **Vector scan** — 266 vectors classified; threat surface excludes cross-chain/bridge, proxy/upgrade, AMM/oracle, NFT, governance, liquidation, paymaster/AA, assembly (none present).

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
