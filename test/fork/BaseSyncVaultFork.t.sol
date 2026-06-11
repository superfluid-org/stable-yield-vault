// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";

import { Test } from "forge-std/Test.sol";

import { StableYieldVaultDeployer } from "script/StableYieldVaultDeployer.sol";
import { NetworkConfig } from "script/config/NetworkConfig.sol";

import { StableYieldSyncVault } from "src/vault/sync/StableYieldSyncVault.sol";
import { SyncFundManager } from "src/vault/sync/SyncFundManager.sol";

/**
 * @title BaseSyncVaultForkTest
 * @notice Base-mainnet fork suite for the sync vault wired to the REAL production targets:
 *         native USDC, the canonical USDCx wrapper super-token (real Superfluid GDA), and the
 *         live "Steakhouse Prime USDC" Morpho Vault V2.
 *
 *         The fuzzed scenarios emulate production reality: several users depositing relatable
 *         amounts ($1 … $10k with jitter) at staggered times, some withdrawing (partially or
 *         fully) after a short while, while the fund operator performs the scheduled
 *         maintenance (`ensureYieldFlowDuration`) at most every 12 hours.
 *
 *         Run with:    forge test --match-contract BaseSyncVaultForkTest -vvv
 *         Env knobs:   BASE_RPC_URL          (default: https://mainnet.base.org)
 *                      BASE_FORK_BLOCK_NUMBER (default: 0 = latest; pin for determinism/caching)
 *                      SKIP_FORK_TESTS=true   (skip the whole suite, e.g. offline CI)
 */
