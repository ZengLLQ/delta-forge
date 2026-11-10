// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IOptionToken} from "../interfaces/IOptionToken.sol";

/**
 * @title OptionToken
 * @notice ERC-20 token representing fractionalized European option contracts (oTokens) in DeltaForge
 * @dev Controlled strictly by the issuing DeltaVault instance
 */
contract OptionToken is ERC20, IOptionToken {
    address public immutable override underlying;
    uint256 public immutable override strikePrice;
    uint256 public immutable override expiryTimestamp;
    bool public immutable override isPut;
    address public immutable override vault;
    uint256 public immutable override epochId;

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVaultAllowed();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address underlying_,
        uint256 strikePrice_,
        uint256 expiryTimestamp_,
        bool isPut_,
        uint256 epochId_
    ) ERC20(name_, symbol_) {
        if (underlying_ == address(0) || msg.sender == address(0)) revert ZeroAddress();
        underlying = underlying_;
        strikePrice = strikePrice_;
        expiryTimestamp = expiryTimestamp_;
        isPut = isPut_;
        vault = msg.sender;
        epochId = epochId_;
    }

    /**
     * @notice Mints options to recipient
     * @dev Only callable by the owning vault prior to expiry
     */
    function mint(address to, uint256 amount) external override onlyVault {
        if (block.timestamp >= expiryTimestamp) revert OptionExpired();
        _mint(to, amount);
    }

    /**
     * @notice Burns options upon exercise or redemption
     * @dev Only callable by the owning vault
     */
    function burn(address from, uint256 amount) external override onlyVault {
        _burn(from, amount);
    }
}
