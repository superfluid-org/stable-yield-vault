# X-Ray Report

> StableYieldAsyncVault | 524 nSLOC | 9470350 (`main`) | Foundry | 23/04/26

Analyzed branch: `main` at `9470350`.

---

## 1. Protocol Overview

**What it does:** ERC-7540 async vault with epoch-based two-phase settlement that streams yield to depositors continuously via a Superfluid GDA pool.

- **Users**: Depositors supply an ERC-20 (e.g. USDC) and receive non-transferable shares; they later redeem for underlying plus an accrued yield stream.
- **Core flow**: `requestDeposit` → operator `closeEpoch`/`settleEpoch` → `deposit`/`mint` claim → yield streams in real time via GDA → `requestRedeem` → operator settles → `redeem`/`withdraw` claim.
- **Key mechanism**: Epoch-based NAV snapshot (`closeEpoch`) + netted settlement (`settleEpoch`) with asset-basis pool units. `annualRate / 1y` per-unit stream funded from FundManager's super-token balance.
- **Token model**: Share token = vault itself (ERC-20, soul-bound — `transfer`/`transferFrom` revert). Underlying ERC-20 `ASSET`. Superfluid `SUPER_TOKEN` wraps underlying for the GDA flow. GDA pool units, asset-basis, non-transferable.
- **Admin model**: `DEFAULT_ADMIN_ROLE` (wires the vault once via `setVault`), `FUND_OPERATOR_ROLE` (all operational levers), `VAULT_ROLE` (granted to the vault in `setVault` for hook calls). No timelock, no pause, no multisig enforced on-chain.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Vault | StableYieldAsyncVault | 349 | ERC-7540 vault: epoch state machine, request/claim lifecycle, share mint/burn |
| Fund Management | FundManager | 175 | GDA pool admin, stream distributor, stream-solvency invariant enforcer |

Total in-scope: **524 nSLOC** across 2 contracts. Six interfaces (IFundManager + 5 ERC-7540/7575 interfaces) are excluded from scope but read for context.

### How It Fits Together

The core trick: asset-basis pool units tie a user's deposited underlying amount (not share count) directly to a Superfluid stream rate, so the per-unit yield rate stays constant (`annualRate/1y`) regardless of share-price drift, and the FundManager self-holds units for unclaimed depositors so the self-stream slice round-trips back into its own buffer.

### Deposit & Claim

```
User.requestDeposit(assets, controller, owner)                                  [Vault]
  ├─ _settleDepositIfNeeded(controller)          // lazy: pending → claimable at last epoch rate
  ├─ ASSET.safeTransferFrom(owner, vault, assets)  // vault custodies pending assets itself
  ├─ cs.pendingDepositAssets += assets; totalPendingDepositAssets += assets
  └─ cs.depositRequestEpoch = currentEpoch

Operator.closeEpoch(workingAssets)                                              [FundManager]
  ├─ totalFundAssets = workingAssets + unutilized + scaledYield
  └─→ Vault.closeEpoch(totalFundAssets)                                         [Vault, onlyFundManager]
        ├─ effectiveSupply = totalSupply + _unclaimedDepositShares - _unclaimedRedeemShares
        ├─ epochRate = totalFundAssets * 1e18 / effectiveSupply  (or 1e18 if supply==0)
        ├─ _snapshot = (epoch, depositingAssets, redeemingShares, rate)        *lock the epoch*
        └─ currentEpoch++; totalPending{Deposit,Redeem} = 0

Operator.settleEpoch()                                                          [FundManager]
  ├─ require(canSettleEpoch())                  // buffer check + redeem-deficit check
  ├─ snap = vault.getSnapshot()
  ├─→ Vault.settleEpoch()                                                       [Vault, onlyFundManager]
  │     ├─ redeemingAssets = snap.redeemingShares * snap.rate / 1e18
  │     ├─ totalClaimableRedeemAssets += redeemingAssets                       *earmark*
  │     ├─ if surplus: ASSET.safeTransfer(FM, surplus)                         *vault → FM*
  │     ├─ else deficit: FM.move(vault, deficit)                               *FM → vault*
  │     ├─ _unclaimedDepositShares += ...; _unclaimedRedeemShares += redeemingShares
  │     └─ _epochRate[e] = rate; _epochSettled[e] = true; delete _snapshot
  ├─ POOL.increaseMemberUnits(FM, depositingAssets)   *FM self-holds units*
  ├─ _recalibrateFlow()                         *distributeFlow(totalUnits * rate/yr)*
  └─ _assertInvariant()

User.deposit(assets, receiver, controller) / mint(...)                          [Vault]
  ├─ shares = assets * claimableShares / claimableAssets
  ├─ _mint(receiver, shares); _unclaimedDepositShares -= shares
  └─→ FundManager.onClaimDeposit(receiver, assets)                              [FM, VAULT_ROLE]
        ├─ POOL.decreaseMemberUnits(FM, assets)
        └─ POOL.increaseMemberUnits(receiver, assets)   *stream now flows to user*
```

### Request Redeem & Claim

