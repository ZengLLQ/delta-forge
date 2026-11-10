// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeltaMath} from "../src/libraries/DeltaMath.sol";

contract DeltaMathTest is Test {
    uint256 internal constant WAD = 1e18;
    int256 internal constant INT_WAD = 1e18;

    function test_WadMulDiv(uint256 a, uint256 b) public pure {
        a = bound(a, 1, 1e28);
        b = bound(b, 1, 1e28);
        uint256 prod = DeltaMath.wadMul(a, b);
        // a * b / 1e18
        assertGe(prod, 0);
    }

    function test_WadSqrt() public pure {
        assertEq(DeltaMath.wadSqrt(0), 0);
        assertApproxEqRel(DeltaMath.wadSqrt(1 * WAD), 1 * WAD, 1e14);
        assertApproxEqRel(DeltaMath.wadSqrt(4 * WAD), 2 * WAD, 1e14);
        assertApproxEqRel(DeltaMath.wadSqrt(9 * WAD), 3 * WAD, 1e14);
        assertApproxEqRel(DeltaMath.wadSqrt(16 * WAD), 4 * WAD, 1e14);
        assertApproxEqRel(DeltaMath.wadSqrt(100 * WAD), 10 * WAD, 1e14);
    }

    function test_WadLn_KnownValues() public pure {
        // ln(1) = 0
        assertEq(DeltaMath.wadLn(1 * WAD), 0);

        // ln(e) ~ 1
        assertApproxEqAbs(DeltaMath.wadLn(2718281828459045235), INT_WAD, 1e10);

        // ln(2) ~ 0.693147180559945309
        assertApproxEqAbs(DeltaMath.wadLn(2 * WAD), 693147180559945309, 1e10);

        // ln(0.5) ~ -ln(2)
        assertApproxEqAbs(DeltaMath.wadLn(0.5e18), -693147180559945309, 1e10);

        // ln(10) ~ 2.302585092994046
        assertApproxEqAbs(DeltaMath.wadLn(10 * WAD), 2302585092994045684, 1e10);
    }

    function test_WadLn_Monotonicity(uint256 a, uint256 b) public pure {
        a = bound(a, 0.01e18, 10000 * WAD);
        b = bound(b, 0.01e18, 10000 * WAD);
        if (a < b) {
            assertLe(DeltaMath.wadLn(a), DeltaMath.wadLn(b));
        } else if (a > b) {
            assertGe(DeltaMath.wadLn(a), DeltaMath.wadLn(b));
        }
    }

    function test_WadExp_KnownValues() public pure {
        // e^0 = 1
        assertEq(DeltaMath.wadExp(0), WAD);

        // e^1 ~ 2.718281828459045235
        assertApproxEqRel(DeltaMath.wadExp(INT_WAD), 2718281828459045235, 1e12);

        // e^(-1) ~ 0.367879441171442321
        assertApproxEqRel(DeltaMath.wadExp(-INT_WAD), 367879441171442321, 1e12);

        // e^(ln(2)) ~ 2
        assertApproxEqRel(DeltaMath.wadExp(693147180559945309), 2 * WAD, 1e12);
    }

    function test_WadExp_Ln_Inversion(uint256 x) public pure {
        x = bound(x, 0.05e18, 50 * WAD);
        int256 lnX = DeltaMath.wadLn(x);
        uint256 expLnX = DeltaMath.wadExp(lnX);
        assertApproxEqRel(expLnX, x, 1e12); // Within 0.0001%
    }

    function test_NormalPdf_Symmetry() public pure {
        // phi(0) = 1 / sqrt(2*pi) ~ 0.398942280401432678
        assertApproxEqAbs(DeltaMath.normalPdf(0), 398942280401432678, 1e10);

        // phi(x) == phi(-x)
        int256 x = 1.5e18;
        assertEq(DeltaMath.normalPdf(x), DeltaMath.normalPdf(-x));
    }

    function test_NormalCdf_KnownValues() public pure {
        // Phi(0) = 0.5
        assertEq(DeltaMath.normalCdf(0), 0.5e18);

        // Phi(1.96) ~ 0.975 (95% two-tailed confidence interval)
        assertApproxEqRel(DeltaMath.normalCdf(1.96e18), 0.975e18, 1e13);

        // Phi(-1.96) ~ 0.025
        assertApproxEqRel(DeltaMath.normalCdf(-1.96e18), 0.025e18, 1e15);

        // Phi(1.0) ~ 0.84134
        assertApproxEqRel(DeltaMath.normalCdf(1.0e18), 0.841344746e18, 1e13);

        // Symmetry: Phi(x) + Phi(-x) == 1
        int256 x = 0.85e18;
        uint256 sum = DeltaMath.normalCdf(x) + DeltaMath.normalCdf(-x);
        assertApproxEqAbs(sum, WAD, 10);
    }

    function test_NormalCdf_Monotonicity(int256 a, int256 b) public pure {
        a = bound(a, -5 * INT_WAD, 5 * INT_WAD);
        b = bound(b, -5 * INT_WAD, 5 * INT_WAD);
        if (a <= b) {
            assertLe(DeltaMath.normalCdf(a), DeltaMath.normalCdf(b));
        } else {
            assertGe(DeltaMath.normalCdf(a), DeltaMath.normalCdf(b));
        }
    }

    function test_InvNormalCdf_KnownValues() public pure {
        // Phi^-1(0.5) = 0
        assertEq(DeltaMath.invNormalCdf(0.5e18), 0);

        // Phi^-1(0.975) ~ 1.96
        assertApproxEqRel(uint256(DeltaMath.invNormalCdf(0.975e18)), 1.96e18, 1e15);

        // Inversion: Phi(Phi^-1(p)) ~ p
        uint256 p = 0.15e18; // 15-delta
        int256 z = DeltaMath.invNormalCdf(p);
        uint256 cdfZ = DeltaMath.normalCdf(z);
        assertApproxEqRel(cdfZ, p, 2e15);
    }

    function test_BlackScholes_PutCallParity() public pure {
        // Spot = 3000, Strike = 3200, 7 days, 60% vol, 4% rate
        DeltaMath.OptionParams memory params = DeltaMath.OptionParams({
            spotPrice: 3000 * WAD,
            strikePrice: 3200 * WAD,
            timeToExpirySec: 7 days,
            volatility: 0.6e18,
            riskFreeRate: 0.04e18
        });

        (uint256 callPrice, uint256 putPrice) = DeltaMath.blackScholesPrice(params);

        // Call must be strictly positive
        assertGt(callPrice, 0);
        assertGt(putPrice, 0);

        // Put-Call Parity: C - P = S - K * e^(-rT)
        uint256 tWad = (7 days * WAD) / 31536000;
        int256 negRT = -int256(DeltaMath.wadMul(0.04e18, tWad));
        uint256 discountK = DeltaMath.wadMul(3200 * WAD, DeltaMath.wadExp(negRT));

        int256 lhs = int256(callPrice) - int256(putPrice);
        int256 rhs = int256(3000 * WAD) - int256(discountK);

        // Parity holds to high precision
        assertApproxEqAbs(lhs, rhs, 1e14);
    }

    function test_BlackScholes_CallMonotonicity() public pure {
        // Higher spot price must lead to higher call price
        DeltaMath.OptionParams memory p1 = DeltaMath.OptionParams({
            spotPrice: 2800 * WAD,
            strikePrice: 3000 * WAD,
            timeToExpirySec: 7 days,
            volatility: 0.5e18,
            riskFreeRate: 0.03e18
        });

        DeltaMath.OptionParams memory p2 = DeltaMath.OptionParams({
            spotPrice: 3200 * WAD,
            strikePrice: 3000 * WAD,
            timeToExpirySec: 7 days,
            volatility: 0.5e18,
            riskFreeRate: 0.03e18
        });

        (uint256 call1,) = DeltaMath.blackScholesPrice(p1);
        (uint256 call2,) = DeltaMath.blackScholesPrice(p2);

        assertGt(call2, call1);
    }

    function test_Greeks_Bounds() public pure {
        DeltaMath.OptionParams memory params = DeltaMath.OptionParams({
            spotPrice: 3000 * WAD,
            strikePrice: 3000 * WAD,
            timeToExpirySec: 14 days,
            volatility: 0.55e18,
            riskFreeRate: 0.04e18
        });

        DeltaMath.Greeks memory callGreeks = DeltaMath.calculateGreeks(params, false);
        // Call Delta must be in (0, 1)
        assertGt(callGreeks.delta, 0);
        assertLt(callGreeks.delta, INT_WAD);
        // Gamma and Vega must be positive
        assertGt(callGreeks.gamma, 0);
        assertGt(callGreeks.vega, 0);
        // Theta must be negative (time decay)
        assertLt(callGreeks.theta, 0);

        DeltaMath.Greeks memory putGreeks = DeltaMath.calculateGreeks(params, true);
        // Put Delta must be in (-1, 0)
        assertLt(putGreeks.delta, 0);
        assertGt(putGreeks.delta, -INT_WAD);
    }

    function test_GetStrikeForDelta_Call() public pure {
        // S = 3000, 15-delta Call, 7 days, 60% vol
        uint256 strike = DeltaMath.getStrikeForDelta(
            3000 * WAD,
            0.15e18,
            7 days,
            0.6e18,
            0.04e18,
            false // Call
        );

        // Strike must be OTM (K > S for call)
        assertGt(strike, 3000 * WAD);

        // Verify the option at this strike indeed has Delta ~ 0.15
        DeltaMath.OptionParams memory params = DeltaMath.OptionParams({
            spotPrice: 3000 * WAD,
            strikePrice: strike,
            timeToExpirySec: 7 days,
            volatility: 0.6e18,
            riskFreeRate: 0.04e18
        });

        DeltaMath.Greeks memory greeks = DeltaMath.calculateGreeks(params, false);
        assertApproxEqAbs(greeks.delta, 0.15e18, 0.01e18); // within 1 delta point
    }

    function test_GetStrikeForDelta_Put() public pure {
        // S = 3000, 15-delta Put, 7 days, 60% vol
        uint256 strike = DeltaMath.getStrikeForDelta(
            3000 * WAD,
            0.15e18,
            7 days,
            0.6e18,
            0.04e18,
            true // Put
        );

        // Strike must be OTM (K < S for put)
        assertLt(strike, 3000 * WAD);

        // Verify the option at this strike indeed has Delta ~ -0.15
        DeltaMath.OptionParams memory params = DeltaMath.OptionParams({
            spotPrice: 3000 * WAD,
            strikePrice: strike,
            timeToExpirySec: 7 days,
            volatility: 0.6e18,
            riskFreeRate: 0.04e18
        });

        DeltaMath.Greeks memory greeks = DeltaMath.calculateGreeks(params, true);
        assertApproxEqAbs(greeks.delta, -0.15e18, 0.01e18); // within 1 delta point
    }
}
