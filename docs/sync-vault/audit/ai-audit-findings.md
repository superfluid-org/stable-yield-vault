# 🔐 Security Review — Stable Yield **Sync** Vault

_Generated 2026-06-03 · branch `feat/sync-vault` · scope limited to the sync-vault family._

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | filename (sync-vault only)                             |
| **Files reviewed**               | `src/common/FundManagerBase.sol` · `src/vault/sync/SyncFundManager.sol`<br>`src/vault/sync/StableYieldSyncVault.sol` |
| **Confidence threshold (1-100)** | 80                                                     |

8 parallel hacking agents (vector-scan, math-precision, access-control, economic-security, execution-trace, invariant, periphery, first-principles) reviewed the bundled source. The headline issue (Finding 1) converged independently across **4 of 8** agents.

---

## Findings

[85] **1. Raw underlying counted in NAV but never paid out — permissionless withdraw-DoS + permanent value stranding (E.1 break)**

`SyncFundManager.onWithdraw / totalManagedAssets` · Confidence: 85

**Description**
`totalManagedAssets()` sums `UNDERLYING_ASSET.balanceOf(FM)` (`SyncFundManager.sol:170-171`) and so inflates `maxWithdraw`/`maxRedeem`, but `onWithdraw` sources payouts **only** from the reserve (`fromYieldAssets`) and `EXTERNAL_VAULT.withdraw` (`fromExternal`, line 151) — no code path ever spends a resting raw balance. Anyone can `transfer` raw USDC directly to the FM (cost = the donation): NAV and the advertised `max*` rise by `D`, then a holder redeeming up to `maxRedeem` computes `fromExternal = redeemingAssets − fromYieldAssets > EXTERNAL_VAULT.maxWithdraw(FM)` and the external withdraw reverts — bricking large/full redemptions and permanently stranding `D`. This breaks invariant **E.1** ("request ≤ `max*` ⇒ never reverts") and directly contradicts the documented assumption that raw-underlying donations are harmless "irrational gifts" (`CLAUDE.md` / `design.md §Security`).

**Concrete trace** (sole holder owning all supply `S`; external recoverable `E`, reserve `Y`, donation `D`; at-rest raw = 0 per Inv. 7):

```
Before:  totalManagedAssets = E + Y          maxWithdraw(holder) = E + Y
Attack:  griefer transfers D raw USDC to FM
After:   totalManagedAssets = E + Y + D      maxWithdraw(holder) = E + Y + D   (lies by D)

redeem(S):
  redeemingAssets = E + Y + D
  fromYieldAssets = ceil(Y · S/S)  = Y                (clamped at redeemingAssets)
  fromExternal    = (E+Y+D) − Y    = E + D
  EXTERNAL_VAULT.withdraw(E + D)  reverts  (only E is withdrawable)   ← E.1 broken
```

The donated `D` is never consumed by any path (`_upgrade`/`EXTERNAL_VAULT.deposit` use the *incoming* `assets`; `_rebalanceYieldAssets` deficit>0 pulls only from external, deficit<0 downgrades only super-token), so it rests forever, inflating the share price with phantom value and capping the realizable top of every holder's exit at fraction `E/(E+D)`.

**Severity rationale:** permissionless trigger, no privileged role, fully traced against source. Pure griefing (attacker forfeits `D`) — no profit extraction — but it breaks a stated ERC-4626 invariant, bricks the advertised `max*` contract (a composability/integration hazard), and permanently strands value.

**Fix**

```diff
 function totalManagedAssets() public view returns (uint256) {
-    return EXTERNAL_VAULT.maxWithdraw(address(this)) + scaledYieldAssetsBalance()
-        + UNDERLYING_ASSET.balanceOf(address(this));
+    // Inv. 7: raw underlying never rests in the FM across calls (onDeposit/onWithdraw fully
+    // clear it within the call), so an at-rest raw balance only ever reflects a donation the
+    // payout path cannot realize. Excluding it keeps NAV honest and preserves E.1.
+    return EXTERNAL_VAULT.maxWithdraw(address(this)) + scaledYieldAssetsBalance();
 }
```

Alternative (if you want to actually realize a resting raw balance rather than ignore it): in `onWithdraw`, pay the `fromExternal` slice from `UNDERLYING_ASSET.balanceOf(FM)` first — net of the just-downgraded `fromYieldAssets` (line 145) — and only draw the remainder via `EXTERNAL_VAULT.withdraw`. The `totalManagedAssets` exclusion above is simpler and safe given Inv. 7; also update the `design.md §Security` claim that raw donations are harmless.

---

[75] **2. `onShareTransfer` reverts on zero units where `onWithdraw` skips — residual shares become non-transferable**

