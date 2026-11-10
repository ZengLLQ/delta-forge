// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {DeltaVault} from "../src/vaults/DeltaVault.sol";
import {DeltaOracle} from "../src/oracle/DeltaOracle.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

contract DeployDeltaForge is Script {
    uint256 internal constant WAD = 1e18;

    function run() external returns (address oracleAddr, address callVaultAddr, address putVaultAddr) {
        vm.startBroadcast();

        // 1. Deploy Mock Tokens (or reference existing addresses on live networks)
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 18);

        // 2. Deploy Oracle ($3000 initial spot, 60% IV, 4% risk-free rate, 1 hr max staleness)
        DeltaOracle oracle = new DeltaOracle(3000 * WAD, 0.6e18, 0.04e18, 3600);
        oracleAddr = address(oracle);

        // 3. Deploy Covered Call Vault (WETH)
        DeltaVault callVault = new DeltaVault(weth, "DeltaForge WETH Covered Call Vault", "dfWETH", false, oracleAddr);
        callVaultAddr = address(callVault);

        // 4. Deploy Cash-Secured Put Vault (USDC)
        DeltaVault putVault = new DeltaVault(usdc, "DeltaForge USDC Cash-Secured Put Vault", "dfUSDC", true, oracleAddr);
        putVaultAddr = address(putVault);

        console2.log("=== DeltaForge Deployment Completed ===");
        console2.log("Oracle:", oracleAddr);
        console2.log("WETH Call Vault:", callVaultAddr);
        console2.log("USDC Put Vault:", putVaultAddr);

        vm.stopBroadcast();
    }
}
