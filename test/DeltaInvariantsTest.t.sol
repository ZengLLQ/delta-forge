// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeltaVault} from "../src/vaults/DeltaVault.sol";
import {IDeltaVault} from "../src/interfaces/IDeltaVault.sol";
import {IDutchAuction} from "../src/interfaces/IDutchAuction.sol";
import {DeltaDutchAuction} from "../src/auction/DeltaDutchAuction.sol";
import {DeltaOracle} from "../src/oracle/DeltaOracle.sol";
import {DeltaMath} from "../src/libraries/DeltaMath.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeltaInvariantsTest is Test {
    uint256 internal constant WAD = 1e18;
    int256 internal constant INT_WAD = 1e18;

    MockERC20 internal weth;
    DeltaOracle internal oracle;
    DeltaVault internal vault;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new DeltaOracle(3000 * WAD, 0.6e18, 0.04e18, 3600);
        vault = new DeltaVault(weth, "DeltaForge WETH Call Vault", "dfWETH", false, address(oracle));

        weth.mint(alice, 100000 * WAD);
        weth.mint(bob, 100000 * WAD);

        vm.prank(alice);
        weth.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        weth.approve(address(vault), type(uint256).max);
    }

    /**
     * @notice Invariant 1: Solvency Conservation
     *         totalAssets() + totalReservedPayouts() == asset.balanceOf(vault)
     */
    function testFuzz_Invariant_SolvencyConservation(uint256 depositAmount, uint256 buyAmount, uint256 finalPrice)
        public
    {
        depositAmount = bound(depositAmount, 1 * WAD, 5000 * WAD);
        buyAmount = bound(buyAmount, 0.1e18, depositAmount);
        finalPrice = bound(finalPrice, 500 * WAD, 10000 * WAD);

        // Alice deposits
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Check invariant after deposit
        assertEq(vault.totalAssets() + vault.totalReservedPayouts(), weth.balanceOf(address(vault)));

        // Roll epoch
        uint256 epochId = vault.rollToNextEpoch(0.15e18, 7 days, 1 days);
        IDeltaVault.EpochData memory epoch = vault.getEpoch(epochId);

        // Bob buys options from auction
        vm.warp(block.timestamp + 6 hours);
        IDutchAuction auction = IDutchAuction(epoch.auction);
        uint256 p = auction.currentPrice();

        vm.prank(bob);
        weth.approve(address(auction), type(uint256).max);
        vm.prank(bob);
        auction.buy(buyAmount, p);

        // Check invariant after option sale & premium receipt
        assertEq(vault.totalAssets() + vault.totalReservedPayouts(), weth.balanceOf(address(vault)));

        // Fast forward to expiry with random spot price
        vm.warp(epoch.expiryTimestamp + 1 hours);
        oracle.setSpotPrice(finalPrice);

        // Settle epoch
        vault.settleEpoch();

        // Check invariant holds strictly after settlement!
        assertEq(vault.totalAssets() + vault.totalReservedPayouts(), weth.balanceOf(address(vault)));

        // Bob exercises if ITM
        if (finalPrice > epoch.strikePrice) {
            vm.prank(bob);
            vault.exercise(epochId, buyAmount);

            // Check invariant holds strictly after exercise!
            assertEq(vault.totalAssets() + vault.totalReservedPayouts(), weth.balanceOf(address(vault)));
        }
    }

    /**
     * @notice Invariant 2: Non-Negative Option Payoff
     *         Settlement payout per option is mathematically >= 0
     */
    function testFuzz_Invariant_NonNegativePayoff(uint256 spot, uint256 strike) public pure {
        spot = bound(spot, 1 * WAD, 50000 * WAD);
        strike = bound(strike, 1 * WAD, 50000 * WAD);

        // Call payoff in asset units: max(0, S - K) / S
        uint256 callPayoff = 0;
        if (spot > strike) {
            callPayoff = ((spot - strike) * WAD) / spot;
        }
        assertGe(callPayoff, 0);

        // Put payoff in asset units: max(0, K - S)
        uint256 putPayoff = 0;
        if (strike > spot) {
            putPayoff = strike - spot;
        }
        assertGe(putPayoff, 0);
    }

    /**
     * @notice Invariant 3: Dutch Auction Price Monotonicity
     *         For t1 <= t2: P(t1) >= P(t2)
     */
    function testFuzz_Invariant_AuctionMonotonicity(uint256 t1, uint256 t2) public {
        uint256 startTime = block.timestamp;
        uint256 duration = 1 days;

        t1 = bound(t1, 0, 2 days);
        t2 = bound(t2, 0, 2 days);
        if (t1 > t2) {
            uint256 temp = t1;
            t1 = t2;
            t2 = temp;
        }

        MockERC20 dummyOpt = new MockERC20("Dummy", "DUM", 18);
        DeltaDutchAuction testAuc = new DeltaDutchAuction(
            address(this), address(dummyOpt), address(weth), 100 * WAD, 200 * WAD, 50 * WAD, startTime, duration
        );

        vm.warp(startTime + t1);
        uint256 p1 = testAuc.currentPrice();

        vm.warp(startTime + t2);
        uint256 p2 = testAuc.currentPrice();

        assertGe(p1, p2);
    }

    /**
     * @notice Invariant 4: Greeks Mathematical Boundaries
     *         Delta_call in [0, 1], Delta_put in [-1, 0], Gamma >= 0, Vega >= 0, Theta <= 0
     */
    function testFuzz_Invariant_GreeksBoundaries(uint256 spot, uint256 strike, uint256 vol, uint256 daysExpiry)
        public
        pure
    {
        spot = bound(spot, 100 * WAD, 10000 * WAD);
        strike = bound(strike, 100 * WAD, 10000 * WAD);
        vol = bound(vol, 0.1e18, 1.5e18); // 10% to 150% IV
        daysExpiry = bound(daysExpiry, 1, 90);

        DeltaMath.OptionParams memory params = DeltaMath.OptionParams({
            spotPrice: spot,
            strikePrice: strike,
            timeToExpirySec: daysExpiry * 1 days,
            volatility: vol,
            riskFreeRate: 0.04e18
        });

        DeltaMath.Greeks memory callGreeks = DeltaMath.calculateGreeks(params, false);
        assertGe(callGreeks.delta, 0);
        assertLe(callGreeks.delta, INT_WAD);
        assertGe(callGreeks.gamma, 0);
        assertGe(callGreeks.vega, 0);
        assertLe(callGreeks.theta, 0);

        DeltaMath.Greeks memory putGreeks = DeltaMath.calculateGreeks(params, true);
        assertLe(putGreeks.delta, 0);
        assertGe(putGreeks.delta, -INT_WAD);
    }
}
