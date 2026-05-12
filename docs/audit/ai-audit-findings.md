# 🔐 Security Review — poc-stable-yield-vault

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | default                                                |
| **Files reviewed**               | `src/async-vault/StableYieldAsyncVault.sol` · `src/async-vault/AsyncFundManager.sol` · `script/Deploy.s.sol`<br>`script/StableYieldVaultDeployer.sol` · `script/config/NetworkConfig.sol` · `script/config/AddressRegistry.sol` |
| **Confidence threshold (1-100)** | 80                                                     |

---

## Findings

[90] **1. Donation-driven share-price inflation against new depositors**

`AsyncFundManager.closeEpoch / unutilizedAssetsBalance / scaledYieldAssetsBalance` · Confidence: 90

**Description**
NAV in `closeEpoch` is computed as `workingAssets + UNDERLYING.balanceOf(FM) + YIELD_ASSET.balanceOf(FM)/SCALING_FACTOR` (live `balanceOf`), so anyone can `transfer` raw underlying or super-token directly to FM and inflate the next epoch rate; with one outstanding share an attacker forces the victim's `pendingShares = victim_assets * 1e18 / inflated_rate` to floor to **0**, after which (combined with finding #5) the victim's assets are stuck and the attacker redeems against the inflated NAV to extract them — a textbook ERC-4626 first-depositor attack with no virtual-shares mitigation.

**Fix**

```diff
- function unutilizedAssetsBalance() public view returns (uint256) {
-     return UNDERLYING_ASSET.balanceOf(address(this));
- }
- function scaledYieldAssetsBalance() public view returns (uint256) {
-     return YIELD_ASSET.balanceOf(address(this)) / SCALING_FACTOR;
- }
+ // Track internally; only mutate via give()/take()/_upgrade()/_downgrade()/onSettleEpoch hooks.
+ uint256 private _trackedUnderlying;
+ uint256 private _trackedYield;
+ function unutilizedAssetsBalance() public view returns (uint256) { return _trackedUnderlying; }
+ function scaledYieldAssetsBalance() public view returns (uint256) { return _trackedYield / SCALING_FACTOR; }
+ // PLUS: in StableYieldAsyncVault constructor, mint dead virtual shares (OZ ERC4626 decimal-offset pattern)
+ // to a burn address so first-depositor inflation is economically infeasible.
```

---

[85] **2. Settlement deadlock: `canSettleEpoch` counts yield-asset, `onSettleEpoch` pulls underlying**

`AsyncFundManager.settleEpoch` / `StableYieldAsyncVault.onSettleEpoch` · Confidence: 85

**Description**
`canSettleEpoch` evaluates `scaledYieldAssetsBalance() + unutilizedAssetsBalance() + snap.depositingAssets ≥ redeemingAssets + requiredScaledYieldAssetsBalance` (combined liquidity), but the deficit branch in `onSettleEpoch` does `underlyingAsset.safeTransferFrom(FM, vault, deficit)` against **raw underlying only**. Whenever FM holds enough total value but the redeem deficit exceeds `unutilizedAssetsBalance()` (e.g., yield reserve is healthy but operator parked underlying via `take`/upgrades), `safeTransferFrom` reverts; the snapshot stays open, blocking every `requestDeposit`/`requestRedeem` (`EPOCH_SETTLEMENT_IN_PROGRESS`) and every future `closeEpoch` (`PREVIOUS_EPOCH_NOT_SETTLED`) until manual recapitalization.

**Fix**

```diff
  function settleEpoch() external onlyRole(FUND_OPERATOR_ROLE) nonReentrant {
+     // Pre-fund underlying so the vault's deficit pull cannot revert.
+     (uint256 depositingAssets, uint256 redeemingAssets) = VAULT.epochSettlementAssets();
+     if (redeemingAssets > depositingAssets) {
+         uint256 deficit = redeemingAssets - depositingAssets;
+         uint256 onHand = unutilizedAssetsBalance();
+         if (onHand < deficit) {
+             _downgrade((deficit - onHand) * SCALING_FACTOR);
+         }
+     }
      VAULT.onSettleEpoch();
      ...
  }
```

---

[85] **3. `_flowRatePerUnit` precision loss systematically underpays low-APY configurations**

