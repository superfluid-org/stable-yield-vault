# Deposit Flow

How a deposit (or mint) moves through the system. Deposit is a single synchronous
transaction — there is no waiting room, epoch, snapshot, or settlement. See
[`../design.md`](../design.md) for the model and [`../invariants.md`](../invariants.md)
for the properties.

## Contracts involved

| Contract | Role |
|---|---|
| **StableYieldSyncVault** | ERC-4626 face. Pulls underlying from the caller, forwards it to the FundManager, mints shares. Holds no assets |
| **SyncFundManager** | Sole custodian. Owns the external-vault shares and the super-token reserve. Pre-funds the reserve, deploys the remainder into the external vault, starts the stream |
| **External ERC-4626** | Morpho Vault V2 that custodies the principal and earns the real, compounding yield (`max*` hardcoded 0 — never consulted; position valued via `previewRedeem`, eligibility via gate views) |
| **GDA Pool** | Superfluid pool owned by the FM. Streams the yield super-token to unit holders |

## Asset locations

| Location | What lives there |
|---|---|
| Investor wallet | The underlying being deposited |
| External vault (held by FM) | Deployed principal + the compounding external surplus. Valued via `EXTERNAL_VAULT.previewRedeem(balanceOf(FM))` |
| Reserve (FM, super-token) | The pre-fund slice that funds the GDA stream. Counted in NAV via `scaledYieldAssetsBalance()` |
| FM (raw underlying) | Transient only — 0 at rest (custody hazard, [A.1](../invariants.md#a1--no-raw-underlying-at-rest-in-the-fundmanager-echidna)) |

## Sequence

```mermaid
sequenceDiagram
    participant I as Investor
    participant V as StableYieldSyncVault
    participant FM as SyncFundManager
    participant E as External ERC-4626
    participant POOL as GDA Pool

    I->>V: deposit(assets, receiver)
    Note right of V: nonReentrant · whenDepositable — maxDeposit binary via FM.canDepositExternal() (gate views)
    V->>V: net = assets − DEPOSIT_FEE  %% reverts DEPOSIT_BELOW_FEE if assets ≤ fee
    V-->>I: safeTransferFrom DEPOSIT_FEE (caller → TREASURY)
    V->>FM: safeTransferFrom net underlying (caller → FM)
    V->>V: _mint(receiver, shares)
    Note right of V: shares ≈ net (NAV-neutral entry)
    V->>FM: onDeposit(receiver, net)
    FM->>POOL: increaseMemberUnits(receiver, _toUnit(assets))
    FM->>FM: _rebalanceYieldAssets()  %% top up the reserve from the external position (deficit only)
    FM->>FM: _upgrade(min(max(deficit / SCALING_FACTOR + 1, MIN_EXTERNAL_PULL), assets))  %% pre-fund the residual
    FM->>E: deposit(assets − upgraded, FM)  %% deploy the remainder as principal
    FM->>POOL: _recalibrateFlow()  %% stream starts/raises now
```

## Step by step

1. **Vault entry.** `deposit(assets, receiver)` (or `mint`, or `depositWithPermit` which
   first consumes an EIP-2612 permit). `nonReentrant`, `whenDepositable` (reverts
   `VAULT_TERMINATED` after the admin's one-way `terminate()`). OZ checks
   `assets <= maxDeposit(receiver)`, which is binary: `type(uint256).max` while the vault
   is not terminated and the FM's deposit-side gates clear
   (`FUND_MANAGER.canDepositExternal()`), else 0. `assets` is **gross**: shares are priced
   on the net `previewDeposit(assets) = (assets − DEPOSIT_FEE) · (totalSupply + 10**offset)
   / (totalAssets + 1)`. Because the deposit raises external principal + reserve by exactly
   the net amount, NAV/supply is preserved and `shares ≈ net` at entry.

2. **`_deposit`.** Revert `DEPOSIT_BELOW_FEE` if `assets <= DEPOSIT_FEE` (`0.2e6`, 0.2 USDC).
   Transfer `DEPOSIT_FEE` from the caller to `TREASURY` and the net `assets − DEPOSIT_FEE`
   from the caller straight to the FM, `_mint` the shares (the `_update` hook skips
   `onShareTransfer` on the mint leg), then call `FUND_MANAGER.onDeposit(receiver, net)`.
   (`mint(shares)` charges the fee on top of the assets needed for `shares`.)

3. **`onDeposit(receiver, assets)`** (`VAULT_ROLE`):
   - **Grant units.** `units = _toUnit(net) = net / RAW_PER_UNIT` (one whole token
     → `1e6` units; `RAW_PER_UNIT = 1` for the pinned 6-dec underlying, so every atom of
     net principal buys a unit).
     The reserve target now reflects the new, higher unit count.
   - **Top up the reserve.** `_rebalanceYieldAssets()` pulls
     `min(deficit / SCALING_FACTOR + 1, externalPositionValue())` from the external
     position and upgrades it — only the *deficit*, so the external surplus stays
     compounding, and only when the pull is at least `MIN_EXTERNAL_PULL` (10 atoms; the
     Base USDCx wrapper routes its reserves into Aave v3, which reverts dust supplies —
     a skipped sub-dust shortfall self-corrects). No external calls when already
     solvent. The cap is the position's *value* (Morpho V2 has no liquidity view), so
     the pull can revert on an external liquidity shortfall and brick the deposit until
     liquidity returns (accepted; `forceDeallocate` unsticks).
   - **Pre-fund the residual.** If a deficit remains, upgrade
     `min(max(deficit / SCALING_FACTOR + 1, MIN_EXTERNAL_PULL), assets)` of the
     incoming underlying into the reserve (the floor keeps the upgrade
     wrapper-acceptable and the GDA buffer fundable on dust bootstrap deposits;
     sub-`MIN_EXTERNAL_PULL` deposits onto an empty reserve are not viable).
   - **Deploy the remainder.** `EXTERNAL_VAULT.deposit(assets − upgraded, FM)`. Nothing is
     left at rest in the FM.
   - **Recalibrate.** `_recalibrateFlow()` starts/raises the stream this block, including
     for the first deposit. The hook cannot run under terminal impairment because the
     vault is paused (`maxDeposit == 0`) there.

## Why the stream starts now (and is NAV-neutral)

- A Superfluid stream cannot be partially started — `distributeFlow` needs the whole
  reserve to back the whole flow. The deficit-only rebalance pulls any pre-existing
  shortfall from the external position; the residual pre-fund covers whatever the external
  position could not. In every non-terminal state the post-deposit deficit is `≤ 0`, so the
  recalibrate brings the stream live.
- The deposit only changes the *form* of the FM's assets: `assets` of underlying becomes
  `(assets − upgraded)` external principal + `upgraded` reserve, **both counted in NAV**.
  So `totalAssets` rises by exactly `assets`, the share price is unchanged at entry, and
  the depositor is not diluted by funding their own stream — the pre-fund returns to them
  out-of-band as the stream while the external position replenishes the reserve. After
  entry the share floats with the external vault.

