// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeltaVault} from "../src/vaults/DeltaVault.sol";
import {IDeltaVault} from "../src/interfaces/IDeltaVault.sol";
import {DeltaOracle} from "../src/oracle/DeltaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract DeltaVaultTest is Test {
    uint256 internal constant WAD = 1e18;

    MockERC20 internal weth;
    MockERC20 internal usdc;
    DeltaOracle internal oracle;
    DeltaVault internal callVault;
    DeltaVault internal putVault;

    address internal owner = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal attacker = address(0xBAD);

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 18);

        // Spot $3000, 60% IV, 4% risk-free rate, 1 hr staleness
        oracle = new DeltaOracle(3000 * WAD, 0.6e18, 0.04e18, 3600);

        // Covered Call Vault (underlying WETH)
        callVault = new DeltaVault(weth, "DeltaForge WETH Call Vault", "dfWETH", false, address(oracle));

        // Cash-Secured Put Vault (underlying USDC)
        putVault = new DeltaVault(usdc, "DeltaForge USDC Put Vault", "dfUSDC", true, address(oracle));

        // Mint tokens to users
        weth.mint(alice, 100 * WAD);
        weth.mint(bob, 100 * WAD);
        weth.mint(attacker, 100 * WAD);

        usdc.mint(alice, 300000 * WAD);
        usdc.mint(bob, 300000 * WAD);

        vm.prank(alice);
        weth.approve(address(callVault), type(uint256).max);

        vm.prank(bob);
        weth.approve(address(callVault), type(uint256).max);

        vm.prank(attacker);
        weth.approve(address(callVault), type(uint256).max);

        vm.prank(alice);
        usdc.approve(address(putVault), type(uint256).max);
    }

    function test_VaultInitialization() public view {
        assertEq(callVault.name(), "DeltaForge WETH Call Vault");
        assertEq(callVault.symbol(), "dfWETH");
        assertEq(callVault.asset(), address(weth));
        assertFalse(callVault.isPutVault());
        assertEq(address(callVault.oracle()), address(oracle));
        assertEq(callVault.currentEpoch(), 0);
        assertEq(callVault.totalAssets(), 0);

        assertTrue(putVault.isPutVault());
        assertEq(putVault.asset(), address(usdc));
    }

    function test_DepositAndWithdraw() public {
        // Alice deposits 10 WETH
        vm.prank(alice);
        uint256 shares = callVault.deposit(10 * WAD, alice);

        assertGt(shares, 0);
        assertEq(callVault.totalAssets(), 10 * WAD);
        assertEq(callVault.balanceOf(alice), shares);

        // Alice withdraws 10 WETH
        vm.prank(alice);
        uint256 assetsWithdrawn = callVault.redeem(shares, alice, alice);

        assertApproxEqAbs(assetsWithdrawn, 10 * WAD, 100);
        assertEq(callVault.totalAssets(), 0);
        assertEq(weth.balanceOf(alice), 100 * WAD);
    }

    function test_VirtualShares_InflationAttackDefense() public {
        // Attacker deposits 1 wei of WETH
        vm.prank(attacker);
        callVault.deposit(1, attacker);

        // Attacker donates 50 WETH directly to vault to inflate share price
        vm.prank(attacker);
        weth.transfer(address(callVault), 50 * WAD);

        // Without virtual shares offset, Alice depositing 10 WETH would round down to 0 shares!
        // With OpenZeppelin virtual shares offset = 9, Alice receives non-zero shares
        vm.prank(alice);
        uint256 aliceShares = callVault.deposit(10 * WAD, alice);

        assertGt(aliceShares, 0);

        // Alice can redeem her shares and get her assets back without loss to attacker
        vm.prank(alice);
        uint256 aliceRedeemed = callVault.redeem(aliceShares, alice, alice);

        // Alice gets back ~10 WETH (within 0.0001% precision)
        assertApproxEqRel(aliceRedeemed, 10 * WAD, 1e14);
    }

    function test_RollToNextEpoch_CoveredCall() public {
        // Alice deposits 50 WETH
        vm.prank(alice);
        callVault.deposit(50 * WAD, alice);

        // Owner rolls epoch with 15-delta Call
        uint256 epochId = callVault.rollToNextEpoch(0.15e18, 7 days, 1 days);
        assertEq(epochId, 1);
        assertEq(callVault.currentEpoch(), 1);

        IDeltaVault.EpochData memory epoch = callVault.getEpoch(1);
        assertEq(uint8(epoch.state), uint8(IDeltaVault.EpochState.LOCKED));
        assertGt(epoch.strikePrice, 3000 * WAD); // Call strike > spot
        assertEq(epoch.lockedCollateral, 50 * WAD);
        assertEq(epoch.expiryTimestamp, block.timestamp + 7 days);
        assertTrue(epoch.oToken != address(0));
        assertTrue(epoch.auction != address(0));
    }

    function test_RollToNextEpoch_CashSecuredPut() public {
        // Alice deposits 150,000 USDC
        vm.prank(alice);
        putVault.deposit(150000 * WAD, alice);

        // Owner rolls epoch with 15-delta Put
        uint256 epochId = putVault.rollToNextEpoch(0.15e18, 7 days, 1 days);
        assertEq(epochId, 1);

        IDeltaVault.EpochData memory epoch = putVault.getEpoch(1);
        assertEq(uint8(epoch.state), uint8(IDeltaVault.EpochState.LOCKED));
        assertLt(epoch.strikePrice, 3000 * WAD); // Put strike < spot
        assertEq(epoch.lockedCollateral, 150000 * WAD);
    }

    function test_CannotRollWhileActive_Reverts() public {
        vm.prank(alice);
        callVault.deposit(20 * WAD, alice);

        callVault.rollToNextEpoch(0.15e18, 7 days, 1 days);

        // Trying to roll again while Epoch 1 is still active
        vm.expectRevert(IDeltaVault.InvalidEpochState.selector);
        callVault.rollToNextEpoch(0.15e18, 7 days, 1 days);
    }

    function test_CannotSettleBeforeExpiry_Reverts() public {
        vm.prank(alice);
        callVault.deposit(20 * WAD, alice);

        callVault.rollToNextEpoch(0.15e18, 7 days, 1 days);

        // Trying to settle immediately (before 7 days)
        vm.expectRevert(IDeltaVault.EpochNotExpired.selector);
        callVault.settleEpoch();
    }

    function test_PauseUnpause() public {
        callVault.pause();

        // Deposits revert when paused
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        callVault.deposit(10 * WAD, alice);

        callVault.unpause();

        // Deposits succeed when unpaused
        vm.prank(alice);
        uint256 shares = callVault.deposit(10 * WAD, alice);
        assertGt(shares, 0);
    }
}
