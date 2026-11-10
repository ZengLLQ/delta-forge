// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IOptionToken
 * @notice Interface for tokenized option contracts (oTokens) in DeltaForge
 */
interface IOptionToken is IERC20 {
    error OnlyVaultAllowed();
    error OptionExpired();
    error ZeroAddress();

    function underlying() external view returns (address);
    function strikePrice() external view returns (uint256);
    function expiryTimestamp() external view returns (uint256);
    function isPut() external view returns (bool);
    function vault() external view returns (address);
    function epochId() external view returns (uint256);

    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}
