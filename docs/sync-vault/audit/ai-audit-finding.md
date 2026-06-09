# 🔐 Security Review — Stable Yield **Sync** Vault family

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | sync-vault family (caller-scoped)                      |
| **Files reviewed**               | `src/common/FundManagerBase.sol` · `src/vault/sync/SyncFundManager.sol`<br>`src/vault/sync/StableYieldSyncVault.sol` |
| **Confidence threshold (1-100)** | 80                                                     |

8 agents · 266 attack vectors classified · 2 candidate FINDINGs verified (1 confirmed, 1 refuted by live-read).

---

## Findings

[75] **1. Surplus reserve-trim consumes external deposit capacity → compliant `deposit`/`mint` bricks at the deposit-cap boundary**

`SyncFundManager.onDeposit` · Confidence: 75 · [agents: 2]

**Description**
OZ checks `assets ≤ maxDeposit(FM) = EXTERNAL_VAULT.maxDeposit(FM)` at entry, but `onDeposit` then calls `_rebalanceYieldAssets()`, whose surplus branch (`SyncFundManager.sol:233-236`) deposits `underlyingNeeded` into the external vault *first*, lowering its remaining capacity; the subsequent principal deposit `EXTERNAL_VAULT.deposit(toExternal = assets)` (`:110`) now exceeds the reduced cap and reverts — a fully ERC-4626-compliant external with any deposit cap (Aave/Morpho supply caps are the norm) bricks the user's deposit whenever the reserve is in surplus (reachable via an operator `setStableYieldRate` cut, or a redeem that lowered target flow, while the external sits near its cap). Same root applies to the `mint` path (`previewMint`-derived `assets`). The ERC-4626 contract that `maxDeposit` returns a value `deposit` will accept is violated; impact is a recoverable deposit DoS at the cap boundary (no fund loss).

**Fix**

```diff
         // Deploy the remainder as principal
         uint256 toExternal = assets - toUpgrade;
         if (toExternal > 0) {
+            // The surplus-trim branch of _rebalanceYieldAssets() above may have
+            // consumed external deposit capacity that OZ already counted toward
+            // `assets` at entry; bound by the live remaining capacity and retain
+            // any shortfall in the reserve so a capped (but compliant) external
+            // cannot brick the deposit.
+            uint256 cap = EXTERNAL_VAULT.maxDeposit(address(this));
+            if (toExternal > cap) {
+                _upgrade(toExternal - cap);
+                toExternal = cap;
+            }
+        }
+        if (toExternal > 0) {
             UNDERLYING_ASSET.forceApprove(address(EXTERNAL_VAULT), toExternal);
             EXTERNAL_VAULT.deposit(toExternal, address(this));
         }
```

(Alternatively, skip the `deficit < 0` trim branch entirely inside the deposit-path rebalance — the excess can stay as above-target reserve slack and is trimmed idempotently on the next op.)

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [75] | Surplus reserve-trim consumes external deposit capacity → compliant `deposit`/`mint` bricks at deposit-cap boundary |