`FundManagerBase.onShareTransfer` · Confidence: 75

**Description**
`onShareTransfer` reverts with `BAD_SHARE_TRANSFER` when `senderUnits == 0` (`FundManagerBase.sol:238`), but `onWithdraw` deliberately *skips* the unit decrease for the same zero-units state (`SyncFundManager.sol:130`). Because the unit decrease in `onWithdraw` is `Ceil`-rounded (line 135), a near-full partial redeem zeroes a holder's GDA units while leaving residual shares — e.g. deposit 1 USDC → `1e6` units / `1e18` shares; redeem `1e18 − 1` shares → `delta = ceil(1e6·(1e18−1)/1e18) = 1e6`, units → 0, 1 wei share remains. Any later `transfer` of that residual hits the revert, so the shares are permanently non-transferable (still redeemable, so no fund loss — a dust transfer-DoS). Converged across 3 agents (execution-trace, periphery, first-principles).

**Fix** — mirror the defensive skip already present in `onWithdraw`:

```diff
 function onShareTransfer(address sender, address receiver, uint256 shares) external onlyRole(VAULT_ROLE) {
     uint128 senderUnits = YIELD_POOL.getUnits(sender);
-    if (senderUnits == 0) revert BAD_SHARE_TRANSFER();
+    // A dust position can hold shares but zero units (sub-`RAW_PER_UNIT` deposit, or a Ceil-rounded
+    // onWithdraw that zeroed units ahead of the last shares). Skip rather than revert so the shares
+    // remain transferable — symmetric with onWithdraw's zero-units guard.
+    if (senderUnits == 0) return;

     uint128 delta = uint128(uint256(senderUnits).mulDiv(shares, VAULT.balanceOf(sender), Math.Rounding.Ceil));

     YIELD_POOL.increaseMemberUnits(receiver, delta);
     YIELD_POOL.decreaseMemberUnits(sender, delta);
 }
```

---

[72] **3. Dust external-vault-share donation forces a false full pause, bricking bootstrap deposits**

`StableYieldSyncVault._isExternallyPaused` · Confidence: 72

**Description**
`_isExternallyPaused()` returns true when `maxExternalVaultWithdraw() == 0 && EXTERNAL_VAULT.balanceOf(FM) > 0` (`StableYieldSyncVault.sol:220-223`). An attacker can `transfer` dust external-vault *shares* directly to the FM; whenever the external vault's price-per-share > 1 asset (the normal state for any yield-bearing 4626 once it has accrued), those dust shares floor to `maxWithdraw(FM) == 0` while `balanceOf(FM) > 0`, flipping all four `max*` to 0 and reverting every deposit/mint/withdraw/redeem with `ERC4626ExceededMax*`. This is most acute in the empty-vault **bootstrap** window (the design's intentionally-not-paused "healthy" state), where it bricks the very first deposit. Recoverable — anyone can donate enough additional external shares to push `maxWithdraw(FM) > 0` and un-pause — so it is a griefing nuisance rather than a permanent lock, but it defeats the gate's stated intent of never pausing the bootstrap. Converged across 2 agents (economic-security, execution-trace).

