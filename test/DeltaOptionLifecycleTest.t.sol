// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeltaVault} from "../src/vaults/DeltaVault.sol";
import {IDeltaVault} from "../src/interfaces/IDeltaVault.sol";
import {IDutchAuction} from "../src/interfaces/IDutchAuction.sol";
import {IOptionToken} from "../src/interfaces/IOptionToken.sol";
import {DeltaOracle} from "../src/oracle/DeltaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeltaOptionLifecycleTest is Test {
    uint256 internal constant WAD = 1e18;

    MockERC20 internal weth;
    MockERC20 internal usdc;
    DeltaOracle internal oracle;
    DeltaVault internal callVault;
    DeltaVault internal putVault;

    address internal owner = address(this);
    address internal alice = address(0xA11CE); // Depositor
    address internal bob = address(0xB0B); // Market maker / Option Buyer

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 18);

        oracle = new DeltaOracle(3000 * WAD, 0.6e18, 0.04e18, 3600);

        callVault = new DeltaVault(weth, "DeltaForge WETH Call Vault", "dfWETH", false, address(oracle));
        putVault = new DeltaVault(usdc, "DeltaForge USDC Put Vault", "dfUSDC", true, address(oracle));

        weth.mint(alice, 100 * WAD);
        weth.mint(bob, 50 * WAD);

        usdc.mint(alice, 300000 * WAD);
        usdc.mint(bob, 100000 * WAD);

        vm.prank(alice);
        weth.approve(address(callVault), type(uint256).max);

        vm.prank(bob);
        weth.approve(address(callVault), type(uint256).max);

        vm.prank(alice);
        usdc.approve(address(putVault), type(uint256).max);

        vm.prank(bob);
        usdc.approve(address(putVault), type(uint256).max);
    }

    function test_Lifecycle_OTM_Expiry_FullYieldRetention() public {
        // 1. Alice deposits 100 WETH into vault
        vm.prank(alice);
        uint256 aliceShares = callVault.deposit(100 * WAD, alice);
        assertEq(callVault.totalAssets(), 100 * WAD);

        // 2. Vault owner rolls to Epoch 1 (15-delta Call, 7 days duration, 1 day auction)
        uint256 epochId = callVault.rollToNextEpoch(0.15e18, 7 days, 1 days);
        IDeltaVault.EpochData memory epoch = callVault.getEpoch(epochId);
        uint256 strikePrice = epoch.strikePrice;

        // Call strike is OTM (e.g. ~$3283)
        assertGt(strikePrice, 3000 * WAD);

        // 3. Bob buys 50 options from the Dutch auction at t = 12 hours
        vm.warp(block.timestamp + 12 hours);
        IDutchAuction auction = IDutchAuction(epoch.auction);
        uint256 clearingPrice = auction.currentPrice();

        vm.prank(bob);
        weth.approve(address(auction), type(uint256).max);

        vm.prank(bob);
        uint256 premiumPaid = auction.buy(50 * WAD, clearingPrice);
        assertGt(premiumPaid, 0);

        // 4. Time elapses to 7 days + 1 hour (expiry passed)
        // Spot price rises to $3100, but remains below Strike $3283 (Out-Of-The-Money!)
        vm.warp(epoch.expiryTimestamp + 1 hours);
        oracle.setSpotPrice(3100 * WAD);

        // 5. Vault settles epoch
        (uint256 settlementPrice, uint256 totalPayout) = callVault.settleEpoch();

        assertEq(settlementPrice, 3100 * WAD);
        assertEq(totalPayout, 0); // OTM -> zero payout

        // 6. Verification: 100% of collateral preserved + Bob's option premium retained as profit!
        uint256 totalAssetsAfter = callVault.totalAssets();
        assertEq(totalAssetsAfter, 100 * WAD + premiumPaid);

        // 7. Alice redeems all shares and receives her 100 WETH + the earned premium!
        vm.prank(alice);
        uint256 assetsReceived = callVault.redeem(aliceShares, alice, alice);

        assertApproxEqAbs(assetsReceived, 100 * WAD + premiumPaid, 100);
        assertGt(assetsReceived, 100 * WAD);
    }

    function test_Lifecycle_ITM_Expiry_And_Exercise() public {
        // 1. Alice deposits 100 WETH
        vm.prank(alice);
        callVault.deposit(100 * WAD, alice);

        // 2. Roll to Epoch 1
        uint256 epochId = callVault.rollToNextEpoch(0.15e18, 7 days, 1 days);
        IDeltaVault.EpochData memory epoch = callVault.getEpoch(epochId);

        // 3. Bob buys 20 options from the Dutch auction
        vm.warp(block.timestamp + 6 hours);
        IDutchAuction auction = IDutchAuction(epoch.auction);
        uint256 price = auction.currentPrice();

        vm.prank(bob);
        weth.approve(address(auction), type(uint256).max);

        vm.prank(bob);
        auction.buy(20 * WAD, price);

        IOptionToken oToken = IOptionToken(epoch.oToken);
        assertEq(oToken.balanceOf(bob), 20 * WAD);

        // 4. Spot price jumps to $4000 (well above strikePrice ~$3283 -> In-The-Money!)
        vm.warp(epoch.expiryTimestamp + 1 hours);
        oracle.setSpotPrice(4000 * WAD);

        // 5. Vault settles epoch
        (uint256 settlementPrice, uint256 totalPayout) = callVault.settleEpoch();

        assertEq(settlementPrice, 4000 * WAD);
        assertGt(totalPayout, 0); // ITM -> positive payout

        // 6. Bob exercises his 20 options and receives payout
        uint256 bobBalBefore = weth.balanceOf(bob);

        vm.prank(bob);
        uint256 bobPayout = callVault.exercise(epochId, 20 * WAD);

        assertEq(bobPayout, totalPayout);
        assertEq(weth.balanceOf(bob), bobBalBefore + bobPayout);
        assertEq(oToken.balanceOf(bob), 0); // Options burned

        // 7. Vault remains solvent, reserved payouts cleared
        assertEq(callVault.totalReservedPayouts(), 0);
        assertGt(callVault.totalAssets(), 0);
    }

    function test_Lifecycle_MultiEpoch_ContinuousCompounding() public {
        // Alice deposits 50 WETH
        vm.prank(alice);
        callVault.deposit(50 * WAD, alice);

        // Epoch 1
        callVault.rollToNextEpoch(0.15e18, 7 days, 1 days);
        IDeltaVault.EpochData memory ep1 = callVault.getEpoch(1);

        // Bob buys 10 options
        vm.warp(block.timestamp + 6 hours);
        IDutchAuction auc1 = IDutchAuction(ep1.auction);
        uint256 p1 = auc1.currentPrice();
        vm.prank(bob);
        weth.approve(address(auc1), type(uint256).max);
        vm.prank(bob);
        auc1.buy(10 * WAD, p1);

        // Fast-forward to Epoch 1 expiry and settle OTM
        vm.warp(ep1.expiryTimestamp + 1 hours);
        oracle.setSpotPrice(2950 * WAD);
        callVault.settleEpoch();

        uint256 assetsAfterEp1 = callVault.totalAssets();
        assertGt(assetsAfterEp1, 50 * WAD); // Compounded!

        // Epoch 2 rolls automatically with the higher compounded balance!
        uint256 ep2Id = callVault.rollToNextEpoch(0.15e18, 7 days, 1 days);
        assertEq(ep2Id, 2);

        IDeltaVault.EpochData memory ep2 = callVault.getEpoch(2);
        assertEq(ep2.lockedCollateral, assetsAfterEp1);

        // Bob approves and buys in Epoch 2
        IDutchAuction auc2 = IDutchAuction(ep2.auction);
        uint256 p2 = auc2.currentPrice();
        vm.prank(bob);
        weth.approve(address(auc2), type(uint256).max);
        vm.prank(bob);
        auc2.buy(5 * WAD, p2);

        // Fast forward & settle Epoch 2
        vm.warp(ep2.expiryTimestamp + 1 hours);
        oracle.setSpotPrice(2900 * WAD);
        callVault.settleEpoch();

        assertEq(callVault.currentEpoch(), 2);
    }

    function test_CashSecuredPut_Lifecycle_OTM() public {
        // Alice deposits 300,000 USDC
        vm.prank(alice);
        uint256 aliceShares = putVault.deposit(300000 * WAD, alice);

        // Roll Epoch 1 for Put Vault
        uint256 epochId = putVault.rollToNextEpoch(0.15e18, 7 days, 1 days);
        IDeltaVault.EpochData memory epoch = putVault.getEpoch(epochId);

        // Put strike is OTM (< $3000, e.g. ~$2740)
        assertLt(epoch.strikePrice, 3000 * WAD);

        // Bob buys 20 put options
        vm.warp(block.timestamp + 6 hours);
        IDutchAuction auction = IDutchAuction(epoch.auction);
        uint256 price = auction.currentPrice();

        vm.prank(bob);
        usdc.approve(address(auction), type(uint256).max);

        vm.prank(bob);
        uint256 premiumPaid = auction.buy(20 * WAD, price);
        assertGt(premiumPaid, 0);

        // Fast forward: Spot at expiry = $2900 (above strike $2740 -> Put expires OTM!)
        vm.warp(epoch.expiryTimestamp + 1 hours);
        oracle.setSpotPrice(2900 * WAD);

        // Settle epoch
        (, uint256 totalPayout) = putVault.settleEpoch();
        assertEq(totalPayout, 0);

        // Verify full principal + premium profit retained
        assertEq(putVault.totalAssets(), 300000 * WAD + premiumPaid);

        // Alice withdraws with profit in USDC
        vm.prank(alice);
        uint256 assetsReceived = putVault.redeem(aliceShares, alice, alice);
        assertApproxEqAbs(assetsReceived, 300000 * WAD + premiumPaid, 100);
    }
}