```
User.requestRedeem(shares, controller, owner)                                   [Vault]
  ├─ require(_snapshot.epoch == 0)              *no request during closed-but-not-settled window*
  ├─ _settleRedeemIfNeeded(controller)
  ├─ totalSharesOwned = balanceOf(owner)
  ├─→ FundManager.onRequestRedeem(controller, shares, totalSharesOwned)         [FM, VAULT_ROLE]
  │     ├─ delta = userUnits * shares / totalSharesOwned  (ceil)
  │     ├─ POOL.updateMemberUnits(controller, userUnits - delta)               *stream cut*
  │     └─ _recalibrateFlow()
  └─ _transfer(owner, address(this), shares)   *shares locked on vault itself*

Operator.closeEpoch(...) → Operator.settleEpoch() [as above — redeem leg may pull from FM via move()]

User.redeem(shares, receiver, controller) / withdraw(...)                       [Vault]
  ├─ assets = shares * claimableAssets / claimableShares  (withdraw rounds shares up)
  ├─ totalClaimableRedeemAssets -= assets; _unclaimedRedeemShares -= shares
  ├─ _burn(vault, shares)
  └─ ASSET.safeTransfer(receiver, assets)      *assets paid from vault's earmarked balance*
```

### Operator Funding & Rate Levers