`AsyncFundManager.setStableYieldRate / constructor` · Confidence: 85

**Description**
`_flowRatePerUnit = int96(int256(1e12 * newRate / (YEAR * _BP_DENOMINATOR)))` floors before any unit-multiplication amplifies the value: for `newRate = 1` bp the inner expression is `1e12 / 3.1536e11 ≈ 3.17` → truncated to `3`, giving an effective rate of ~0.946 bp (a **~5.4% relative shortfall** that compounds across all distributions); the same bias is ~5.4% at 5 bp, ~2.2% at 10 bp, etc. — every shareholder is silently underpaid versus the configured stable yield.

**Fix**

```diff
- _flowRatePerUnit = int96(int256(1e12 * newRate / (YEAR * _BP_DENOMINATOR)));
+ // Compute total flow at higher precision; only downcast once at the end.
+ // Track residual numerator across calls so truncation does not bias the long-run rate.
+ uint256 totalUnits = uint256(POOL.getTotalUnits());
+ int256 totalFlowScaled = int256(1e12 * newRate * totalUnits + _flowResidual);
+ int256 totalFlow = totalFlowScaled / int256(YEAR * _BP_DENOMINATOR);
+ _flowResidual  = uint256(totalFlowScaled - totalFlow * int256(YEAR * _BP_DENOMINATOR));
+ _flowRatePerUnit = totalUnits == 0 ? int96(0)
+     : SafeCast.toInt96(totalFlow / int256(totalUnits));
```

---

[80] **4. Sub-RAW_PER_UNIT deposits create permanently unredeemable shares (high-decimal underlyings)**

`AsyncFundManager.onRequestRedeem` · Confidence: 80

**Description**
For underlyings with decimals > 6 (e.g., DAI: `RAW_PER_UNIT = 1e12`), `_toUnit(assets) = assets / 1e12` floors to **0** for any `assets < 1e12`, so a deposit of e.g. `5e11` wei mints `5e11` shares but grants `0` GDA pool units; subsequent `requestRedeem` enters `onRequestRedeem`, reads `userUnits = POOL.getUnits(owner) = 0`, and unconditionally reverts with `BAD_REDEEM_ARGS`. Although shares are transferable in general, `FundManager.onShareTransfer` also reverts (`BAD_SHARE_TRANSFER`) when `senderUnits == 0`, so a dust holder cannot route around the redeem block by sending shares to another address either. The holder's only recovery is to make a strictly larger second deposit and claim it (which they may not have liquidity for). For a holder whose entire balance is sub-unit deposits, the funds are permanently locked.

**Fix**

```diff
  function onRequestRedeem(address shareholder, uint256 sharesRedeemed, uint256 totalSharesOwned)
      external onlyRole(VAULT_ROLE)
  {
      uint128 userUnits = POOL.getUnits(shareholder);
-     if (userUnits == 0) revert BAD_REDEEM_ARGS();
      if (sharesRedeemed == 0 || sharesRedeemed > totalSharesOwned) revert BAD_REDEEM_ARGS();
+     if (userUnits == 0) return; // dust-share holder: nothing to decrement, allow redeem to proceed
      uint128 delta = uint128(uint256(userUnits).mulDiv(sharesRedeemed, totalSharesOwned, Math.Rounding.Ceil));
      POOL.updateMemberUnits(shareholder, userUnits - delta);
  }
+ // Belt-and-braces: also reject a deposit-claim that would mint shares with zero units.
+ // In _claimDeposit, before _mint(receiver, shares), require _toUnit(assets) > 0.
```

---

[80] **5. Round-to-zero settlement locks deposits with no cancellation path**

`StableYieldAsyncVault._settleDepositIfNeeded / _deposit / _mintShares` · Confidence: 80