contract BaseSyncVaultForkTest is Test {

    using Math for uint256;

    //  Base mainnet production addresses
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    ISuperToken internal constant USDCX = ISuperToken(0xD04383398dD2426297da660F9CCA3d439AF9ce1b);
    address internal constant MORPHO_VAULT_V2 = 0xbeef0e0834849aCC03f0089F01f4F1Eeb06873C9; // Steakhouse Prime USDC

    //  Deployment parameters (per the production candidate config)
    uint256 internal constant STABLE_YIELD_RATE_BPS = 300; // 3% annual
    uint256 internal constant GUARANTEED_FLOW_DURATION = 2 days;
    uint256 internal constant MAINTENANCE_INTERVAL = 12 hours; // operator schedule upper bound
    uint256 internal constant FEE_BPS = 100;
    uint256 internal constant BP_DENOMINATOR = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant SCALING_FACTOR = 1e12; // 6-dec USDC -> 18-dec USDCx

    /// @dev Mirrors `FundManagerBase` flow-rate math: wei of USDCx per second per pool unit.
    int96 internal constant FLOW_RATE_PER_UNIT = int96(int256(1e12 * STABLE_YIELD_RATE_BPS / (YEAR * BP_DENOMINATOR)));

    /// @dev Realistic deposit sizes (6-dec USDC): $1, $10, $50, $100, $500, $1k, $5k, $10k.
    uint256[8] internal AMOUNT_BUCKETS = [uint256(1e6), 10e6, 50e6, 100e6, 500e6, 1000e6, 5000e6, 10_000e6];

    address internal immutable DEPLOYER = makeAddr("DEPLOYER");
    address internal immutable TREASURY = makeAddr("TREASURY");
    address internal immutable FUND_OPERATOR = makeAddr("FUND_OPERATOR");
    address internal immutable FUND_ADMIN = makeAddr("FUND_ADMIN");

    StableYieldSyncVault internal _vault;
    SyncFundManager internal _fundManager;
    ISuperfluidPool internal _yieldPool;
    ISuperfluidPool internal _feePool;

    bool internal _skipped;
    uint256 internal _lastMaintenanceAt;

    //  Per-user simulation bookkeeping (reverted between fuzz runs along with the fork state)
    address[] internal _users;
    mapping(address => uint256) internal _deposited; // USDC in
    mapping(address => uint256) internal _received; // USDC out (withdrawals)
    mapping(address => uint256) internal _expectedStreamWei; // 18-dec USDCx the stream owes

    function setUp() public {
        _skipped = vm.envOr("SKIP_FORK_TESTS", true);
        if (_skipped) return;

        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        uint256 blockNumber = vm.envOr("BASE_FORK_BLOCK_NUMBER", uint256(0));
        if (blockNumber == 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, blockNumber);
        }

        vm.startPrank(DEPLOYER);
        StableYieldVaultDeployer.DeploymentResult memory deploymentResult = StableYieldVaultDeployer.deploySyncVault(
            NetworkConfig.DeploymentConfig({
                treasury: TREASURY,
                underlyingAsset: address(USDC),
                yieldAsset: address(USDCX),
                externalVault: MORPHO_VAULT_V2,
                fundOperator: FUND_OPERATOR,
                fundAdmin: FUND_ADMIN,
                initialEraStableYieldRate: STABLE_YIELD_RATE_BPS,
                guaranteedFlowDuration: GUARANTEED_FLOW_DURATION,
                shareName: "Stable Yield Sync Vault Share",
                shareSymbol: "SYSVS"
            })
        );
        vm.stopPrank();

        _vault = StableYieldSyncVault(deploymentResult.vault);
        _fundManager = SyncFundManager(deploymentResult.fundManager);
        _yieldPool = _fundManager.YIELD_POOL();
        _feePool = _fundManager.FEE_POOL();
        _lastMaintenanceAt = block.timestamp;
    }

    modifier onlyForked() {
        if (_skipped) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_deploymentAndWiring() public onlyForked {
        assertEq(_vault.asset(), address(USDC), "vault underlying != Base USDC");
        assertEq(_vault.decimals(), 18, "shares should be 18-dec (6 + offset 12)");
        assertEq(address(_fundManager.EXTERNAL_VAULT()), MORPHO_VAULT_V2, "external vault mismatch");
        assertEq(address(_fundManager.YIELD_ASSET()), address(USDCX), "yield asset mismatch");
        assertEq(_fundManager.SCALING_FACTOR(), SCALING_FACTOR, "scaling factor mismatch");
        assertEq(_fundManager.RAW_PER_UNIT(), 1, "raw-per-unit mismatch for 6-dec underlying");
        assertEq(_fundManager.stableYieldRate(), STABLE_YIELD_RATE_BPS, "stable yield rate mismatch");
        assertEq(_fundManager.guaranteedFlowDuration(), GUARANTEED_FLOW_DURATION, "flow duration mismatch");

        // The live Morpho V2 hardcodes max* to 0 and its gates are open for any fresh address
        assertEq(IERC4626(MORPHO_VAULT_V2).maxDeposit(address(_fundManager)), 0, "Morpho V2 maxDeposit not 0");
        assertTrue(_fundManager.canDepositExternal(), "Morpho deposit gates blocked for the FM");
        assertTrue(_fundManager.canWithdrawExternal(), "Morpho withdraw gates blocked for the FM");

        // Empty vault: not externally paused, deposits open, nothing managed
        assertEq(_vault.maxDeposit(address(0xCAFE)), type(uint256).max, "deposits should be open");
        assertEq(_vault.totalAssets(), 0, "fresh vault should manage nothing");
        assertEq(_yieldPool.getTotalUnits(), 0, "fresh pool should have no units");
    }

    /// @notice External constraint (discovered by this suite; motivates
    ///         `SyncFundManager.MIN_EXTERNAL_PULL`): the production Base USDCx is NOT a plain
    ///         wrapper — on every `upgrade` it auto-supplies its USDC reserves into Aave v3, and
    ///         Aave reverts `InvalidAmount()` for amounts whose scaled value rounds to 0 (1 atom
    ///         at the current ~1.07 liquidity index). Without the dust guard, the FM's 1-atom
    ///         rebalance pulls would brick the calling user op.
    function test_fork_baseUSDCxDustUpgradeReverts() public onlyForked {
        address someone = makeAddr("dust-upgrader");
        deal(address(USDC), someone, 1);

        vm.startPrank(someone);
        USDC.approve(address(USDCX), 1);
        // 1 atom of USDC == 1e12 wei of USDCx; USDCx routes the received atom to Aave -> revert
        vm.expectRevert();
        USDCX.upgrade(1e12);
        vm.stopPrank();
    }

    /// @notice Regression for the `MIN_EXTERNAL_PULL` dust guard: a sub-atom reserve deficit
    ///         used to make the rebalance pull exactly 1 atom, whose upgrade reverts on Base
    ///         USDCx's Aave routing (see test_fork_baseUSDCxDustUpgradeReverts) — bricking the
    ///         calling operation. With the guard, the sub-dust pull is skipped and both operator
    ///         maintenance and user ops run cleanly over a sub-atom deficit.
    function test_fork_subAtomDeficitDoesNotBrickOps() public onlyForked {
        address alice = makeAddr("alice");
        _users.push(alice);
        _deposit(alice, 1000e6);

        // Let the stream drain the reserve below target without maintenance.
        _advancePlain(1 hours);
        int256 deficit = _fundManager.evaluateYieldAssetsDeficit();
        assertGt(deficit, int256(SCALING_FACTOR), "setup: expected an atom-scale deficit");

        // Donate USDCx to the FM to shrink the shortfall to exactly half an atom.
        _donateUSDCx(address(_fundManager), uint256(deficit) - SCALING_FACTOR / 2);
        assertEq(_fundManager.evaluateYieldAssetsDeficit(), int256(SCALING_FACTOR / 2), "setup: sub-atom deficit");

        // Operator maintenance must skip the sub-dust pull instead of reverting...
        vm.prank(FUND_OPERATOR);
        _fundManager.ensureYieldFlowDuration();

        // ...and a user op at the same instant must not brick either.
        uint256 halfShares = _vault.balanceOf(alice) / 2;
        vm.prank(alice);
        _vault.redeem(halfShares, alice, alice);
    }

    /// @notice One depositor through the full production lifecycle: deposit -> hold under
    ///         scheduled operator maintenance -> claim the streamed yield -> exit. Asserts
    ///         units/flow/NAV state changes at each transition and overall value conservation.
    /// forge-config: default.fuzz.runs = 12
    /// forge-config: ci.fuzz.runs = 12
    function testFuzz_fork_singleUserLifecycle(uint256 amountSeed, uint256 holdSeed) public onlyForked {
        address alice = makeAddr("alice");
        _users.push(alice);

        uint256 amount = _realisticAmount(amountSeed);
        uint256 holdTime = bound(holdSeed, 12 hours, 6 days);

        // --- Deposit ---
        uint256 shares = _deposit(alice, amount);
        assertGt(shares, 0, "no shares minted");

        // NAV is reserve-inclusive and starts at par with the deposit, short of the GDA flow
        // buffer the agreement escrows at stream start (~4h of flow, i.e. ~1.4e-5 of principal;
        // recovered into NAV by the next maintenance rebalance) and external rounding atoms.
        assertLe(_vault.totalAssets(), amount, "NAV above par at entry");
        assertApproxEqRel(_vault.totalAssets(), amount, 0.0001e18, "NAV not at par (beyond buffer scale)");
        // The pre-funded reserve covers the forward-solvency target...
        assertGt(_fundManager.scaledYieldAssetsBalance(), 0, "reserve not pre-funded at deposit");
        // ...and the rest of the principal is deployed into the live Morpho vault
        assertGt(_fundManager.externalPositionValue(), 0, "principal not deployed to Morpho");
        assertLt(_fundManager.externalPositionValue(), amount, "pre-fund should come out of the deposit");

        // --- Hold, with the operator maintaining every <= 12h ---
        _advanceWithMaintenance(holdTime);

        // --- Streamed yield reached the holder (3% APR on nominal principal, pro-rated) ---
        _yieldPool.claimAll(alice);
        uint256 streamed = USDCX.balanceOf(alice);
        assertApproxEqRel(streamed, _expectedStreamWei[alice], 0.002e18, "streamed yield != GDA expectation");
        uint256 promised = amount * STABLE_YIELD_RATE_BPS * holdTime * SCALING_FACTOR / (YEAR * BP_DENOMINATOR);
        assertApproxEqRel(streamed, promised, 0.01e18, "streamed yield drifted from the 3% promise");

        // --- The treasury fee stream pays ~1% of the yield stream ---
        _feePool.claimAll(TREASURY);
        uint256 feeStreamed = USDCX.balanceOf(TREASURY);
        assertApproxEqRel(feeStreamed, streamed * FEE_BPS / BP_DENOMINATOR, 0.01e18, "fee stream != 1% of yield stream");

        // --- Full exit ---
        uint256 exitShares = Math.min(_vault.balanceOf(alice), _vault.maxRedeem(alice));
        uint256 assetsOut = _redeem(alice, exitShares);
        assertGt(assetsOut, 0, "exit paid nothing");
        _assertResidualSharesAreDust(alice);

        // Value conservation: principal back + stream, +/- the external vault's real performance
        uint256 totalValue = _received[alice] + streamed / SCALING_FACTOR;
        assertGe(totalValue, amount * 995 / 1000, "holder lost more than rounding + fee on exit");
        assertLe(totalValue, amount * 103 / 100, "holder extracted implausible value");

        // Stream fully wound down with the last holder gone
        if (_vault.totalSupply() == 0) {
            assertEq(_yieldPool.getTotalUnits(), 0, "units survived full exit");
            assertEq(_yieldPool.getTotalFlowRate(), 0, "flow survived full exit");
        }
    }

    /// @notice Production-reality simulation: 3-6 users deposit relatable amounts at staggered
    ///         times over a 5-day window; roughly half withdraw (25/50/75/100%) after a short
    ///         while; the operator runs `ensureYieldFlowDuration` every 12 hours sharp. Asserts
    ///         per-operation state changes, rolling coherence invariants, and final conservation.
    function testFuzz_fork_multiUserProductionScenario(uint256 seed) public onlyForked {
        UserPlan[] memory plans = _buildPlans(seed);

        uint256 stepDuration = 6 hours;
        uint256 totalSteps = 20; // 5 days

        for (uint256 step = 0; step < totalSteps; ++step) {
            for (uint256 i = 0; i < plans.length; ++i) {
                if (plans[i].depositStep == step) {
                    _deposit(plans[i].user, plans[i].amount);
                }
                if (plans[i].withdrawStep == step) {
                    uint256 sharesToRedeem = _vault.balanceOf(plans[i].user) * plans[i].withdrawPct / 100;
                    sharesToRedeem = Math.min(sharesToRedeem, _vault.maxRedeem(plans[i].user));
                    if (sharesToRedeem > 0) _redeem(plans[i].user, sharesToRedeem);
                }
            }

            _assertCoherence();
            _advanceWithMaintenance(stepDuration);
        }

        // --- Everyone exits ---
        for (uint256 i = 0; i < plans.length; ++i) {
            address user = plans[i].user;
            uint256 exitShares = Math.min(_vault.balanceOf(user), _vault.maxRedeem(user));
            if (exitShares > 0) _redeem(user, exitShares);
            _assertResidualSharesAreDust(user);
        }

        // --- Wind-down state ---
        assertLt(_vault.totalSupply(), 1e12, "supply did not wind down to dust"); // < 1 USDC-atom of shares
        assertLt(_vault.totalAssets(), 5e6, "residual NAV beyond GDA-buffer scale dust");

        // --- Per-user conservation: principal +/- drift came back as USDC + streamed USDCx ---
        for (uint256 i = 0; i < plans.length; ++i) {
            address user = plans[i].user;
            _yieldPool.claimAll(user);
            uint256 streamed = USDCX.balanceOf(user);
            assertApproxEqRel(streamed, _expectedStreamWei[user], 0.002e18, "streamed yield != GDA expectation");

            uint256 totalValue = _received[user] + streamed / SCALING_FACTOR;
            assertGe(totalValue, _deposited[user] * 99 / 100, "user lost more than fees + rounding");
            // Relative bound (external performance) + absolute slack: stayers pro-rata capture
            // pool-level residuals (GDA buffer refunds re-enter NAV after each recalibration,
            // ~4h of pool flow, i.e. up to ~1 USDC at the simulated TVL) — a windfall that is
            // large relative to the smallest ($1) stakes.
            assertLe(totalValue, _deposited[user] * 103 / 100 + 2e6, "user extracted implausible value");
        }
    }

    /// @notice Shares are transferable and the yield stream follows them: a transfer moves a
    ///         proportional slice of GDA units, after which the receiver accrues the stream.
    /// forge-config: default.fuzz.runs = 8
    /// forge-config: ci.fuzz.runs = 8
    function testFuzz_fork_shareTransferMovesStream(uint256 amountSeed, uint256 fracSeed) public onlyForked {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _users.push(alice);
        _users.push(bob);

        uint256 amount = _realisticAmount(amountSeed);
        uint256 fractionBps = bound(fracSeed, 1000, 9000); // transfer 10%..90% of the position

        uint256 shares = _deposit(alice, amount);
        _advanceWithMaintenance(1 days);

        uint128 aliceUnitsBefore = _yieldPool.getUnits(alice);
        uint256 transferShares = shares * fractionBps / BP_DENOMINATOR;
        vm.prank(alice);
        _vault.transfer(bob, transferShares);

        uint128 expectedDelta = uint128(uint256(aliceUnitsBefore).mulDiv(transferShares, shares, Math.Rounding.Ceil));
        assertEq(_yieldPool.getUnits(bob), expectedDelta, "receiver units != proportional slice");
        assertEq(_yieldPool.getUnits(alice), aliceUnitsBefore - expectedDelta, "sender units not reduced");
        // Total units are conserved, but `onShareTransfer` does not recalibrate the flow, and the
        // GDA re-floors the per-unit rate on any units change: the total flow sags by up to
        // 1 wei/s/unit (951 -> 950 at 3%) until the next deposit/withdraw recalibration.
        assertEq(_yieldPool.getTotalUnits(), uint128(uint256(aliceUnitsBefore)), "total units changed by a transfer");
        _assertFlowAtTarget("flow outside the post-transfer sag envelope");

        _advanceWithMaintenance(1 days);

        _yieldPool.claimAll(bob);
        assertApproxEqRel(USDCX.balanceOf(bob), _expectedStreamWei[bob], 0.002e18, "receiver stream != GDA expectation");
        assertGt(USDCX.balanceOf(bob), 0, "stream did not follow the transferred shares");
    }

    //      __  __     __
    //     / / / /__  / /___  ___  _____
    //    / /_/ / _ \/ / __ \/ _ \/ ___/
    //   / __  /  __/ / /_/ /  __/ /
    //  /_/ /_/\___/_/ .___/\___/_/
    //              /_/

    struct UserPlan {
        address user;
        uint256 amount;
        uint256 depositStep;
        uint256 withdrawStep; // type(uint256).max = holds until the final exit
        uint256 withdrawPct; // 25 / 50 / 75 / 100
    }

    function _buildPlans(uint256 seed) internal returns (UserPlan[] memory plans) {
        uint256 userCount = 3 + (seed % 4); // 3..6 users
        plans = new UserPlan[](userCount);

        for (uint256 i = 0; i < userCount; ++i) {
            uint256 entropy = uint256(keccak256(abi.encode(seed, i)));
            address user = makeAddr(string.concat("user", vm.toString(i)));
            _users.push(user);

            uint256 depositStep = entropy % 8; // everyone is in within the first 2 days
            bool withdrawsEarly = (entropy >> 8) % 2 == 0;
            uint256 withdrawStep = withdrawsEarly ? depositStep + 2 + ((entropy >> 16) % 12) : type(uint256).max;
            uint256 withdrawPct = 25 * (1 + ((entropy >> 32) % 4));

            plans[i] = UserPlan({
                user: user,
                amount: _realisticAmount(entropy >> 64),
                depositStep: depositStep,
                withdrawStep: withdrawStep,
                withdrawPct: withdrawPct
            });
        }
    }

    /// @dev Relatable deposit sizes: a bucket ($1 ... $10k) with +/-10% jitter.
    function _realisticAmount(uint256 seed) internal view returns (uint256 amount) {
        uint256 base = AMOUNT_BUCKETS[seed % AMOUNT_BUCKETS.length];
        uint256 jitter = (seed >> 8) % (base / 5 + 1); // 0 .. 20% of base
        amount = base * 9 / 10 + jitter; // 90% .. 110% of base
    }

    /// @dev Deposit with full state-change assertions (shares, units, flow, custody).
    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        deal(address(USDC), user, USDC.balanceOf(user) + assets);

        vm.prank(user);
        USDC.approve(address(_vault), assets);

        uint128 unitsBefore = _yieldPool.getUnits(user);
        uint256 supplyBefore = _vault.totalSupply();
        uint256 expectedShares = _vault.previewDeposit(assets);

        vm.prank(user);
        shares = _vault.deposit(assets, user);

        assertEq(shares, expectedShares, "deposit != previewDeposit");
        assertEq(_vault.totalSupply(), supplyBefore + shares, "supply did not grow by minted shares");
        // RAW_PER_UNIT == 1 for 6-dec USDC: units are granted 1:1 on nominal principal
        assertEq(_yieldPool.getUnits(user), unitsBefore + uint128(assets), "units != nominal principal");
        // Stream starts/recalibrates at deposit time
        assertEq(_yieldPool.getTotalFlowRate(), _expectedTotalYieldFlowRate(), "flow not recalibrated on deposit");
        // Custody invariant A.2: no raw underlying rests in the FM across calls
        assertEq(USDC.balanceOf(address(_fundManager)), 0, "raw underlying resting in FM after deposit");

        _deposited[user] += assets;
    }

    /// @dev Redeem with full state-change assertions (preview parity, payout, units, custody).
    function _redeem(address user, uint256 shares) internal returns (uint256 assets) {
        assertLe(shares, _vault.maxRedeem(user), "trying to redeem above maxRedeem");

        uint256 expectedAssets = _vault.previewRedeem(shares);
        uint128 unitsBefore = _yieldPool.getUnits(user);
        uint256 sharesOwned = _vault.balanceOf(user);
        uint256 usdcBefore = USDC.balanceOf(user);

        vm.prank(user);
        assets = _vault.redeem(shares, user, user);

        assertEq(assets, expectedAssets, "redeem != previewRedeem");
        assertEq(USDC.balanceOf(user) - usdcBefore, assets, "receiver did not get the exact payout");
        if (unitsBefore > 0) {
            uint128 expectedDelta = shares == sharesOwned
                ? unitsBefore
                : uint128(uint256(unitsBefore).mulDiv(shares, sharesOwned, Math.Rounding.Ceil));
            assertEq(_yieldPool.getUnits(user), unitsBefore - expectedDelta, "units not reduced proportionally");
        }
        assertEq(_yieldPool.getTotalFlowRate(), _expectedTotalYieldFlowRate(), "flow not recalibrated on withdraw");
        assertEq(USDC.balanceOf(address(_fundManager)), 0, "raw underlying resting in FM after withdraw");

        _received[user] += assets;
    }

    /// @dev Operator maintenance: `ensureYieldFlowDuration` + post-conditions (reserve at the
    ///      forward-solvency target up to the skipped sub-dust band — pulls below
    ///      `MIN_EXTERNAL_PULL` atoms are skipped, see SyncFundManager — and flow at the
    ///      configured rate).
    function _maintain() internal {
        vm.prank(FUND_OPERATOR);
        _fundManager.ensureYieldFlowDuration();
        _lastMaintenanceAt = block.timestamp;

        assertLt(
            _fundManager.evaluateYieldAssetsDeficit(),
            int256(_fundManager.MIN_EXTERNAL_PULL() * SCALING_FACTOR),
            "reserve below target beyond the sub-dust band after maintenance"
        );
        _assertFlowAtTarget("flow drifted after maintenance");
        if (_yieldPool.getTotalUnits() > 0) {
            assertGt(_yieldPool.getTotalFlowRate(), 0, "stream stopped despite active holders");
        }
    }

    /// @dev The pool flow must sit at the configured target — exactly after any deposit/withdraw
    ///      (they recalibrate), but a units move without recalibration (share transfer) re-floors
    ///      the GDA per-unit rate at EACH units update, sagging the total by up to 1 wei/s/unit
    ///      per update (`onShareTransfer` performs two: increase + decrease) until the next
    ///      `distributeFlow` (the remainder accrues to the pool admin, i.e. the FM).
    function _assertFlowAtTarget(string memory err) internal view {
        int96 actual = _yieldPool.getTotalFlowRate();
        int96 expected = _expectedTotalYieldFlowRate();
        assertLe(actual, expected, err);
        assertGe(actual, expected - 2 * int96(int128(_yieldPool.getTotalUnits())), err);
    }

    /// @dev Fund `to` with an exact wei amount of USDCx via a throwaway upgrader.
    function _donateUSDCx(address to, uint256 amountWei) internal {
        address donor = makeAddr("usdcx-donor");
        uint256 atoms = amountWei / SCALING_FACTOR + 1;
        deal(address(USDC), donor, USDC.balanceOf(donor) + atoms);
        vm.startPrank(donor);
        USDC.approve(address(USDCX), atoms);
        USDCX.upgrade(atoms * SCALING_FACTOR);
        USDCX.transfer(to, amountWei);
        vm.stopPrank();
    }

    /// @dev Warp without operator maintenance (still accrues the stream expectations).
    function _advancePlain(uint256 duration) internal {
        _accrueExpectedStream(duration);
        vm.warp(block.timestamp + duration);
    }

    /// @dev Advance time in chunks, running the operator schedule (every 12h at most) and
    ///      accruing the exact per-user GDA stream expectation along the way.
    function _advanceWithMaintenance(uint256 duration) internal {
        uint256 target = block.timestamp + duration;
        while (block.timestamp < target) {
            uint256 nextStop = Math.min(_lastMaintenanceAt + MAINTENANCE_INTERVAL, target);
            _advancePlain(nextStop - block.timestamp);
            if (block.timestamp >= _lastMaintenanceAt + MAINTENANCE_INTERVAL) _maintain();
        }
    }

    /// @dev Each member's accrual over a window with stable units is exactly their current pool
    ///      flow rate * dt (the per-unit rate only changes on units updates / recalibrations,
    ///      which the simulations only perform at window boundaries).
    function _accrueExpectedStream(uint256 dt) internal {
        for (uint256 i = 0; i < _users.length; ++i) {
            _expectedStreamWei[_users[i]] += uint256(uint96(_yieldPool.getMemberFlowRate(_users[i]))) * dt;
        }
    }

    function _expectedTotalYieldFlowRate() internal view returns (int96) {
        return FLOW_RATE_PER_UNIT * int96(int128(_yieldPool.getTotalUnits()));
    }

    /// @dev Rolling coherence invariants, checked at every simulation step.
    function _assertCoherence() internal view {
        assertEq(_vault.totalAssets(), _fundManager.totalManagedAssets(), "vault NAV != FM NAV");

        uint256 sumShares;
        uint256 sumUnits;
        for (uint256 i = 0; i < _users.length; ++i) {
            sumShares += _vault.balanceOf(_users[i]);
            sumUnits += _yieldPool.getUnits(_users[i]);
        }
        assertEq(sumShares, _vault.totalSupply(), "share supply != sum of holders");
        assertEq(sumUnits, _yieldPool.getTotalUnits(), "pool units != sum of members");
    }

    /// @dev `maxRedeem` can floor a hair below the full balance when the external vault
    ///      underperforms the promised rate; whatever cannot be redeemed must be worth dust.
    function _assertResidualSharesAreDust(address user) internal view {
        uint256 residualValue = _vault.convertToAssets(_vault.balanceOf(user));
        assertLe(residualValue, Math.max(_deposited[user] / 200, 1), "non-dust shares stuck after exit");
    }

}