_Below threshold — description only, no fix block. A robust remedy would gate the pause on a minimum recoverable value (or the FM's tracked deployment) rather than a raw `balanceOf(FM) > 0`, so dust cannot trip it._

---

## Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [85] | Raw underlying in NAV but unpayable → withdraw-DoS + value stranding (E.1 break) |
| 2 | [75] | `onShareTransfer` reverts on zero units where `onWithdraw` skips → dust shares non-transferable |
| 3 | [72] | Dust external-vault-share donation forces false `_isExternallyPaused` → bricks bootstrap deposits |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Missing `nonReentrant` on operator setters** — `FundManagerBase.setStableYieldRate` / `ensureYieldFlowDuration` — Code smells: both invoke `_rebalanceYieldAssets()` (external `EXTERNAL_VAULT.withdraw/deposit`) without the `nonReentrant` that the sibling `setGuaranteedFlowDuration` carries (line 214). Trigger requires the trusted operator + a malicious external vault re-entering mid-rebalance (e.g. into `vault.transfer` → `onShareTransfer` while units/reserve are half-updated) — operator-gated, so demoted; add the guard for consistency.
- **Ceil-rounded reserve slice over-draws the stream reserve** — `SyncFundManager.onWithdraw` — Code smells: `fromYieldAssets = scaledYieldAssetsBalance().mulDiv(shares, supplyBeforeBurn, Ceil)` (line 142) takes an over-proportional reserve bite on every redeem; under a deposit-capped-but-liquid external the post-payout rebalance can't refill, so stayers' forward-solvency horizon degrades. Cumulative magnitude vs. operator `ensureYieldFlowDuration` cadence unverified.
- **Deposit-side `max*` may revert (E.1 on deposit)** — `SyncFundManager.onDeposit` — Code smells: unconditional `EXTERNAL_VAULT.deposit(toExternal)` (line 109) when the vault-level `maxDeposit` only bounds the *total* deposit; a deposit-capped (not impaired) external could reject the post-pre-fund remainder even though `assets ≤ maxDeposit` passed.
- **Pathological `rate × guaranteedFlowDuration` bricks every deposit** — `SyncFundManager.onDeposit` — Code smells: `toUpgrade = min(need, assets)` clamps the pre-fund but `_recalibrateFlow()` runs unconditionally (line 112); when `rate · duration > YEAR · BP` the reserve stays below the GDA buffer and `distributeFlow` reverts. No on-chain bound enforces `rate · duration ≤ YEAR · BP` (operator-misconfig reachable; flagged in `CLAUDE.md` as a known tradeoff).
- **Pause fails to engage on total-loss share-burn** — `StableYieldSyncVault._isExternallyPaused` — Code smells: gated on `balanceOf(FM) > 0`; an external 4626 that burns the FM's shares to 0 on a socialized total loss reads `maxWithdraw == 0 && balanceOf == 0` → not paused, so holders race to drain the reserve via `withdraw`/`redeem` against `totalManagedAssets`, defeating D.2. Hinges on the external's loss accounting.
- **Silent `int96`/`uint96` flow-rate truncation** — `FundManagerBase._targetFlowRate` / `evaluateYieldAssetsDeficit` / `setStableYieldRate` — Code smells: `_flowRatePerUnit * int96(int128(getTotalUnits()))` (line 301) and the unbounded operator `newRate` cast (line 205) wrap silently; thresholds (~1e14+ USDC of units, or an extreme rate) are far beyond realistic TVL, so latent-robustness only.
- **GDA buffer omitted from reserve target** — `FundManagerBase.evaluateYieldAssetsDeficit` — Code smells: explicit `FIXME: add buffer` (line 264); `requiredBalance` omits Superfluid's `flowRate · liquidationPeriod` GDA buffer. Non-exploitable while `MIN_GUARANTEED_FLOW_DURATION = 1 day` ≥ the ~4h mainnet liquidation period, but a live brick on any host where `liquidationPeriod > guaranteedFlowDuration`.
- **Plain `approve` in `_upgrade`** — `FundManagerBase._upgrade` — Code smells: `UNDERLYING_ASSET.approve(...)` (line 282) rather than the `forceApprove` used elsewhere in `SyncFundManager`; fragile for USDT-style residual-allowance or fee-on-transfer underlyings (the `[6,18]`-decimal constructor gate doesn't exclude them).
- **NAV is a pure spot read of an untrusted external vault** — `SyncFundManager.totalManagedAssets` — Code smells: share price = `totalAssets/supply` reads live `EXTERNAL_VAULT.maxWithdraw(FM)` with no TWAP/clamp; within-block manipulation of the external vault's own NAV can sandwich sync-vault deposits/withdrawals. Documented as an accepted floating-share/MEV tradeoff; residual exploitability depends on the out-of-scope external vault.

---

## Notes on cleared surfaces (verified NOT exploitable)

To save reviewer time, the agents explicitly cleared the following (no finding):

- OZ ERC-4626 default conversions use correct vault-favorable rounding; `SafeERC20`/`forceApprove` used on all external-vault legs.
- `_spendAllowance` is correctly applied in `_withdraw` when `caller != owner`.
- `maxDeposit/maxMint/maxWithdraw/maxRedeem` correctly return 0 under the documented terminal-impairment pause.
- The in-flight-underlying deposit-brick (donation-griefing on `deposit`) was already fixed via the exact-`underlyingNeeded` redeposit (`SyncFundManager._rebalanceYieldAssets`, 2026-06-02); the trim no longer sweeps `balanceOf(FM)`.
- `onShareTransfer` conserves units exactly (`delta ≤ senderUnits`) and prevents decoupling units from shares.
- `VAULT_ROLE` is unobtainable (pinned to the vault at construction, grantable only by `DEFAULT_ADMIN_ROLE`); no unprotected state mutators, no escalation chain, no init-hijack, no proxy/delegatecall surface.
- For the stated 6-dec USDC deployment (`RAW_PER_UNIT == 1`), Finding 2's sub-`RAW_PER_UNIT` dust-deposit variant is unreachable; the reachable variant is the `onWithdraw` Ceil-zeroing path described above.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