```
FundOperator.give(amount)     → ASSET.safeTransferFrom(op, FM, amount)          *pre-fund redeems / buffer*
FundOperator.take(amount)     → _assertInvariant(); ASSET.safeTransfer(op, amount)  *only if invariant holds*
FundOperator.upgrade(amt)     → ASSET.approve(superToken); superToken.upgrade(amt * scale)   *buffer into stream*
FundOperator.downgrade(amt)   → superToken.downgrade(amt); _assertInvariant()   *unwrap — must not break invariant*
FundOperator.setAnnualRate(r) → _flowRatePerUnit = scale * r / (YEAR * BP); _recalibrateFlow(); _assertInvariant()
FundOperator.setGuaranteedFlowDuration(d) → guaranteedFlowDuration = d; _assertInvariant()
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Yield Aggregator / Vault** with **Liquid-Staking** characteristics

ERC-7540/4626 vault with a strategy-like backend (`FundManager` holds real liquidity, streams yield). The Superfluid GDA component introduces a rate-reporting surface that behaves like a liquid-staking exchange-rate oracle in miniature: the `annualRate` is set by an off-chain operator and converted on-chain into a flow that affects each share's effective yield (per spec `D5`).

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|--------------|
| User / Controller / Operator-of-Controller | Untrusted | Call `requestDeposit`, `deposit`/`mint`, `requestRedeem`, `redeem`/`withdraw`, `setOperator`. ERC-7540 operators are delegated per-controller and can request/claim on behalf of their grantor. |
| `FUND_OPERATOR_ROLE` | Bounded (off-chain strategy + honest rate-setting) — all levers are **instant, no timelock, no pause** | `closeEpoch`, `settleEpoch`, `give`, `take`, `upgrade`, `downgrade`, `setAnnualRate`, `setGuaranteedFlowDuration`. `take` and `downgrade` are invariant-gated; others are trivially safe or force a `_assertInvariant()` after. |
| `VAULT_ROLE` (the vault contract) | Trusted by FM (vault-contract role granted in `setVault`) | Call `onClaimDeposit`, `onRequestRedeem`, `move` on FM. `move` is an unrestricted `safeTransfer` of ASSET to any recipient. |
| `DEFAULT_ADMIN_ROLE` | Trusted, **one-shot wiring intent but not enforced** (see Attack Surfaces) — instant, no timelock | `setVault` (grants VAULT_ROLE), plus the full AccessControl surface: `grantRole`, `revokeRole`, `renounceRole` over `FUND_OPERATOR_ROLE` and `VAULT_ROLE`. |
| Superfluid protocol (GDA pool, SUPER_TOKEN) | Trusted external dependency | Holds FM's super-token balance, enforces its own liquidation buffer, processes `distributeFlow`. |

**Adversary Ranking** (ordered by threat level for this protocol type):

1. **Compromised `FUND_OPERATOR_ROLE`** — single key with instant authority to drain unutilized asset balance via `take`, starve the stream via `setAnnualRate(0)`, or close/settle epochs at an attacker-chosen NAV. No timelock, no multisig, no pause.
2. **Compromised `DEFAULT_ADMIN_ROLE`** — can grant `FUND_OPERATOR_ROLE` to an attacker; `setVault` wiring surface is one-shot-by-intent but **not actually locked** (see Attack Surfaces).
3. **Share-rounding / first-depositor attacker** — epoch rate uses `effectiveSupply` with a `1e18` bootstrap when supply is zero; first-epoch rate-setting is a classic inflation/zero-share-return attack surface.
4. **Epoch-interleaving attacker** — a user racing `closeEpoch` and `settleEpoch` could potentially interact with the rate transitions (requestRedeem gated by `_snapshot.epoch == 0`, but other claim-path flows are not).
5. **Malicious controller / operator-of-controller** — ERC-7540 delegation surface: `setOperator`, plus the `controller` parameter on `requestDeposit` and `requestRedeem` makes griefing via third-party `depositRequestEpoch` overwrites a concern.
6. **Strategy / external-dependency drift** — operator reports `workingAssets` off-chain in `closeEpoch`; mis-report inflates or deflates NAV. The vault has no independent check.

See [entry-points.md](entry-points.md) for the full permissionless entry point map (9 permissionless, 11 role-gated, 1 admin-only in the source; AccessControl contributes additional admin surface).

### Trust Boundaries

- **User → Vault.** Users custody their assets to the vault on `requestDeposit`. The vault is trusted to partition its balance via `totalPendingDepositAssets` and `totalClaimableRedeemAssets` counters; no on-chain invariant check reconciles these against `ASSET.balanceOf(vault)`. *Git signal: high churn — 27 modifications to `StableYieldAsyncVault.sol`, 9 fix-scored commits (≥5) including three late-window high-score fixes.*
- **Vault → FundManager.** The vault calls FM during request/claim/settle. `onRequestRedeem` decrements pool units without any independent sanity check beyond `totalSharesOwned > 0`. `move` lets the vault pull *any* amount of ASSET from FM to any recipient — the vault is expected to only self-transfer, but `move(recipient, amount)` takes an arbitrary `recipient`. If the vault is ever bug-compromised (e.g. a reentrancy that calls `move` with an attacker-chosen recipient), FM's unutilized balance is exposed.
- **Admin → role-grant surface.** `setVault` is written as one-shot (`if (address(vault) != address(0)) revert VAULT_ALREADY_SET()`), but `vault` is **never assigned** by `setVault` — only VAULT_ROLE is granted. The revert is dead code; admin can call `setVault` repeatedly and grant VAULT_ROLE to multiple addresses (see Attack Surfaces).
- **FundManager → Superfluid.** FM is the pool admin and a connected pool member. It trusts SUPER_TOKEN's `availableBalanceOf` netting and the pool's unit accounting. An upgrade or governance change on the Superfluid side could silently break the invariant arithmetic (cast-widening, flow-rate precision, self-slice timing).

### Key Attack Surfaces

- **`setVault` does not assign `vault`** — `FundManager.setVault` (`FundManager.sol:217-225`) only grants `VAULT_ROLE` but never writes to the `vault` storage variable. The `VAULT_ALREADY_SET` guard (`FundManager.sol:219`) checks `address(vault) != address(0)` — since `vault` stays zero, this revert never fires. Admin can grant `VAULT_ROLE` to multiple addresses, and any subsequent call to `FundManager.closeEpoch` (`FundManager.sol:142`) or `FundManager.settleEpoch` (`FundManager.sol:150-153`) — which do `vault.closeEpoch(...)` / `vault.getSnapshot()` — will revert calling into address(0). Deployment is effectively broken until this is fixed; separately, once fixed the multi-grant behavior needs to remain one-shot.
- **`FundManager.move` takes arbitrary `recipient`** — `move(address recipient, uint256 amount)` (`FundManager.sol:265-267`) is `onlyRole(VAULT_ROLE)` and unconditionally transfers any amount to any address. The vault's intended use is `FM.move(address(this), deficit)` during `settleEpoch` (`StableYieldAsyncVault.sol:250`). Any bug in the vault that lets an attacker route the `recipient` parameter — or any future caller granted VAULT_ROLE — can drain FM's unutilized ASSET balance in one call.
- **Epoch rate is computed from operator-reported NAV with no independent check** — `FundManager.closeEpoch` (`FundManager.sol:139-143`) accepts `workingAssets` from the operator and sums it with `unutilizedAssetsBalance()` and `scaledYieldAssetsBalance()`. An over-reported `workingAssets` inflates the rate (dilutes depositors), an under-report deflates it (dilutes stayers). Only the on-chain terms are verifiable; the off-chain strategy balance is fully trusted.
- **Instant operator levers over funds and stream** — `setAnnualRate` (`FundManager.sol:194-206`), `take` (`FundManager.sol:172-177`), `downgrade` (`FundManager.sol:186-191`), and `setGuaranteedFlowDuration` (`FundManager.sol:209-215`) all execute in a single transaction without timelock or pause. A compromised operator can drain unutilized balance to the invariant floor (`take`), zero the stream (`setAnnualRate(0)`), or collapse the buffer horizon to `MIN_GUARANTEED_FLOW_DURATION` (1 day) and then `take` the slack.
- **Stream-solvency invariant is partially enforced** — `_assertInvariant` (`FundManager.sol:346-348`) is called on `take`, `downgrade`, `setAnnualRate`, `setGuaranteedFlowDuration`, `settleEpoch`. It is **not** called on `give`, `upgrade`, `onRequestRedeem`, `onClaimDeposit`. `onRequestRedeem` monotonically shrinks flow so is safe; `onClaimDeposit` has no effect on total units; `give`/`upgrade` are monotone increases. The trivially-safe claim is only valid if flows can't underflow `int96` or the multiplication `UNIT_PER_ASSET_DEPOSITED * depositingAssets` can't overflow `uint128`.
- **`uint128` / `int96` casts from `uint256` in pool-unit and flow arithmetic** — `POOL.increaseMemberUnits(FM, uint128(snap.depositingAssets * UNIT_PER_ASSET_DEPOSITED))` (`FundManager.sol:157`), `uint128(depositAssets * UNIT_PER_ASSET_DEPOSITED)` (`FundManager.sol:236-237`), `int96(int128(POOL.getTotalUnits()))` (`FundManager.sol:342`), `int96(int256(SUPER_TOKEN_SCALE * newRate / (YEAR * _BP_DENOMINATOR)))` (`FundManager.sol:126, 200`). `UNIT_PER_ASSET_DEPOSITED` is 1 so the first two boil down to casting `uint256 → uint128`, which silently truncates above 2^128. No explicit bounds checks.
- **`canSettleEpoch` precondition has documented footgun** — `FIXME: 1e18 here might be a footgun` at `FundManager.sol:322`. The `redeemingAssets = snap.redeemingShares.mulDiv(snap.rate, 1e18)` computation is also performed identically inside `Vault.settleEpoch` (`StableYieldAsyncVault.sol:234`) — if one formula drifts from the other during future changes, preconditions and actual settlement will diverge.
- **First-epoch / zero-supply rate bootstrap** — `Vault.closeEpoch` (`StableYieldAsyncVault.sol:206`) sets `epochRate = 1e18` when `effectiveSupply == 0`. A single wei deposit followed by a large unaccounted-for transfer *into the FundManager* before `closeEpoch` inflates `totalFundAssets` (operator's `workingAssets` + FM unutilized balance), which when divided by the tiny `effectiveSupply` gives a very high rate; subsequent depositors mint few shares at that rate. The classic vault-inflation vector applies via the FM balance rather than the vault balance.
- **`settleEpoch` reentrancy across cross-contract callback** — `Vault.settleEpoch` calls `FundManager.move(vault, deficit)` which does `ASSET.safeTransfer(recipient, amount)` (`FundManager.sol:266`). If ASSET is a callback-capable token (ERC-777 / hook-on-receive), the recipient is the vault itself — state at that moment: `totalClaimableRedeemAssets += redeemingAssets` already done but `_unclaimedDepositShares` / `_unclaimedRedeemShares` updates not yet committed, `_snapshot` not yet deleted. FM's own path also calls `vault.settleEpoch()` *before* `POOL.increaseMemberUnits` and `_recalibrateFlow`, so the FM-level invariant is asserted at the very end. A standard ERC-20 is fine; ASSET choice is therefore load-bearing.
- **`setOperator` blanket approval** — `Vault.setOperator(operator, true)` (`StableYieldAsyncVault.sol:272`) grants the operator full request/claim authority over the grantor. ERC-7540 standard, but worth flagging: a compromised operator address can `requestRedeem(allShares, attackerController, grantor)` and later `redeem(all, attacker, attackerController)`.
- **Lazy settlement under epoch-rate drift** — `_settleDepositIfNeeded` / `_settleRedeemIfNeeded` (`StableYieldAsyncVault.sol:516-558`) convert pending → claimable at the **request-epoch's** rate, not the current rate. Correct by design, but the combination with `claimableDepositAssets`/`claimableDepositShares` pre-computation means that a user who interleaves `requestDeposit` across two epochs can have one rate applied retroactively to the older pending — verify that `_settleDepositIfNeeded` is called before every path that would add new pending (it is called in `requestDeposit` at line 107, covering this).

### Upgrade Architecture Concerns

The protocol is **not upgradeable** — no proxy pattern, no `initialize()`, no upgrade authorization. `FUND_MANAGER` is immutable on the vault; `ASSET`, `SUPER_TOKEN`, `POOL`, `SUPER_TOKEN_SCALE` are immutable on the FundManager. Storage-layout and implementation-swap risks do not apply.

### Protocol-Type Concerns

**As a Yield Aggregator / Vault:**
- **Share-price bootstrap**: `effectiveSupply == 0 → rate = 1e18` (`StableYieldAsyncVault.sol:206`) is the only defense; no minimum initial deposit, no virtual-share offset, no dead-shares reservation. Combined with `totalFundAssets = workingAssets + unutilized + scaledYield` (where unutilized is `ASSET.balanceOf(FM)`), a direct ASSET transfer to FM before the first `closeEpoch` is a donation vector that raises the bootstrap rate for the first depositor.
- **`totalAssets()` returns last snapshot, not live** — `StableYieldAsyncVault.sol:353-360` returns `_lastReportedTotalAssets` frozen at the last `closeEpoch`. Any integrating contract that reads `totalAssets()` between settlements sees stale NAV. Documented in a `NOTE`.
- **Rounding direction in `_withdraw` and `_mintShares`** — `shares = assets.mulDiv(claimableShares, claimableAssets, Math.Rounding.Ceil)` (`StableYieldAsyncVault.sol:446`) for `_withdraw` and `assets = shares.mulDiv(claimableAssets, claimableShares, Math.Rounding.Ceil)` for `_mintShares` (`StableYieldAsyncVault.sol:430`) both round "against the user" (favors vault). `_deposit` and `_redeem` round down. Review whether all four directions align with the ERC-4626/7540 monotonicity requirements; the rounding-issue fix `34806fb` (score 12) landed 6 days before HEAD and touched exactly this path.

**As a Liquid-Staking-like system:**
- **Rate-reporting (annualRate) is the exchange-rate analog** — off-chain operator decides the stream rate, on-chain invariant only checks forward-solvency of what's committed, not correctness of the commitment. If the operator over-commits (sets `annualRate` above strategy yield for an extended period), NAV drifts down and the share-price absorbs the miss — a documented design choice (spec §NAV Dynamics), but the on-chain enforcement is a floor, not a ceiling.
- **Unclaimed shares tracked globally, not per-epoch** — `_unclaimedDepositShares`/`_unclaimedRedeemShares` (`StableYieldAsyncVault.sol:53-56`) are aggregate counters. The `FIXME` at `StableYieldAsyncVault.sol:261` (`verify below formula (should this account for unclaimed redeeming/depositing shares?)`) flags that the team itself is unsure of the `totalAssetValue` event formula inside `settleEpoch`.

### Temporal Risk Profile

**Deployment & Initialization:**
- `FUND_MANAGER` is set as **immutable** in the vault constructor (`StableYieldAsyncVault.sol:88`), but `FundManager.vault` must be wired post-deploy via `setVault`. Deploy order: FM → Vault (passing FM) → `FM.setVault(vault)`. The `setVault` bug described above makes this wiring a **hard blocker** right now, not just a risk window.
- No `initialize()` function, no separate deploy → init window to front-run.
- Constructor requires `ISuperToken(_superToken).getUnderlyingToken() == address(ASSET)` (`FundManager.sol:105`) — good. Does **not** verify `ISuperToken.getUnderlyingDecimals() <= 18`, which matters because `SUPER_TOKEN_SCALE = 10 ** (18 - underlyingDecimals)` (`FundManager.sol:109`) underflows for 19-decimal tokens (pre-0.8 would wrap; under 0.8.34 it reverts — acceptable, but flagging).
- `_grantRole(DEFAULT_ADMIN_ROLE, msg.sender)` at construction (`FundManager.sol:112`). Admin is the deployer EOA unless subsequently transferred. There is no two-step transfer guard.

**Market Stress:**
- **Liquidity shortfall on redeem-heavy epoch** — `canSettleEpoch` returns false if FM lacks unutilized assets to cover the redeem-deposit deficit (`FundManager.sol:324-328`). Operator must `give` or unwind strategy before retry. Documented mitigation, not an on-chain fix.
- **`int96` flow-rate ceiling** — `int96(int256(SUPER_TOKEN_SCALE * newRate / (YEAR * _BP_DENOMINATOR)))` (`FundManager.sol:126, 200`) clips any rate high enough that the per-unit flow rate overflows int96. For USDC (SUPER_TOKEN_SCALE=1e12, YEAR=31,536,000, BP=10_000) the per-unit wei/s rate is `newRate * 1e12 / 3.15e11 ≈ newRate * 3.17`. int96 fits up to ~3.96e28, so this is not a realistic constraint. Flagging because silent truncation in `int96(int256(...))` without bounds check is the kind of thing that bites at scale.
- **`_targetFlowRate` overflow** — `_flowRatePerUnit * int96(int128(POOL.getTotalUnits()))` (`FundManager.sol:342`). `_flowRatePerUnit` and `getTotalUnits()` multiplied in int96 space; if totalUnits exceeds `int96_max / _flowRatePerUnit`, the multiplication overflows. For USDC at 5% APR, `_flowRatePerUnit ≈ 1.585e8`. int96_max ≈ 3.96e28 / 1.585e8 ≈ 2.5e20 units. One unit per 1 wei USDC (6 decimals) → break around `2.5e14` USDC. Not imminent but not absurdly far either.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **SUPER_TOKEN (Superfluid super-token wrapper)** — via `FundManager.sol:121, 126, 157, 181, 187, 236-237, 282, 292, 314-318, 338`
> - Assumes: `getUnderlyingToken()` / `getUnderlyingDecimals()` never change; `upgrade(x)` mints exactly `x` super-tokens consuming `x / SUPER_TOKEN_SCALE` underlying; `availableBalanceOf` correctly nets buffers; `distributeFlow`/`connectPool`/`createPool` semantics are stable.
> - Validates: underlying token match at construction (`FundManager.sol:105`). Decimals are read once at construction (`FundManager.sol:108-109`). No runtime validation after deployment.
> - Mutability: Superfluid protocol is governed by Superfluid's own upgrade mechanism. Behavior can change across Superfluid versions.
> - On failure: most super-token calls revert; `distributeFlow` failure would revert any path that recalibrates flow.

> **ISuperfluidPool (GDA pool created at FM construction)** — via `FundManager.sol:118, 157, 236-237, 249, 259, 315, 338`
> - Assumes: `updateMemberUnits`/`increase`/`decreaseMemberUnits` strictly atomic, `getTotalUnits` returns exact post-state, unit type is uint128, non-transferable units enforced (configured `transferabilityForUnitsOwner: false`).
> - Validates: pool is FM-owned (created with `createPool(address(this), ...)`), so no cross-pool confusion.
> - Mutability: pool lives inside Superfluid's governed protocol.
> - On failure: revert propagates up the call chain — `settleEpoch`, `requestRedeem`, `deposit`/`mint` all fail if the pool reverts.

> **ASSET (ERC-20 underlying)** — via `StableYieldAsyncVault.sol:110, 244, 493` and `FundManager.sol:167, 175, 180, 266, 277`
> - Assumes: standard ERC-20, no fee-on-transfer, no rebasing, no hook-on-transfer (transfers do not reenter), 6-18 decimals.
> - Validates: none at runtime. `SafeERC20` handles non-reverting returns but not fee-on-transfer accounting drift.
> - Mutability: immutable address once constructor runs; behavior depends on the token (USDC is upgradeable).
> - On failure: revert. Deny-list ASSETs (USDC/USDT blacklist) would freeze specific controllers' deposits and redeems.

**Token Assumptions** *(unvalidated only)*:
- Fee-on-transfer: if ASSET charges a transfer fee, `requestDeposit` credits `assets` to `pendingDepositAssets` but the vault receives `assets - fee` — internal accounting overstates real balance, invariant `balanceOf(vault) == totalPendingDepositAssets + totalClaimableRedeemAssets` (stated in `StableYieldAsyncVault.sol:66`) breaks silently.
- Rebasing: not applicable to most stablecoins but worth ruling out if ASSET choice is extended.
- Hook-on-transfer: ERC-777-style ASSET is not expected for a stable-yield vault, but no explicit whitelist; the `Vault.settleEpoch → FundManager.move → safeTransfer(vault, ...)` chain opens a reentrancy surface if one is used.
- Decimals ≤ 18: enforced implicitly (19+ would revert in constructor on underflow at `FundManager.sol:109`). Fine as a gate.

**Shared State Exposure:** FM is the sole owner of its GDA pool; the pool is not shared with other protocols. SUPER_TOKEN is Superfluid's global asset; flows aren't shared-resource sensitive but FM's `availableBalanceOf` is netted against *all* flows FM participates in — currently only this one.

---

## 3. Invariants

### Stated Invariants

- **Stream solvency (enforced):** `availableBalanceOf(FM) >= actualFlowRate * GUARANTEED_FLOW_DURATION` — spec §Stream Solvency Invariant; implemented as `evaluateYieldAssetsDeficit() == 0` called by `_assertInvariant` (`FundManager.sol:291-300, 346-348`). Enforced on `take`, `downgrade`, `setAnnualRate`, `setGuaranteedFlowDuration`, `settleEpoch`. (per spec + per code)
- **Vault ASSET partition (stated, not checked):** `underlyingAsset.balanceOf(vault) == totalPendingDepositAssets + totalClaimableRedeemAssets` — `StableYieldAsyncVault.sol:65-67`. No on-chain assertion; relies on every state-changing path updating both sides consistently. (per code comment only)
- **Shares non-transferable:** `transfer` / `transferFrom` revert with `SHARES_NON_TRANSFERABLE` — `StableYieldAsyncVault.sol:280-288`. (per spec D6 + per code)
- **Epoch sequencing:** requests blocked during settlement window via `if (_snapshot.epoch != 0) revert EPOCH_SETTLEMENT_IN_PROGRESS()` in `requestDeposit`/`requestRedeem` (`StableYieldAsyncVault.sol:104, 152`). `closeEpoch` refuses to close if a prior snapshot is unsettled (`:199`). `settleEpoch` requires a non-zero snapshot (`:231`). (per code)
- **ERC-7540 async gate (stated):** `previewDeposit`/`previewMint`/`previewRedeem`/`previewWithdraw` revert with `NOT_SUPPORTED_BY_ASYNC_VAULT` — `StableYieldAsyncVault.sol:387-405`. (per code)
- **Settlement preconditions (stated in NatSpec):** buffer sufficiency + redeem-deficit coverage — `IFundManager.sol:104-109`, implemented as `canSettleEpoch` (`FundManager.sol:303-329`). (per code)

### Inferred Invariants

- **Pool total units reflect live stream obligation**: `POOL.getTotalUnits()` always equals `sum(FM's pending-claim units) + sum(claimed user units)`. Derived from `increaseMemberUnits` on settle, `decrease/increase` swap on claim, `updateMemberUnits(controller, userUnits - delta)` on requestRedeem. If violated: `_recalibrateFlow` would stream at the wrong rate.
- **Monotonic claimable**: `cs.claimableDepositAssets`, `cs.claimableRedeemAssets` only decrease inside `_claimDeposit`/`_claimRedeem`; only increase inside `_settleDepositIfNeeded`/`_settleRedeemIfNeeded`. Derived from `StableYieldAsyncVault.sol:475-494, 516-558`. If violated: double-claim.
- **`totalClaimableRedeemAssets` ≤ vault ASSET balance**: updated in `Vault.settleEpoch:238` and decremented in `_claimRedeem:491`. Vault-level earmark that partitions the single ASSET balance against pending deposits. No on-chain assertion.
- **`POOL.getUnits(FM) + Σ POOL.getUnits(users) == POOL.getTotalUnits()`**: Superfluid should enforce this, but FM's self-share calculation depends on it. If off, the self-stream slice that feeds `availableBalanceOf(FM)` is miscounted.
- **`_flowRatePerUnit * totalUnits` fits int96**: implicit upper bound on (annualRate × totalUnits). No on-chain check; silent clip or revert depending on Superfluid internals.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `README.md` at repo root |
| NatSpec | Thorough on public functions (both contracts) | `IFundManager.sol` and `IStableYieldAsyncVault.sol` interfaces carry full `@notice`/`@dev`/`@param` blocks; implementation file NatSpec via `@inheritdoc` |
| Spec/Whitepaper | Present | `docs/stable-yield-reserve.md` — complete design doc with lifecycle, invariants, D1-D6 design decisions, worked examples |
| Inline Comments | Thorough in hot paths | Strong explanatory comments around settlement, epoch logic, invariant enforcement; 4 open `FIXME` markers in security-critical math (see Tech Debt) |

Spec-derived claims in this report are tagged `(per spec)`. All threat-model and code-behavior observations are derived from reading the current `main` branch source.

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | **0** | File scan (always reliable) |
| Test functions | **0** | File scan (always reliable) |
| Line coverage | 0.00% (0/399 in src/) | `forge coverage` ran successfully — there are simply no tests |
| Branch coverage | 0.00% (0/56 in src/) | same |

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 0 | none |
| Stateless Fuzz | 0 | none |
| Stateful Fuzz (Foundry) | 0 | none |
| Stateful Fuzz (Echidna) | 0 | none |
| Stateful Fuzz (Medusa) | 0 | none |
| Formal Verification (Certora) | 0 | none |
| Formal Verification (Halmos) | 0 | none |

### Gaps

- **No tests exist at all.** The `test/` directory contains no `.t.sol` files. `forge coverage` reports 0/399 lines covered across both source contracts. Every finding in this report is based on source reading — nothing is empirically validated.
- Missing, in audit-impact order for this protocol type: stateful fuzz (epoch state machine, lazy settlement paths), property/invariant tests (stream solvency, vault ASSET partition, pool unit conservation), unit tests for rounding direction across `_deposit`/`_mintShares`/`_redeem`/`_withdraw`, fork tests against a real Superfluid deployment to validate `connectPool`/`distributeFlow`/super-token netting assumptions.

---

## 6. Developer & Git History

> Repo shape: **normal_dev** — 40 source-touching commits across 22 days (2026-03-31 → 2026-04-22) on `main`. All work by a single author.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| Pilou  | 54      | +2660 / -1103      | 100%                |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 1 | Single-developer repo |
| Merge commits | 0 of 54 (0%) | No peer-review via PR merges visible in history — flat commit history |
| Repo age | 2026-03-31 → 2026-04-22 | 22 days |
| Recent source activity (30d) | 40 source-touching commits (all) | Entire repo history is within the late window |
| Test co-change rate | 0% | Measures file co-modification; since there are zero test files, the metric is trivially zero — no residual "fix without test" inference available |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| src/StableYieldAsyncVault.sol | 27 | Highest-churn source file |
| src/FundManager.sol | 10 | Second-highest |
| src/interfaces/vault/IStableYieldAsyncVault.sol | 7 | Interface co-moved |
| src/interfaces/IFundManager.sol | 7 | Interface co-moved |

Older paths (`src/WaitingRoom.sol`, `src/RedeemClaimingRoom.sol`, `src/interfaces/IYieldStrategy.sol`, `src/interfaces/IWaitingRoom.sol`, `src/interfaces/IRedeemClaimingRoom.sol`, `src/interfaces/IStableYieldAsyncVault.sol` at repo root) appear in git log but are **not present on HEAD** — they were removed by `1b49777` (`feat: add streaming yield + remove waiting rooms`) on 2026-04-21 as part of the pivot to the current streaming architecture.

### Security-Relevant Commits

Score = weighted sum of fix-like signals (message keywords, diff patterns, security-domain breadth, shape). ≥10 warrants a manual diff review.

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| 838c293 | 2026-04-22 | fix: review constructor | 14 | tightens access control; 3 security domains |
| a3bc5f4 | 2026-04-22 | fix: updated fundManager and its interface | 14 | rewrites access control; changes fund flows |
| 34806fb | 2026-04-16 | fix: rounding issues | 12 | changes accounting/balance logic; 3 domains |
| 75d92e0 | 2026-04-15 | fix: supply inaccuracy related to unclaimed deposit/redeems | 10 | accounting fix; 3 domains |
| 051208a | 2026-04-14 | fix: lazy settlement logic update | 10 | accounting fix; 4 domains |
| 11f0068 | 2026-04-13 | fix: typo | 10 | spans access_control + fund_flows |
| 34f7567 | 2026-04-13 | feat: draft FundManager | 10 | tightens access control |
| 9470350 | 2026-04-22 | feat: added deploy script | 9 | adds runtime guards; 3 domains |
| da56534 | 2026-04-16 | fix: address audit findings | 9 | 4 domains |
| 75cbb63 | 2026-04-16 | fix: use safeTransfer for `ASSET` transfers + update Natspecs | 9 | 4 domains |

Two score-14 access-control/fund-flow rewrites landed on 2026-04-22, the HEAD day. **The `setVault` bug flagged in Section 2 is within the 838c293 diff window** — the commit that introduced the current `setVault` is `838c293` (`fix: review constructor`).

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| access_control | 33 | FundManager.sol, StableYieldAsyncVault.sol |
| fund_flows | 33 | FundManager.sol, StableYieldAsyncVault.sol, IStableYieldAsyncVault.sol |
| state_machines | 27 | StableYieldAsyncVault.sol, IStableYieldAsyncVault.sol |
| liquidation | 6 | IStableYieldAsyncVault.sol |

Every security domain has been touched in the last 30 days; `access_control` and `fund_flows` saw the most churn and include the two highest-scored fixes.

### Forked Dependencies

| Library | Path | Upstream | Status | Notes |
|---------|------|----------|--------|-------|
| openzeppelin-contracts-v5 | lib/openzeppelin-contracts-v5 | OpenZeppelin | Submodule (untracked in git status — newly added) | Used by FundManager (AccessControl, SafeERC20, ReentrancyGuard). Pragma spans `^0.8.19`-`^0.8.20` — compatible with `0.8.34`. |
| openzeppelin-contracts | (removed) | OpenZeppelin | Removed in `e92a0b9` | Replaced by v5 submodule. Vault still imports from `@openzeppelin/contracts/*` via remappings — verify `remappings.txt` resolves to a submodule present on HEAD (an additional `openzeppelin-contracts` submodule is standard; the `x-ray` enumeration ran with `lib/openzeppelin-contracts-v5/` untracked). |
| ERC-7540-Reference | lib/ERC-7540-Reference | — | Submodule | Reference implementation; not imported by src/. |
| superfluid-protocol-monorepo | lib/superfluid-protocol-monorepo | — | Submodule | Superfluid contracts imported via `@superfluid-finance/*`. |

Two OpenZeppelin paths coexist (`@openzeppelin/contracts/*` used by the vault, `@openzeppelin-v5/contracts/*` used by FundManager). This is intentional (different remappings) but worth noting: any future change to `remappings.txt` could silently swap one for the other.

### Technical Debt Markers

| File:Line | Type | Text | Author | Date |
|-----------|------|------|--------|------|
| src/FundManager.sol:125 | FIXME | this formula needs to be generalized (eg. for regular 1e18 underlying decimals assets) | Pilou | 2026-04-22 |
| src/FundManager.sol:199 | FIXME | this formula needs to be generalized (eg. for regular 1e18 underlying decimals assets) | Pilou | 2026-04-22 |
| src/FundManager.sol:322 | FIXME | 1e18 here might be a footgun | Pilou | 2026-04-22 |
| src/StableYieldAsyncVault.sol:261 | FIXME | verify below formula (should this account for unclaimed redeeming/depositing shares?) | Pilou | 2026-04-14 |

All four are in security-critical paths (rate calculation, settlement precondition, settlement event).

### Security Observations

- **Single-developer, zero-review process.** One author, 54 commits, 0 merge commits. No PR-based review visible in git history. Every line has been written and reviewed by the same person.
- **No tests whatsoever.** 0 test files, 0 test functions, 0% coverage. Post-hoc validation is impossible — the only correctness signals are the 4 `fix:` commits that appear to address real bugs already found.
- **Entire repo is within the "late changes" window.** The protocol was bootstrapped 2026-03-31 and reached HEAD 2026-04-22. All source commits are <30 days old — there is no "settled" legacy code, everything is recent and potentially unfinished.
- **Two score-14 access-control/fund-flow rewrites on HEAD day.** `838c293` (`fix: review constructor`) and `a3bc5f4` (`fix: updated fundManager and its interface`) both landed on 2026-04-22. These are the diffs that introduced the current `setVault` wiring — which contains the "never assigns `vault` storage variable" bug flagged in Section 2.
- **Architectural pivot on 2026-04-21.** Commit `1b49777` (`feat: add streaming yield + remove waiting rooms`, 547 lines changed) replaced the prior `WaitingRoom`-based design with the current Superfluid GDA streaming model. The current design is ~36 hours older than the protocol's earlier structure — mental model from any prior design doc may not align with current code.
- **High churn in accounting math.** `34806fb` (`fix: rounding issues`), `75d92e0` (`fix: supply inaccuracy related to unclaimed deposit/redeems`), and `051208a` (`fix: lazy settlement logic update`) all touch the vault's share-math paths within the last 10 days. Rounding-direction review is a priority.
- **Four open FIXMEs in security-critical math.** Three in `FundManager.sol` on the flow-rate/settle-precondition formulae, one in `StableYieldAsyncVault.sol:261` on the settlement event amount formula. The author has annotated known-uncertain code.

### Cross-Reference Synthesis

- `StableYieldAsyncVault.sol` is both the top file hotspot (27 modifications) and the home of state-machine risks flagged in Section 2 (lazy settlement, bootstrap rate, rounding directions). Highest-priority file for deep review.
- Two fix-score-14 commits on 2026-04-22 rewrote `setVault` / `FundManager` access-control. The identified `setVault` bug (doesn't assign `vault` storage) — flagged as the #1 attack surface — is freshly introduced and has not been retested because no tests exist.
- The FIXME at `FundManager.sol:322` (`1e18 here might be a footgun`) is inside `canSettleEpoch`, which is the single on-chain precondition gate for `settleEpoch` — any asymmetry with the matching computation in `Vault.settleEpoch:234` would allow settlement to proceed with the wrong invariant check.
- `fix: address audit findings` (`da56534`, 2026-04-16) suggests a prior audit happened; the current HEAD is 6 days and multiple high-score rewrites past that point — prior audit artifacts may no longer apply to the current code.

---

## X-Ray Verdict

**EXPOSED** — zero tests, single-developer solo history, no merge/review signals, and two score-14 access-control/fund-flow rewrites on HEAD day without test coverage. The protocol is structurally a POC as far as the harness around the code is concerned, even though the documentation and NatSpec are unusually strong for this stage.

Tier floor set by Tests (0 test files = EXPOSED) and Code Hygiene (4 FIXMEs in security-critical paths). Docs (HARDENED — spec + thorough NatSpec + inline comments) and Access Control (ADEQUATE — roles exist, boundaries are defined, no timelock/multisig/pause) sit higher but cannot pull the tier up.

**Structural facts:**
1. 524 nSLOC across 2 in-scope contracts (StableYieldAsyncVault 349, FundManager 175); 6 interfaces excluded from scope.
2. Zero test files, zero test functions, 0.00% line coverage — `forge coverage` runs cleanly but has nothing to cover.
3. Single author (Pilou), 54 commits over 22 days, zero merge commits, 100% of source lines by one developer.
4. Non-upgradeable: no proxy, no `initialize()`, all major addresses immutable in constructors.
5. 10 fix-scored commits (≥5), two at score 14 on the HEAD day touching access control and fund flows.
6. 4 open FIXMEs, all in security-critical math (rate calculation, settlement precondition, settlement event).