**Description**
`_settleDepositIfNeeded` computes `pendingShares = pendingAssets.mulDiv(1e18, epochRate)` and floors to **0** whenever `pendingAssets * 1e18 < epochRate` (e.g., after yield-driven rate growth or finding #1's donation inflation); the controller is then left with `claimableDepositAssets > 0, claimableDepositShares = 0`, after which `_deposit` reverts (`shares = assets * 0 / claimableAssets = 0` → `INVALID_PARAMETERS`) and `_mintShares` reverts with division-by-zero (`mulDiv(claimableAssets, 0, Ceil)`). There is **no `cancelDepositRequest`**, so the deposit is permanently un-claimable.

**Fix**

```diff
  function _settleDepositIfNeeded(address controller) internal {
      ControllerState storage cs = _controllerState[controller];
      uint256 pendingAssets = cs.pendingDepositAssets;
      if (pendingAssets == 0) return;
      uint256 requestEpoch = cs.depositRequestEpoch;
      if (requestEpoch >= currentEpoch) return;
      uint256 epochRate = _epochRate[requestEpoch];
      uint256 pendingShares = pendingAssets.mulDiv(ASSETS_PER_SHARE_SCALE, epochRate);
+     if (pendingShares == 0) {
+         // Refund stranded dust to the controller instead of stranding it.
+         underlyingAsset.safeTransfer(controller, pendingAssets);
+         totalPendingDepositAssets -= pendingAssets;
+         cs.pendingDepositAssets = 0;
+         return;
+     }
      cs.claimableDepositShares += pendingShares;
      cs.claimableDepositAssets += pendingAssets;
      cs.pendingDepositAssets = 0;
  }
```
*(Combined with finding #1's virtual-shares mitigation, the donation lock-in chain is fully closed.)*

---

[75] **6. `_toUnit` per-user vs aggregate floor mismatch traps GDA units in FundManager**

`AsyncFundManager.onClaimDeposit` · Confidence: 75

**Description**
At `settleEpoch` FM is granted `_toUnit(snap.depositingAssets) = floor(total / RAW_PER_UNIT)` units, but each per-user `_claimDeposit → onClaimDeposit` only transfers `_toUnit(perUserAssets) = floor(per_user / RAW_PER_UNIT)`; since `Σ floor(a_i/k) ≤ floor(Σ a_i / k)`, FM permanently retains the truncation residue and — being itself a connected pool member — keeps earning the corresponding slice of the GDA flow forever instead of returning it to depositors.

---

[75] **7. `_unclaimedDepositShares` accumulates aggregate-vs-per-user floor residue, biasing every future epoch rate**

`StableYieldAsyncVault.onSettleEpoch` · Confidence: 75

**Description**
`onSettleEpoch` increments `_unclaimedDepositShares` by `floor(snap.depositingAssets * 1e18 / snap.rate)` (one aggregate floor) while per-user `_settleDepositIfNeeded` decrements it by `floor(pendingAssets_i * 1e18 / rate)` summed across users; aggregate-floor ≥ Σ per-user-floor, so a positive residue accrues every epoch and is never burned down — that residue then enters `effectiveSupply = totalSupply + _unclaimedDepositShares - _unclaimedRedeemShares` at every subsequent `closeEpoch`, suppressing future `epochRate` and monotonically diluting existing share holders.

---

[75] **8. Raw `IERC20.approve` is incompatible with non-standard tokens (USDT-style, fee-on-transfer)**

`AsyncFundManager.constructor / _upgrade` · Confidence: 75

**Description**
The constructor's `UNDERLYING_ASSET.approve(msg.sender, type(uint256).max)` and `_upgrade`'s `UNDERLYING_ASSET.approve(address(YIELD_ASSET), underlyingAmount)` use raw `approve` (not `SafeERC20.forceApprove`); for void-returning USDT-style tokens the ABI decode reverts the constructor; for fee-on-transfer tokens the silently-reduced inbound amounts break the documented `balanceOf(vault) == totalPendingDepositAssets + totalClaimableRedeemAssets` invariant on every deposit; both classes of tokens are otherwise in-scope per the contract's 6–18-decimal underlying parameterization.

---

[75] **9. `int96` unchecked cast in `setStableYieldRate` / flow-rate math wraps silently at scale**

`AsyncFundManager.setStableYieldRate / _targetFlowRate / canSettleEpoch / evaluateFunding` · Confidence: 75

**Description**
`setStableYieldRate` does `_flowRatePerUnit = int96(int256(1e12 * newRate / (YEAR * _BP_DENOMINATOR)))` with no upper bound on `newRate` (the contract's own `// FIXME` only flags missing era-duration enforcement); for sufficiently large `newRate` the int96 cast wraps silently, and the same int96 narrowing in `_targetFlowRate`/`canSettleEpoch`/`evaluateFunding` (`int96(int128(POOL.getTotalUnits()))`) panics or truncates for large pools — corrupting the per-unit flow into a possibly-negative value that then cascades through `uint96`/`uint256` casts as a massive positive, breaking solvency checks across the entire epoch lifecycle.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [90] | Donation-driven share-price inflation against new depositors |
| 2 | [85] | Settlement deadlock: `canSettleEpoch` counts yield-asset, `onSettleEpoch` pulls underlying |
| 3 | [85] | `_flowRatePerUnit` precision loss systematically underpays low-APY configurations |
| 4 | [80] | Sub-RAW_PER_UNIT deposits create permanently unredeemable shares (high-decimal underlyings) |
| 5 | [80] | Round-to-zero settlement locks deposits with no cancellation path |
| 6 | [75] | `_toUnit` per-user vs aggregate floor mismatch traps GDA units in FundManager |
| 7 | [75] | `_unclaimedDepositShares` accumulates aggregate-vs-per-user floor residue |
| 8 | [75] | Raw `IERC20.approve` is incompatible with non-standard tokens |
| 9 | [75] | `int96` unchecked cast in `setStableYieldRate` / flow-rate math wraps silently |

**Composite chain:** Finding **[1]** + **[5]** form the full donation-attack exploit: the inflation lifts `epochRate` to a value where the victim's `pendingAssets * 1e18 < epochRate`, finding [5] then permanently strands the assets with no claim/cancel path, and the attacker (sole pre-existing shareholder) redeems against the inflated NAV. Combined confidence: **min(90, 80) = 80**.

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **`take()` drains underlying mid-epoch and deadlocks settlement** — `AsyncFundManager.take` — Code smells: no solvency cap, callable post-`closeEpoch` before `settleEpoch` — Operator-trusted by design but the post-snapshot window is uniquely dangerous; combined with finding #2 a single `take()` between close and settle freezes every user in the snapshot until `give()` returns funds.
- **`closeEpoch(workingAssets)` accepts unverified operator-supplied NAV** — `AsyncFundManager.closeEpoch` — Code smells: no upper/lower bound, no max-delta vs prior epoch, no event with raw input — One bad value (mistake or compromised operator key) re-prices every shareholder of the next era. Distinct from the donation surface (finding #1); a fix to one does not fix the other.
- **`setGuaranteedFlowDuration` has no upper bound** — `AsyncFundManager.setGuaranteedFlowDuration` — Code smells: only `MIN_GUARANTEED_FLOW_DURATION` floor; admin can set duration to a value that consumes all unutilized assets into yield reserve, indirectly bricking redeem settlement (chains with finding #2).
- **`setStableYieldRate` callable while `_snapshot.epoch != 0`** — `AsyncFundManager.setStableYieldRate` — Code smells: no gating by snapshot state — Rate change between `closeEpoch` and `settleEpoch` shifts `requiredScaledYieldAssetsBalance`, can flip an in-flight settlement from pass to fail in `canSettleEpoch`.
- **4-arg `redeem`/`withdraw` allow approved operators to redirect `receiver`** — `StableYieldAsyncVault.redeem / withdraw` — Code smells: only `_isOperator[controller][msg.sender]` checked, `receiver` is unconstrained — ERC-7540 standard permits this; a controller's broad operator approval becomes a full-position theft primitive if the operator key is compromised. (Note: shares are now transferable via `_update` → `onShareTransfer`, so a compromised operator can alternatively transfer shares directly — the redirect-on-claim primitive is an additional, claim-time-specific path that bypasses the share-transfer hook.)
- **`requestDeposit` / `requestRedeem` lack deadline / slippage parameters** — `StableYieldAsyncVault.requestDeposit / requestRedeem` — Code smells: forward-priced epochs but no `deadline` / `minSharesOut` / `maxAssetsOut` parameter — A request held in mempool can settle at an arbitrarily worse rate; ERC-7540-by-design but no on-chain rails.
- **Zero-`totalAssets` close epoch produces stored rate = 0, bricking conversions** — `StableYieldAsyncVault.onCloseEpoch` — Code smells: `epochRate = 0 * 1e18 / supply = 0` when FM is drained yet supply > 0 — `convertToShares`/`convertToAssets` become permanently broken or return 0; `_settleDepositIfNeeded` for any deposit in that epoch divides by zero.
- **`_rebalanceYieldAssets` adds unconditional `+1` overshoot regardless of decimals** — `AsyncFundManager._rebalanceYieldAssets / evaluateFunding` — Code smells: `+ 1` is a decimals-clipping buffer that's correct for `SCALING_FACTOR > 1` but pure overshoot for 18-dec underlyings — 1 wei per call moves from unutilized into yield reserve over thousands of rebalances.
- **`totalClaimableRedeemAssets` accumulates uncreditable dust forever** — `StableYieldAsyncVault.onSettleEpoch / _claimRedeem` — Code smells: aggregate `mulDiv(snap.redeemingShares, snap.rate, SCALE)` increment ≥ Σ per-user `mulDiv(pendingShares_i, rate, SCALE)` decrements — Stranded underlying matching the residue accumulates in the vault permanently; mirror of finding #7 on the redeem side.
- **`_toUnit` does an unchecked uint256 → uint128 downcast** — `AsyncFundManager._toUnit` — Code smells: silent wrap if `underlyingAmount / RAW_PER_UNIT > type(uint128).max` — Realistic only for very large per-epoch deposits or 6-dec exotic tokens at scale, but no `SafeCast` despite OZ being available.
- **Aggregate `claimableDeposit*` blends multiple settled epoch rates** — `StableYieldAsyncVault._claimDeposit` — Code smells: `claimableDepositAssets`/`claimableDepositShares` sum across multiple lazy-settled epochs at different rates; partial `_deposit(assets)` then operates at the blended ratio — Adversarial timing of claims (potentially with operator collusion) can mis-allocate shares vs claiming epoch-by-epoch.
- **Bootstrap-rate "charity" rewards first depositor with pre-existing FM balance** — `StableYieldAsyncVault.onCloseEpoch` — Code smells: `effectiveSupply == 0` short-circuits to rate = 1e18 ignoring pre-existing FM underlying/yield balance — If FM is funded via `give` before any user deposits (common in operator-bootstrapped deployments), the first depositor receives a share whose immediate NAV exceeds what they paid.
- **Vault-balance partition invariant not enforced on-chain** — `StableYieldAsyncVault.settleEpoch` — Code smells: documented invariant `balanceOf(vault) == totalPendingDepositAssets + totalClaimableRedeemAssets` has no `assert`/`require`; anyone can transfer extra underlying to the vault address; no post-settlement balance check — A buggy/reentered FM deficit pull could under-collateralize redeemers while the partition counters still tally.
- **`onRequestRedeem` ceil-rounds GDA units off — yield-share decays vs NAV-share** — `AsyncFundManager.onRequestRedeem` — Code smells: `delta = ceil(userUnits * sharesRedeemed / totalSharesOwned)` rounds against the redeemer; combined with floor on `_toUnit` at deposit, repeat redeem-then-deposit erodes yield entitlement vs share entitlement.
- **Misconfigured deploy defaults — `getPolygonMainnetConfig` returns all-zeros** — `script/config/NetworkConfig.sol` — Code smells: every field is `address(0)` / `0` / empty string with no validation in `Deploy.s.sol` or `StableYieldVaultDeployer._deploy` — A maintainer filling in only some fields can ship with `fundAdmin = address(0)` (OZ AccessControl will silently grant `DEFAULT_ADMIN_ROLE` to address(0)), permanently locking ops.
- **`StableYieldVaultDeployer._deploy` is a thin pass-through with no input validation** — `script/StableYieldVaultDeployer.sol` — Code smells: no zero-address checks, no rate bounds, no non-empty share-name/symbol — Defense-in-depth gap; the only safety net is FM's constructor checks.
- **`ensureYieldFlowDuration` always rebalances even when only restart is intended** — `AsyncFundManager.ensureYieldFlowDuration` — Code smells: no view-only "restart flow" alternative; combined with `take()` and operator's other powers, expands the operator-trust surface.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