_No findings at or above the confidence threshold (80). The sync family is well-hardened; the items below are sub-threshold trails and accepted-design liveness boundaries._

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **DEFAULT_ADMIN_ROLE is the implicit admin of VAULT_ROLE** — `FundManagerBase` (constructor / AccessControl) — Code smells: no `_setRoleAdmin` is ever called, so the flow-duration admin (`_fundAdmin`, intended only for `setGuaranteedFlowDuration`) can `grantRole(VAULT_ROLE, attacker)` and then call `SyncFundManager.onWithdraw(victim, shares, …, attacker, redeemingAssets)` directly — the FM fully trusts the caller and never re-checks vault supply/balances, so it pays out the reserve + external position to an attacker-chosen `receiver` with **no corresponding share burn**, and `onShareTransfer` can relocate any holder's yield units. Breaks the role separation the design relies on. Admin-trust boundary (gated behind the trusted key), but the enforcement is missing. Fix: `_setRoleAdmin(VAULT_ROLE, <unreachable/self>)` in the constructor.
- **int96 flow-rate cast chain has no width guard** — `FundManagerBase._targetFlowRate` (`:318`) / `evaluateYieldAssetsDeficit` (`:286`) — Code smells: `_flowRatePerUnit * int96(int128(YIELD_POOL.getTotalUnits()))` — the `int96(int128(units))` narrowing silently truncates above `int96.max` and the product is a checked int96 multiply (reverts on overflow). Both bounds require ≥~1e18 USDC TVL (≥7 orders beyond total USDC supply), so practically unreachable — flagged by 3 agents purely as a defense-in-depth/theoretical bound; consider `SafeCast` + widen-before-multiply if a non-6-dec or extreme-TVL deployment is ever contemplated.
- **`onWithdraw` post-payout trim can brick a withdraw under a non-compliant external** — `SyncFundManager.onWithdraw` (`:169`) — Code smells: the trailing `_rebalanceYieldAssets()` surplus branch (`:233-236`) deposits into the external; for a *compliant* external it deposits exactly `underlyingNeeded ≤ maxDeposit` (safe), but a non-compliant external that reverts `deposit` despite `maxDeposit > 0` would brick the exit (strictly worse than the documented deposit-side limitation, since it traps funds). Documented as an accepted external-compliance requirement; confirm the withdraw path is in scope of that acceptance.
- **`onWithdraw` reserve slice rounds up (`Ceil`) while payout is floor-priced** — `SyncFundManager.onWithdraw` (`:145`) — Code smells: `fromYieldAssets = scaledYieldAssetsBalance().mulDiv(shares, supplyBeforeBurn, Ceil)` sources the reserve in preference to the external by up to ~1 atom over strict pro-rata; clamped to `redeemingAssets` (no over-payment) and self-healed by post-payout rebalance + flow-decrease recalibrate. Three agents converged; could not construct an extractable or bricking path — only transient buffer erosion. Unverified whether a high-frequency dust-redeem loop under a `maxDeposit==0` external (trim branch skipped) can outpace rebalancing.
- **Dust / partial-impairment deposit leaves the reserve below the solvency horizon** — `SyncFundManager.onDeposit` (`:100-104`) — Code smells: pre-fund caps `toUpgrade = min(deficit/SCALING_FACTOR + 1, assets)`; when `assets < need` (a dust deposit, or partial external illiquidity where `0 < maxWithdraw(FM) < need` so the vault is *not* paused) the reserve stays below `flowRate · guaranteedFlowDuration` yet `_recalibrateFlow()` still raises the flow. `distributeFlow` doesn't revert (Superfluid buffer uses the shorter liquidation period), so the documented `guaranteedFlowDuration` horizon is silently violated until the next op/operator poke. Design docs tolerate "residual positive deficit"; confirm reachability under realistic external liquidity caps.
- **Vestigial unbounded approval to the vault** — `FundManagerBase` constructor — Code smells: `UNDERLYING_ASSET.forceApprove(msg.sender, type(uint256).max)` grants the vault unlimited spend on the FM's underlying, but the sync vault never calls `transferFrom` on the FM (deposits pull caller→FM; payouts are FM-pushed). Dead surface today (vault is immutable/pinned); remove or scope per-op.
- **Temporary external liquidity freeze hard-pauses all redemptions** — `StableYieldSyncVault._isExternallyPaused` (`:819-822`) / `maxWithdraw`/`maxRedeem` — Code smells: the full pause keys solely on `EXTERNAL_VAULT.maxWithdraw(FM) == 0`, which a *non-loss* freeze (Aave at 100% utilization, external self-pause) also triggers; all four `max*` return 0 for the whole freeze even though `totalManagedAssets()` still includes the reserve + resting underlying that `onWithdraw`'s R-shares path could pay out. In-code NatSpec explicitly acknowledges this conflation as accepted — surfaced as the most material liveness consideration; consider capping `max*` at the reserve-serviceable amount during a freeze instead of forcing 0.

---

## Verified-closed (chased and refuted, not reported)

- **Donation NAV double-count on `maxWithdraw`** — `totalManagedAssets()` (`:180-183`) is a *live* `balanceOf` read; once redeemer #1 spends the donation, NAV drops for redeemer #2's fresh `maxWithdraw`. No cross-call double-count. Agents independently confirmed value conservation `fromExternal + fromYieldAssets + fromDonation = redeemingAssets`, with the external leg always `≤ maxWithdraw(FM)`.
- **Unit-decrease underflow** in `onWithdraw`/`onShareTransfer` — `Ceil` mulDiv with `shares ≤ balance` ⇒ `delta ≤ units`; zero-unit dust positions are skipped, not reverted.
- **First-deposit inflation attack** — mitigated by `_decimalsOffset() = 12`.
- **Single-function reentrancy** — vault entrypoints are `nonReentrant`; `_withdraw` burns before the external call (CEI).
- **Terminal-pause gate** — keyed on `totalSupply() > 0` (not the FM's external-share balance), resisting the dust-share donation false-pause and the total-loss share-burn blind-spot.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
