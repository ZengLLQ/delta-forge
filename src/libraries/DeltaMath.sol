// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title DeltaMath
 * @notice High-precision fixed-point math library for Black-Scholes-Merton options pricing,
 *         Greeks calculation, and delta-targeted strike selection.
 * @dev All operations use 18-decimal Wad precision (1e18 = 1.0).
 */
library DeltaMath {
    uint256 internal constant WAD = 1e18;
    int256 internal constant INT_WAD = 1e18;
    uint256 internal constant HALF_WAD = 0.5e18;
    uint256 internal constant SECONDS_PER_YEAR = 31536000; // 365 days

    // ln(2) * 1e18
    int256 internal constant LN2_WAD = 693147180559945309;

    // 1 / sqrt(2 * pi) * 1e18
    uint256 internal constant INV_SQRT_2PI_WAD = 398942280401432678;

    // Abramowitz & Stegun 26.2.17 polynomial constants
    uint256 internal constant P_WAD = 231641900000000000; // 0.2316419
    int256 internal constant B1_WAD = 319381530000000000; // 0.319381530
    int256 internal constant B2_WAD = -356563782000000000; // -0.356563782
    int256 internal constant B3_WAD = 1781477937000000000; // 1.781477937
    int256 internal constant B4_WAD = -1821255978000000000; // -1.821255978
    int256 internal constant B5_WAD = 1330274429000000000; // 1.330274429

    error MathOverflow();
    error MathDivisionByZero();
    error NegativeOrZeroInput();
    error InvalidProbability();

    // -------------------------------------------------------------
    // Basic Fixed-Point Operations
    // -------------------------------------------------------------

    function wadMul(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / WAD;
    }

    function wadDiv(uint256 x, uint256 y) internal pure returns (uint256) {
        if (y == 0) revert MathDivisionByZero();
        return (x * WAD) / y;
    }

    function wadMulInt(int256 x, int256 y) internal pure returns (int256) {
        return (x * y) / INT_WAD;
    }

    function wadDivInt(int256 x, int256 y) internal pure returns (int256) {
        if (y == 0) revert MathDivisionByZero();
        return (x * INT_WAD) / y;
    }

    function wadMin(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function wadMax(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function wadClamp(uint256 val, uint256 minVal, uint256 maxVal) internal pure returns (uint256) {
        if (val < minVal) return minVal;
        if (val > maxVal) return maxVal;
        return val;
    }

    /**
     * @notice Fixed-point square root: sqrt(x * 1e18)
     */
    function wadSqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
        uint256 x = y * WAD;
        z = x;
        uint256 c = (x + 1) / 2;
        while (c < z) {
            z = c;
            c = (x / c + c) / 2;
        }
    }

    /**
     * @notice High-precision fixed-point natural logarithm ln(x / 1e18) * 1e18
     * @dev Uses binary range reduction followed by rapidly-converging odd-powers series
     * @param x Strictly positive value in WAD
     * @return result Signed logarithm in WAD
     */
    function wadLn(uint256 x) internal pure returns (int256 result) {
        if (x == 0) revert NegativeOrZeroInput();

        int256 k = 0;
        uint256 y = x;

        while (y >= 2 * WAD) {
            y /= 2;
            k++;
        }
        while (y < WAD) {
            y *= 2;
            k--;
        }

        // y is now in [WAD, 2 * WAD)
        // z = (y - WAD) / (y + WAD) in [0, 1/3)
        int256 z = int256(((y - WAD) * WAD) / (y + WAD));
        int256 z2 = (z * z) / INT_WAD;
        int256 z3 = (z2 * z) / INT_WAD;
        int256 z5 = (z3 * z2) / INT_WAD;
        int256 z7 = (z5 * z2) / INT_WAD;
        int256 z9 = (z7 * z2) / INT_WAD;
        int256 z11 = (z9 * z2) / INT_WAD;

        int256 series = z + z3 / 3 + z5 / 5 + z7 / 7 + z9 / 9 + z11 / 11;
        int256 logY = 2 * series;

        result = k * LN2_WAD + logY;
    }

    /**
     * @notice High-precision fixed-point exponential e^(x / 1e18) * 1e18
     * @param x Signed input in WAD
     */
    function wadExp(int256 x) internal pure returns (uint256) {
        if (x < -40 * INT_WAD) return 0;
        if (x > 40 * INT_WAD) revert MathOverflow();

        int256 k = x / LN2_WAD;
        int256 r = x - k * LN2_WAD;
        if (r < 0) {
            k -= 1;
            r += LN2_WAD;
        }

        // 8th-order Taylor polynomial for e^r where r in [0, ln(2))
        int256 r2 = (r * r) / INT_WAD;
        int256 r3 = (r2 * r) / INT_WAD;
        int256 r4 = (r3 * r) / INT_WAD;
        int256 r5 = (r4 * r) / INT_WAD;
        int256 r6 = (r5 * r) / INT_WAD;
        int256 r7 = (r6 * r) / INT_WAD;
        int256 r8 = (r7 * r) / INT_WAD;

        int256 term = INT_WAD + r + r2 / 2 + r3 / 6 + r4 / 24 + r5 / 120 + r6 / 720 + r7 / 5040 + r8 / 40320;

        if (k >= 0) {
            return uint256(term) << uint256(k);
        } else {
            return uint256(term) >> uint256(-k);
        }
    }

    // -------------------------------------------------------------
    // Statistical Functions (Normal PDF, CDF, Inverse CDF)
    // -------------------------------------------------------------

    /**
     * @notice Standard normal probability density function: phi(x) = (1 / sqrt(2*pi)) * e^(-x^2 / 2)
     */
    function normalPdf(int256 xWad) internal pure returns (uint256) {
        int256 absX = xWad < 0 ? -xWad : xWad;
        int256 x2 = (absX * absX) / INT_WAD;
        int256 negHalfX2 = -(x2 / 2);
        uint256 expVal = wadExp(negHalfX2);
        return (INV_SQRT_2PI_WAD * expVal) / WAD;
    }

    /**
     * @notice Standard normal cumulative distribution function Phi(x)
     * @dev Abramowitz & Stegun 26.2.17 polynomial approximation (error < 7.5e-8)
     */
    function normalCdf(int256 xWad) internal pure returns (uint256) {
        if (xWad == 0) return HALF_WAD;
        if (xWad < 0) {
            uint256 negCdf = normalCdf(-xWad);
            return negCdf >= WAD ? 0 : WAD - negCdf;
        }
        if (xWad > 7 * INT_WAD) {
            return WAD;
        }

        uint256 ux = uint256(xWad);
        uint256 denom = WAD + (P_WAD * ux) / WAD;
        uint256 t = (WAD * WAD) / denom;
        int256 it = int256(t);

        uint256 phi = normalPdf(xWad);

        // Horner evaluation of polynomial
        int256 poly = it
            * (B1_WAD
                + (it * (B2_WAD + (it * (B3_WAD + (it * (B4_WAD + (it * B5_WAD) / INT_WAD)) / INT_WAD)) / INT_WAD))
                / INT_WAD) / INT_WAD;

        if (poly < 0) poly = 0;
        uint256 phiPoly = (phi * uint256(poly)) / WAD;
        return phiPoly >= WAD ? WAD : WAD - phiPoly;
    }

    /**
     * @notice Inverse standard normal cumulative distribution function: Phi^-1(p)
     * @dev Newton-Raphson solver starting from rational initial estimate
     * @param targetP Probability in WAD: (0.01e18 <= targetP <= 0.99e18)
     */
    function invNormalCdf(uint256 targetP) internal pure returns (int256) {
        if (targetP == 0 || targetP >= WAD) revert InvalidProbability();

        // Initial guess based on sign
        int256 x;
        if (targetP == HALF_WAD) return 0;
        if (targetP > HALF_WAD) {
            x = int256(((targetP - HALF_WAD) * 3 * WAD) / HALF_WAD);
        } else {
            x = -int256(((HALF_WAD - targetP) * 3 * WAD) / HALF_WAD);
        }

        // 5 iterations of Newton-Raphson: x_{n+1} = x_n - (Phi(x_n) - p) / phi(x_n)
        for (uint256 i = 0; i < 5; i++) {
            uint256 cdf = normalCdf(x);
            int256 diff = int256(cdf) - int256(targetP);
            uint256 pdf = normalPdf(x);
            if (pdf == 0) break;
            int256 step = (diff * INT_WAD) / int256(pdf);
            x -= step;
        }

        return x;
    }

    // -------------------------------------------------------------
    // Black-Scholes-Merton Pricing & Greeks
    // -------------------------------------------------------------

    struct OptionParams {
        uint256 spotPrice; // S in WAD
        uint256 strikePrice; // K in WAD
        uint256 timeToExpirySec; // T in seconds
        uint256 volatility; // sigma in WAD (e.g. 0.60e18)
        uint256 riskFreeRate; // r in WAD (e.g. 0.04e18)
    }

    struct Greeks {
        int256 delta; // Delta in WAD (Call: [0, 1e18], Put: [-1e18, 0])
        uint256 gamma; // Gamma in WAD
        uint256 vega; // Vega in WAD
        int256 theta; // Theta in WAD (annual decay)
    }

    /**
     * @notice Calculates d1 and d2 for Black-Scholes formula
     */
    function calculateD1D2(OptionParams memory params) internal pure returns (int256 d1, int256 d2) {
        if (params.spotPrice == 0 || params.strikePrice == 0 || params.timeToExpirySec == 0 || params.volatility == 0) {
            revert NegativeOrZeroInput();
        }

        // T in Wad years: (seconds * 1e18) / 31536000
        uint256 tWad = (params.timeToExpirySec * WAD) / SECONDS_PER_YEAR;
        uint256 sqrtT = wadSqrt(tWad);

        // ln(S / K)
        int256 lnSK = wadLn((params.spotPrice * WAD) / params.strikePrice);

        // (r + 0.5 * sigma^2) * T
        uint256 halfVol2 = wadMul(params.volatility, params.volatility) / 2;
        uint256 drift = params.riskFreeRate + halfVol2;
        int256 driftT = int256(wadMul(drift, tWad));

        // numerator = ln(S/K) + (r + 0.5*sigma^2)*T
        int256 num = lnSK + driftT;

        // denominator = sigma * sqrt(T)
        uint256 denom = wadMul(params.volatility, sqrtT);
        if (denom == 0) revert MathDivisionByZero();

        d1 = (num * INT_WAD) / int256(denom);
        d2 = d1 - int256(denom);
    }

    /**
     * @notice Computes European Call and Put theoretical prices in WAD
     */
    function blackScholesPrice(OptionParams memory params) internal pure returns (uint256 callPrice, uint256 putPrice) {
        (int256 d1, int256 d2) = calculateD1D2(params);

        uint256 tWad = (params.timeToExpirySec * WAD) / SECONDS_PER_YEAR;
        int256 negRT = -int256(wadMul(params.riskFreeRate, tWad));
        uint256 discountFactor = wadExp(negRT);

        uint256 phiD1 = normalCdf(d1);
        uint256 phiD2 = normalCdf(d2);

        // Call = S * Phi(d1) - K * e^(-rT) * Phi(d2)
        uint256 term1 = wadMul(params.spotPrice, phiD1);
        uint256 term2 = wadMul(params.strikePrice, wadMul(discountFactor, phiD2));
        callPrice = term1 > term2 ? term1 - term2 : 0;

        // Put = K * e^(-rT) * Phi(-d2) - S * Phi(-d1)
        uint256 phiNegD1 = normalCdf(-d1);
        uint256 phiNegD2 = normalCdf(-d2);
        uint256 putTerm1 = wadMul(params.strikePrice, wadMul(discountFactor, phiNegD2));
        uint256 putTerm2 = wadMul(params.spotPrice, phiNegD1);
        putPrice = putTerm1 > putTerm2 ? putTerm1 - putTerm2 : 0;
    }

    /**
     * @notice Calculates analytical Greeks for an option position
     */
    function calculateGreeks(OptionParams memory params, bool isPut) internal pure returns (Greeks memory greeks) {
        (int256 d1, int256 d2) = calculateD1D2(params);
        uint256 tWad = (params.timeToExpirySec * WAD) / SECONDS_PER_YEAR;
        uint256 sqrtT = wadSqrt(tWad);

        uint256 phiD1 = normalCdf(d1);
        uint256 pdfD1 = normalPdf(d1);

        if (!isPut) {
            greeks.delta = int256(phiD1);
        } else {
            greeks.delta = int256(phiD1) - INT_WAD;
        }

        // Gamma = pdf(d1) / (S * sigma * sqrt(T))
        uint256 gammaDenom = wadMul(params.spotPrice, wadMul(params.volatility, sqrtT));
        if (gammaDenom > 0) {
            greeks.gamma = (pdfD1 * WAD) / gammaDenom;
        }

        // Vega = S * sqrt(T) * pdf(d1)
        greeks.vega = wadMul(params.spotPrice, wadMul(sqrtT, pdfD1));

        // Theta (Call): - (S * pdf(d1) * sigma) / (2 * sqrt(T)) - r * K * e^(-rT) * Phi(d2)
        int256 negRT = -int256(wadMul(params.riskFreeRate, tWad));
        uint256 discountFactor = wadExp(negRT);
        uint256 phiD2 = normalCdf(d2);

        uint256 thetaTerm1 = (wadMul(params.spotPrice, wadMul(pdfD1, params.volatility)) * WAD) / (2 * sqrtT);
        uint256 thetaTerm2 = wadMul(params.riskFreeRate, wadMul(params.strikePrice, wadMul(discountFactor, phiD2)));

        greeks.theta = -int256(thetaTerm1 + thetaTerm2);
    }

    /**
     * @notice Determines strike price K that targets a specific Delta for Covered Call or Cash-Secured Put
     * @param spotPrice Current spot price S in WAD
     * @param targetDelta Target delta in WAD (e.g. 0.15e18 for 15-delta Call, or 0.15e18 for 15-delta Put)
     * @param timeToExpirySec Duration in seconds
     * @param volatility Implied volatility in WAD
     * @param riskFreeRate Risk-free rate in WAD
     * @param isPut False for Covered Call, True for Cash-Secured Put
     */
    function getStrikeForDelta(
        uint256 spotPrice,
        uint256 targetDelta,
        uint256 timeToExpirySec,
        uint256 volatility,
        uint256 riskFreeRate,
        bool isPut
    ) internal pure returns (uint256 strikePrice) {
        uint256 tWad = (timeToExpirySec * WAD) / SECONDS_PER_YEAR;
        uint256 sqrtT = wadSqrt(tWad);

        int256 targetD1;
        if (!isPut) {
            // For Call: Delta = Phi(d1) = targetDelta
            targetD1 = invNormalCdf(targetDelta);
        } else {
            // For Put: Delta = Phi(d1) - 1 => Phi(d1) = 1 - targetDelta
            targetD1 = invNormalCdf(WAD - targetDelta);
        }

        // ln(K/S) = -d1 * sigma * sqrt(T) + (r + 0.5 * sigma^2) * T
        uint256 halfVol2 = wadMul(volatility, volatility) / 2;
        uint256 drift = riskFreeRate + halfVol2;
        int256 driftT = int256(wadMul(drift, tWad));

        int256 d1SigmaSqrtT = (targetD1 * int256(wadMul(volatility, sqrtT))) / INT_WAD;
        int256 exponent = -d1SigmaSqrtT + driftT;

        uint256 expFactor = wadExp(exponent);
        strikePrice = wadMul(spotPrice, expFactor);
    }
}
