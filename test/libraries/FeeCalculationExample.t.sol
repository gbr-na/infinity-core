// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolFeeLibrary} from "../../src/libraries/ProtocolFeeLibrary.sol";
import {FullMath} from "../../src/pool-cl/libraries/FullMath.sol";

// --- integration test imports ---
import {IHooks} from "../../src/interfaces/IHooks.sol";
import {IProtocolFeeController} from "../../src/interfaces/IProtocolFeeController.sol";
import {ICLPoolManager} from "../../src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "../../src/pool-cl/CLPoolManager.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "../../src/types/Currency.sol";
import {BalanceDelta} from "../../src/types/BalanceDelta.sol";
import {TickMath} from "../../src/pool-cl/libraries/TickMath.sol";
import {Vault} from "../../src/Vault.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Deployers} from "../pool-cl/helpers/Deployers.sol";
import {TokenFixture} from "../helpers/TokenFixture.sol";
import {CLPoolManagerRouter} from "../pool-cl/helpers/CLPoolManagerRouter.sol";
import {MockProtocolFeeController} from "../pool-cl/helpers/ProtocolFeeControllers.sol";

// ============================================================
// Pure-math tests
// ============================================================

/// @notice Verifies the exact fee split for a swap with amountIn = 100 tokens (18 decimals).
///
/// Setup:
///   amountIn     = 100e18  (100 tokens, decimal = 18)
///   protocolFee  = 1000 pips  (0.1%)
///   lpFee        = 3000 pips  (0.3%)
///
/// Expected outputs (derived in docs/fee-calculation.md §9):
///   swapFee          = 3997 pips
///   amountNet        = 99_600_300_000_000_000_000   (net amount entering the pool)
///   feeAmount        = 399_700_000_000_000_000       (total fee collected)
///   protocolFeeAmt   = 100_000_000_000_000_000       (0.1 token)
///   lpFeeAmt         = 299_700_000_000_000_000       (0.2997 token)
contract FeeCalculationExampleTest is Test {
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;

    uint256 constant AMOUNT_IN         = 100e18;
    uint16  constant PROTOCOL_FEE_PIPS = 1000;   // 0.1%
    uint24  constant LP_FEE_PIPS       = 3000;   // 0.3%
    uint256 constant MAX_FEE_PIPS      = 1_000_000;

    // Expected values — computed analytically and documented in fee-calculation.md §9
    uint24  constant EXPECTED_SWAP_FEE          = 3997;
    uint256 constant EXPECTED_AMOUNT_NET        = 99_600_300_000_000_000_000;
    uint256 constant EXPECTED_FEE_AMOUNT        = 399_700_000_000_000_000;
    uint256 constant EXPECTED_PROTOCOL_FEE_AMT  = 100_000_000_000_000_000;
    uint256 constant EXPECTED_LP_FEE_AMT        = 299_700_000_000_000_000;

    // -------------------------------------------------------------------------
    // Step 1: calculateSwapFee
    // -------------------------------------------------------------------------

    /// @dev swapFee = protocolFee + lpFee − floor(protocolFee × lpFee / 1_000_000)
    function test_step1_swapFee() public pure {
        uint24 swapFee = ProtocolFeeLibrary.calculateSwapFee(PROTOCOL_FEE_PIPS, LP_FEE_PIPS);
        assertEq(swapFee, EXPECTED_SWAP_FEE, "swapFee mismatch");
    }

    // -------------------------------------------------------------------------
    // Step 2: SwapMath — net amount and total fee (exact-input path)
    // -------------------------------------------------------------------------

    /// @dev amountNet = floor(amountIn × (MAX_FEE_PIPS − swapFee) / MAX_FEE_PIPS)
    function test_step2_netAmount() public pure {
        uint256 amountNet = FullMath.mulDiv(AMOUNT_IN, MAX_FEE_PIPS - EXPECTED_SWAP_FEE, MAX_FEE_PIPS);
        assertEq(amountNet, EXPECTED_AMOUNT_NET, "amountNet mismatch");
    }

    /// @dev feeAmount = ceil(amountNet × swapFee / (MAX_FEE_PIPS − swapFee))
    function test_step2_feeAmount() public pure {
        uint256 amountNet = FullMath.mulDiv(AMOUNT_IN, MAX_FEE_PIPS - EXPECTED_SWAP_FEE, MAX_FEE_PIPS);
        uint256 feeAmount = FullMath.mulDivRoundingUp(amountNet, EXPECTED_SWAP_FEE, MAX_FEE_PIPS - EXPECTED_SWAP_FEE);
        assertEq(feeAmount, EXPECTED_FEE_AMOUNT, "feeAmount mismatch");
    }

    /// @dev amountNet + feeAmount must equal amountIn exactly (no dust)
    function test_step2_netPlusFeeEqualsAmountIn() public pure {
        uint256 amountNet = FullMath.mulDiv(AMOUNT_IN, MAX_FEE_PIPS - EXPECTED_SWAP_FEE, MAX_FEE_PIPS);
        uint256 feeAmount = FullMath.mulDivRoundingUp(amountNet, EXPECTED_SWAP_FEE, MAX_FEE_PIPS - EXPECTED_SWAP_FEE);
        assertEq(amountNet + feeAmount, AMOUNT_IN, "amountNet + feeAmount != amountIn");
    }

    // -------------------------------------------------------------------------
    // Step 3: CLPool — split protocol fee from LP fee
    // -------------------------------------------------------------------------

    /// @dev delta = (amountNet + feeAmount) × protocolFee / PIPS_DENOMINATOR
    ///            = amountIn × protocolFee / PIPS_DENOMINATOR   (since net + fee = amountIn)
    function test_step3_protocolFeeAmount() public pure {
        uint256 amountNet = FullMath.mulDiv(AMOUNT_IN, MAX_FEE_PIPS - EXPECTED_SWAP_FEE, MAX_FEE_PIPS);
        uint256 feeAmount = FullMath.mulDivRoundingUp(amountNet, EXPECTED_SWAP_FEE, MAX_FEE_PIPS - EXPECTED_SWAP_FEE);

        // mirrors CLPool.sol: (step.amountIn + step.feeAmount) * protocolFee / PIPS_DENOMINATOR
        uint256 protocolFeeAmt = (amountNet + feeAmount) * PROTOCOL_FEE_PIPS / ProtocolFeeLibrary.PIPS_DENOMINATOR;
        assertEq(protocolFeeAmt, EXPECTED_PROTOCOL_FEE_AMT, "protocol fee amount mismatch");
    }

    function test_step3_lpFeeAmount() public pure {
        uint256 amountNet = FullMath.mulDiv(AMOUNT_IN, MAX_FEE_PIPS - EXPECTED_SWAP_FEE, MAX_FEE_PIPS);
        uint256 feeAmount = FullMath.mulDivRoundingUp(amountNet, EXPECTED_SWAP_FEE, MAX_FEE_PIPS - EXPECTED_SWAP_FEE);
        uint256 protocolFeeAmt = (amountNet + feeAmount) * PROTOCOL_FEE_PIPS / ProtocolFeeLibrary.PIPS_DENOMINATOR;

        uint256 lpFeeAmt = feeAmount - protocolFeeAmt;
        assertEq(lpFeeAmt, EXPECTED_LP_FEE_AMT, "LP fee amount mismatch");
    }

    /// @dev protocol + LP = total fee collected
    function test_step3_protocolPlusLpEqualsTotal() public pure {
        uint256 amountNet = FullMath.mulDiv(AMOUNT_IN, MAX_FEE_PIPS - EXPECTED_SWAP_FEE, MAX_FEE_PIPS);
        uint256 feeAmount = FullMath.mulDivRoundingUp(amountNet, EXPECTED_SWAP_FEE, MAX_FEE_PIPS - EXPECTED_SWAP_FEE);
        uint256 protocolFeeAmt = (amountNet + feeAmount) * PROTOCOL_FEE_PIPS / ProtocolFeeLibrary.PIPS_DENOMINATOR;
        uint256 lpFeeAmt = feeAmount - protocolFeeAmt;

        assertEq(protocolFeeAmt + lpFeeAmt, feeAmount, "protocol + LP != total fee");
    }

    // -------------------------------------------------------------------------
    // Packed protocolFee encoding / decoding
    // -------------------------------------------------------------------------

    /// @dev Verify that packing and unpacking a zeroForOne fee round-trips correctly.
    ///      packedFee = fee | (fee << 12) puts the same 1000-pip fee in both directions.
    function test_protocolFeeEncoding_zeroForOne() public pure {
        // _buildProtocolFee(1000) = 1000 | (1000 << 12)
        uint24 packed = uint24(PROTOCOL_FEE_PIPS) | (uint24(PROTOCOL_FEE_PIPS) << 12);
        assertEq(ProtocolFeeLibrary.getZeroForOneFee(packed), PROTOCOL_FEE_PIPS, "zeroForOne decode mismatch");
    }

    function test_protocolFeeEncoding_oneForZero() public pure {
        uint24 packed = uint24(PROTOCOL_FEE_PIPS) | (uint24(PROTOCOL_FEE_PIPS) << 12);
        assertEq(ProtocolFeeLibrary.getOneForZeroFee(packed), PROTOCOL_FEE_PIPS, "oneForZero decode mismatch");
    }

    // -------------------------------------------------------------------------
    // Edge cases
    // -------------------------------------------------------------------------

    /// @dev When protocolFee = 0, the entire fee goes to LPs.
    function test_edge_zeroProtocolFee() public pure {
        uint24 swapFee = ProtocolFeeLibrary.calculateSwapFee(0, LP_FEE_PIPS);
        assertEq(swapFee, LP_FEE_PIPS, "swapFee should equal lpFee when protocolFee is 0");

        uint256 amountNet = FullMath.mulDiv(AMOUNT_IN, MAX_FEE_PIPS - swapFee, MAX_FEE_PIPS);
        uint256 feeAmount = FullMath.mulDivRoundingUp(amountNet, swapFee, MAX_FEE_PIPS - swapFee);
        uint256 protocolFeeAmt = 0; // protocolFee == 0, CLPool skips the split
        uint256 lpFeeAmt = feeAmount - protocolFeeAmt;

        // LP gets the full fee; protocol gets nothing
        assertEq(protocolFeeAmt, 0,         "protocol fee should be 0");
        assertEq(lpFeeAmt, feeAmount,       "LP should receive the full fee");
    }

    /// @dev When lpFee = 0, the entire fee is the protocol fee only.
    function test_edge_zeroLpFee() public pure {
        uint24 swapFee = ProtocolFeeLibrary.calculateSwapFee(PROTOCOL_FEE_PIPS, 0);
        assertEq(swapFee, PROTOCOL_FEE_PIPS, "swapFee should equal protocolFee when lpFee is 0");

        uint256 amountNet = FullMath.mulDiv(AMOUNT_IN, MAX_FEE_PIPS - swapFee, MAX_FEE_PIPS);
        uint256 feeAmount = FullMath.mulDivRoundingUp(amountNet, swapFee, MAX_FEE_PIPS - swapFee);

        // CLPool special case: swapFee == protocolFee → entire feeAmount goes to protocol
        uint256 protocolFeeAmt = feeAmount; // (state.swapFee == state.protocolFee) branch
        uint256 lpFeeAmt = feeAmount - protocolFeeAmt;

        assertEq(lpFeeAmt, 0,              "LP fee should be 0 when lpFee is 0");
        assertEq(protocolFeeAmt, feeAmount, "protocol should receive the full fee when lpFee is 0");
    }
}

