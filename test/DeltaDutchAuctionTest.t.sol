// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeltaDutchAuction} from "../src/auction/DeltaDutchAuction.sol";
import {IDutchAuction} from "../src/interfaces/IDutchAuction.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeltaDutchAuctionTest is Test {
    uint256 internal constant WAD = 1e18;

    MockERC20 internal paymentToken;
    MockERC20 internal oToken;
    DeltaDutchAuction internal auction;

    address internal vault = address(0xCAFE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal totalOptions = 100 * WAD;
    uint256 internal startPrice = 150 * WAD; // $150
    uint256 internal reservePrice = 50 * WAD; // $50
    uint256 internal startTime;
    uint256 internal duration = 1 days;

    function setUp() public {
        startTime = block.timestamp;

        paymentToken = new MockERC20("USD Coin", "USDC", 18);
        oToken = new MockERC20("Delta Option", "dCALL", 18);

        auction = new DeltaDutchAuction(
            vault, address(oToken), address(paymentToken), totalOptions, startPrice, reservePrice, startTime, duration
        );

        // Fund auction with oTokens
        oToken.mint(address(auction), totalOptions);

        // Fund buyers with payment tokens
        paymentToken.mint(alice, 50000 * WAD);
        paymentToken.mint(bob, 50000 * WAD);

        vm.prank(alice);
        paymentToken.approve(address(auction), type(uint256).max);

        vm.prank(bob);
        paymentToken.approve(address(auction), type(uint256).max);
    }

    function test_InitialParameters() public view {
        assertEq(auction.vault(), vault);
        assertEq(auction.oToken(), address(oToken));
        assertEq(auction.paymentToken(), address(paymentToken));
        assertEq(auction.totalOptions(), totalOptions);
        assertEq(auction.startPrice(), startPrice);
        assertEq(auction.reservePrice(), reservePrice);
        assertEq(auction.currentPrice(), startPrice);
        assertFalse(auction.isConcluded());
    }

    function test_LinearPriceDecay() public {
        // At t = 0: Price = $150
        assertEq(auction.currentPrice(), 150 * WAD);

        // At t = 6 hours (25% elapsed): Price = 150 - 0.25 * (150 - 50) = $125
        vm.warp(startTime + 6 hours);
        assertApproxEqAbs(auction.currentPrice(), 125 * WAD, 100);

        // At t = 12 hours (50% elapsed): Price = 150 - 0.50 * 100 = $100
        vm.warp(startTime + 12 hours);
        assertApproxEqAbs(auction.currentPrice(), 100 * WAD, 100);

        // At t = 18 hours (75% elapsed): Price = $75
        vm.warp(startTime + 18 hours);
        assertApproxEqAbs(auction.currentPrice(), 75 * WAD, 100);

        // At t = 24 hours (100% elapsed): Price = $50 (floor)
        vm.warp(startTime + 24 hours);
        assertEq(auction.currentPrice(), 50 * WAD);

        // At t = 30 hours: Floor holds
        vm.warp(startTime + 30 hours);
        assertEq(auction.currentPrice(), 50 * WAD);
    }

    function test_Buy_Success() public {
        // Warp to midpoint: Price = $100
        vm.warp(startTime + 12 hours);
        uint256 price = auction.currentPrice();

        uint256 buyAmount = 10 * WAD;
        uint256 expectedCost = (buyAmount * price) / WAD; // 10 * 100 = 1000 WAD

        vm.prank(alice);
        uint256 paid = auction.buy(buyAmount, price);

        assertEq(paid, expectedCost);
        assertEq(oToken.balanceOf(alice), buyAmount);
        assertEq(paymentToken.balanceOf(address(auction)), expectedCost);
        assertEq(auction.totalSold(), buyAmount);
        assertEq(auction.totalPremium(), expectedCost);
    }

    function test_Buy_SlippageExceeded_Reverts() public {
        // Price is $150 at t = 0; Alice sets maxPrice = $140
        vm.prank(alice);
        vm.expectRevert(IDutchAuction.SlippageExceeded.selector);
        auction.buy(5 * WAD, 140 * WAD);
    }

    function test_Buy_InsufficientSupply_Reverts() public {
        vm.warp(startTime + 1 hours);
        uint256 price = auction.currentPrice();

        // Attempting to buy 101 options when only 100 exist
        vm.prank(alice);
        vm.expectRevert(IDutchAuction.InsufficientAuctionSupply.selector);
        auction.buy(101 * WAD, price);
    }

    function test_AutoConclude_WhenSoldOut() public {
        vm.warp(startTime + 6 hours);
        uint256 price = auction.currentPrice();

        // Alice buys all 100 options
        vm.prank(alice);
        auction.buy(100 * WAD, price);

        assertTrue(auction.isConcluded());
        assertEq(auction.totalSold(), 100 * WAD);

        // Vault should have received the collected premium immediately
        uint256 expectedPremium = (100 * WAD * price) / WAD;
        assertEq(paymentToken.balanceOf(vault), expectedPremium);
    }

    function test_ConcludeAuction_AfterDuration() public {
        // Alice buys 40 options at halfway mark
        vm.warp(startTime + 12 hours);
        uint256 price = auction.currentPrice();
        vm.prank(alice);
        auction.buy(40 * WAD, price);

        // Warp past auction duration
        vm.warp(startTime + 25 hours);

        // Anyone can finalize after duration
        vm.prank(bob);
        (uint256 sold, uint256 premium, uint256 unsold) = auction.concludeAuction();

        assertEq(sold, 40 * WAD);
        assertEq(unsold, 60 * WAD);
        assertTrue(auction.isConcluded());

        // Vault receives payment & gets unsold oTokens back
        assertEq(paymentToken.balanceOf(vault), premium);
        assertEq(oToken.balanceOf(vault), 60 * WAD);
    }

    function test_ConcludeAuction_EarlyByNonVault_Reverts() public {
        vm.warp(startTime + 2 hours);
        vm.prank(bob);
        vm.expectRevert(IDutchAuction.Unauthorized.selector);
        auction.concludeAuction();
    }
}
