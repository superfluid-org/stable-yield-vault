# Open Design Questions

## 2. GDA Units: Request Time vs. Claim Time — RESOLVED

**Decision:** Option A (units at request time), with a per-era committed `annualRate`.

See [StableYieldReserve design — D3](./stable-yield-reserve.md#d3-annualrate-is-a-per-era-committed-rate-resolves-i3-and-i9) for the full rationale. Summary:
- Units are incremented on `requestDeposit` (asset-basis) and decremented on `requestRedeem` (proportional to `sharesRedeemed / totalSharesOwned`).
- Carve-outs are sized against the committed `annualRate`; `flowRate` is recomputed on every deposit/redeem to preserve the rate.
- Yield adjustment is handled at era boundaries via the NAV-buffer policy (Policy ⓐ), not per-request clawbacks.

---

## 3. Fee-on-Transfer Tokens

**Problem:** The vault currently does not account for fee-on-transfer (FoT) tokens — tokens that deduct a fee on every `transfer`/`transferFrom` call, meaning the received amount is less than the sent amount.

### Impact

If a FoT token were used as the vault's underlying asset:
- **Deposit accounting would be incorrect:** `requestDeposit(assets)` records `assets` as the deposited amount, but the vault would actually receive `assets - fee`. This inflates the user's claim relative to the vault's real balance.
- **Settlement would be insolvent:** `settleEpoch` would attempt to deploy the full recorded amount to the strategy, but the vault holds less than expected.
- **Redemptions would fail or shortchange users:** Withdraw/redeem calculations based on recorded totals would exceed available balances.

### Options

**A) Explicitly do not support FoT tokens (recommended)**
- Document the restriction clearly in the contract NatSpec and deployment guidelines.
- Add no extra code — keep the vault lean and gas-efficient.
- This is consistent with most major vault implementations (e.g., ERC-4626 reference, Yearn V3, Morpho).

**B) Support FoT tokens**
- Measure actual received amounts via balance-before/balance-after on every transfer-in.
- Adds gas overhead and complexity to every deposit and settlement path.
- Increases attack surface (read-only reentrancy on balance checks, donation attacks).

**Decision:** NOT SUPPORTED. 

---