// ============================================================
// Integration tests — real pool, real swap
// ============================================================

/// @notice Spins up a real CL pool with lpFee=3000, protocolFee=1000, adds liquidity,
///         executes an exact-input swap of 100e18 token0, then asserts:
///           - protocol fee accrued == 100_000_000_000_000_000  (0.1 token)
///           - LP fee collected     == 299_700_000_000_000_000  (0.2997 token)
///           - protocol + LP        == 399_700_000_000_000_000  (total fee)
///
/// Pool design for a guaranteed single-step swap:
///   - Tick range  : [-60, 60]
///   - Liquidity   : 40_000e18
///   - Max token0 absorbable in range ≈ 40_000e18 × 0.003 ≈ 120e18  > 100e18 ✓
///     → the entire 100e18 input is consumed before hitting tick -60
///   - This gives the "exhaust remaining" path in SwapMath (no mulDivRoundingUp on feeAmount),
///     so feeAmount = amountIn − amountNet = 100e18 − 99_600_300_000_000_000_000 = 399_700_000_000_000_000 exactly.
///
/// LP fee Q128 rounding note:
///   feeGrowthGlobal += floor(LP_FEE × Q128 / L)  →  feesOwed = floor(feeGrowthDelta × L / Q128)
///   = LP_FEE − 1  when L does not divide LP_FEE×Q128  (1-wei dust locked in feeGrowthGlobal forever).
///   For our params: LP_FEE×Q128/L = 2997×2^128/(4×10^8); since 5^8 ∤ 2997 the division is inexact
///   → feesOwed = 299_699_999_999_999_999.  Tests use assertApproxEqAbs(..., 1) to capture this.
contract FeeCalculationIntegrationTest is Test, Deployers, TokenFixture {
    using PoolIdLibrary for PoolKey;

    // ── fee parameters ────────────────────────────────────────────────────────
    uint24 constant LP_FEE           = 3000;                                    // 0.3%
    uint16 constant PROTOCOL_FEE_DIR = 1000;                                    // 0.1% per direction
    /// @dev packed uint24: bits[11:0] = zeroForOne, bits[23:12] = oneForZero
    uint24 constant PROTOCOL_FEE_PACKED = uint24(1000) | (uint24(1000) << 12);  // 0x001001F40 → 0x3E8 | 0x3E8000... wait
    // actually: 1000 | (1000 << 12) = 1000 + 4_096_000 = 4_097_000? no
    // 1000 = 0x3E8; 1000 << 12 = 0x3E8000; packed = 0x3E8000 | 0x3E8 = 0x3E83E8 = 4_096_488 decimal

    // ── liquidity / position ──────────────────────────────────────────────────
    int24  constant TICK_LOWER        = -60;
    int24  constant TICK_UPPER        =  60;
    int256 constant LIQUIDITY_DELTA   = int256(40_000e18);

    // ── swap parameters ───────────────────────────────────────────────────────
    uint256 constant AMOUNT_IN = 100e18;

    // ── expected fee amounts (from pure-math tests and fee-calculation.md §9) ─
    uint256 constant EXPECTED_PROTOCOL_FEE = 100_000_000_000_000_000;  // 0.1  token
    uint256 constant EXPECTED_LP_FEE       = 299_700_000_000_000_000;  // 0.2997 token
    uint256 constant EXPECTED_TOTAL_FEE    = 399_700_000_000_000_000;  // 0.3997 token

    // ── infrastructure ────────────────────────────────────────────────────────
    Vault                   vault;
    CLPoolManager           poolManager;
    CLPoolManagerRouter     router;
    MockProtocolFeeController protocolFeeController;
    PoolKey                 key;

    function setUp() public {
        initializeTokens();
        (vault, poolManager) = createFreshManager();

        router = new CLPoolManagerRouter(vault, poolManager);
        protocolFeeController = new MockProtocolFeeController();

        // Approve enough tokens — setUp uses ~120e18 per token for liquidity
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);

        // Pool: lpFee = 0.3%, tickSpacing = 60, no hooks
        key = PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            hooks:       IHooks(address(0)),
            poolManager: poolManager,
            fee:         LP_FEE,
            parameters:  bytes32(uint256(uint24(TICK_UPPER) << 16)) // tickSpacing = 60
        });
        poolManager.initialize(key, SQRT_RATIO_1_1);

        // Attach protocol fee controller and set 0.1% in both swap directions
        poolManager.setProtocolFeeController(IProtocolFeeController(protocolFeeController));
        protocolFeeController.setProtocolFeeForPool(key.toId(), PROTOCOL_FEE_PACKED);
        vm.prank(address(protocolFeeController));
        poolManager.setProtocolFee(key, PROTOCOL_FEE_PACKED);

        // Add liquidity to [-60, 60].
        // With L = 40_000e18 and tick range ±60, the pool can absorb ~120e18 token0
        // before hitting the tick boundary — well above our 100e18 swap.
        router.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower:      TICK_LOWER,
                tickUpper:      TICK_UPPER,
                liquidityDelta: LIQUIDITY_DELTA,
                salt:           bytes32(0)
            }),
            ""
        );
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _swap() internal returns (BalanceDelta delta) {
        delta = router.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne:        true,
                amountSpecified:   -int256(AMOUNT_IN), // exact input
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    // ── sanity: verify pool is configured correctly ───────────────────────────

    function test_integration_poolSetup() public view {
        (, , uint24 pFee, uint24 lpFee) = poolManager.getSlot0(key.toId());

        // zeroForOne direction fee = lower 12 bits
        assertEq(pFee & 0xfff, PROTOCOL_FEE_DIR, "zeroForOne protocol fee not set");
        // oneForZero direction fee = upper 12 bits
        assertEq(pFee >> 12,   PROTOCOL_FEE_DIR, "oneForZero protocol fee not set");
        assertEq(lpFee, LP_FEE, "LP fee not set");
    }

    // ── core: verify swap consumes exactly AMOUNT_IN ─────────────────────────

    /// @dev delta.amount0() must be exactly −100e18 (user paid the full amount).
    ///      If it were less, the swap was truncated by a tick boundary and
    ///      the single-step assumption used to derive EXPECTED_* would be wrong.
    function test_integration_swapConsumesFullInput() public {
        BalanceDelta delta = _swap();
        assertEq(uint256(uint128(-delta.amount0())), AMOUNT_IN, "swap did not consume full amountIn");
    }

    // ── protocol fee ─────────────────────────────────────────────────────────

    /// @dev After the swap, CLPoolManager.protocolFeesAccrued[currency0] must equal
    ///      amountIn × protocolFee / 1_000_000 = 100e18 × 1000 / 1_000_000 = 0.1e18
    function test_integration_protocolFeeAccrued() public {
        uint256 before0 = poolManager.protocolFeesAccrued(currency0);
        uint256 before1 = poolManager.protocolFeesAccrued(currency1);

        _swap();

        uint256 accrued0 = poolManager.protocolFeesAccrued(currency0) - before0;
        uint256 accrued1 = poolManager.protocolFeesAccrued(currency1) - before1;

        assertEq(accrued0, EXPECTED_PROTOCOL_FEE, "protocol fee (currency0) mismatch");
        assertEq(accrued1, 0,                     "no currency1 protocol fee for zeroForOne swap");
    }

    // ── LP fee ────────────────────────────────────────────────────────────────

    /// @dev After the swap, call modifyPosition(liquidityDelta=0) to collect the LP fee.
    ///      The balance change equals the fee distributed to this position via feeGrowthGlobal.
    ///
    ///      Q128 rounding: feesOwed = LP_FEE − 1 = 299_699_999_999_999_999
    ///      because 5^8 ∤ 2997, so LP_FEE×Q128 is not divisible by L.
    ///      The 1-wei difference is dust permanently locked in feeGrowthGlobal.
    function test_integration_lpFeeCollected() public {
        _swap();

        uint256 bal0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));

        // collect fees without changing liquidity
        router.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower:      TICK_LOWER,
                tickUpper:      TICK_UPPER,
                liquidityDelta: 0,
                salt:           bytes32(0)
            }),
            ""
        );

        uint256 lpFeeCollected = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this)) - bal0Before;

        // 1-wei tolerance accounts for Q128 fixed-point dust in feeGrowthGlobal
        assertApproxEqAbs(lpFeeCollected, EXPECTED_LP_FEE, 1, "LP fee collected mismatch (>1 wei off)");
    }

    // ── total fee breakdown ───────────────────────────────────────────────────

    /// @dev protocol fee + LP fee should sum to within 1 wei of the theoretical total.
    ///      The gap (if any) is Q128 dust locked permanently in feeGrowthGlobal.
    function test_integration_totalFeeBreakdown() public {
        uint256 pfeeBefore = poolManager.protocolFeesAccrued(currency0);

        _swap();

        uint256 protocolFee = poolManager.protocolFeesAccrued(currency0) - pfeeBefore;

        uint256 bal0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        router.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower:      TICK_LOWER,
                tickUpper:      TICK_UPPER,
                liquidityDelta: 0,
                salt:           bytes32(0)
            }),
            ""
        );
        uint256 lpFee = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this)) - bal0Before;

        assertEq(protocolFee, EXPECTED_PROTOCOL_FEE, "protocol fee mismatch");

        // 1-wei tolerance for Q128 dust
        assertApproxEqAbs(lpFee,               EXPECTED_LP_FEE,    1, "LP fee mismatch (>1 wei off)");
        assertApproxEqAbs(protocolFee + lpFee,  EXPECTED_TOTAL_FEE, 1, "total fee mismatch (>1 wei off)");
    }
}
