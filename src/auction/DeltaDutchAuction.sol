// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDutchAuction} from "../interfaces/IDutchAuction.sol";
import {TransientLock} from "../libraries/TransientLock.sol";

/**
 * @title DeltaDutchAuction
 * @notice Continuous linear Dutch auction distributing newly minted option tokens (oTokens)
 * @dev Price starts at ceiling (1.5x BS) and decays linearly to reserve price (0.5x BS)
 */
contract DeltaDutchAuction is IDutchAuction, TransientLock {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;

    address public immutable vault;
    address public immutable oToken;
    address public immutable paymentToken;

    uint256 public immutable totalOptions;
    uint256 public immutable startPrice;
    uint256 public immutable reservePrice;
    uint256 public immutable startTime;
    uint256 public immutable duration;

    uint256 public override totalSold;
    uint256 public override totalPremium;
    bool public override isConcluded;

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    constructor(
        address vault_,
        address oToken_,
        address paymentToken_,
        uint256 totalOptions_,
        uint256 startPrice_,
        uint256 reservePrice_,
        uint256 startTime_,
        uint256 duration_
    ) {
        if (vault_ == address(0) || oToken_ == address(0) || paymentToken_ == address(0)) {
            revert ZeroAmount();
        }
        if (totalOptions_ == 0 || startPrice_ == 0 || reservePrice_ > startPrice_ || duration_ == 0) {
            revert ZeroAmount();
        }

        vault = vault_;
        oToken = oToken_;
        paymentToken = paymentToken_;
        totalOptions = totalOptions_;
        startPrice = startPrice_;
        reservePrice = reservePrice_;
        startTime = startTime_;
        duration = duration_;
    }

    /**
     * @notice Computes current clearing price per option based on elapsed auction time
     */
    function currentPrice() public view override returns (uint256) {
        if (block.timestamp <= startTime) {
            return startPrice;
        }
        uint256 elapsed = block.timestamp - startTime;
        if (elapsed >= duration) {
            return reservePrice;
        }

        uint256 priceSpread = startPrice - reservePrice;
        uint256 priceDrop = (priceSpread * elapsed) / duration;
        return startPrice - priceDrop;
    }

    /**
     * @notice Purchases oTokens at current Dutch auction clearing price
     * @param optionAmount Number of option tokens to purchase
     * @param maxPricePerOption Slippage protection ceiling
     * @return premiumPaid Total payment transferred
     */
    function buy(uint256 optionAmount, uint256 maxPricePerOption)
        external
        override
        nonReentrant
        returns (uint256 premiumPaid)
    {
        if (block.timestamp < startTime) revert AuctionNotStarted();
        if (isConcluded) revert AuctionAlreadyConcluded();
        if (optionAmount == 0) revert ZeroAmount();

        uint256 available = totalOptions - totalSold;
        if (optionAmount > available) revert InsufficientAuctionSupply();

        uint256 clearingPrice = currentPrice();
        if (clearingPrice > maxPricePerOption) revert SlippageExceeded();

        // premiumPaid = (optionAmount * clearingPrice) / WAD
        premiumPaid = (optionAmount * clearingPrice) / WAD;
        if (premiumPaid == 0) revert ZeroAmount();

        totalSold += optionAmount;
        totalPremium += premiumPaid;

        // Pull payment from bidder directly to auction contract
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), premiumPaid);

        // Transfer oTokens to bidder
        IERC20(oToken).safeTransfer(msg.sender, optionAmount);

        emit BidPlaced(msg.sender, optionAmount, clearingPrice, premiumPaid);

        // If all options are sold, auto-conclude
        if (totalSold == totalOptions) {
            _finalizeAuction();
        }
    }

    /**
     * @notice Concludes auction and transfers collected premiums & unsold options back to vault
     */
    function concludeAuction() external override nonReentrant returns (uint256 sold, uint256 premium, uint256 unsold) {
        if (isConcluded) revert AuctionAlreadyConcluded();
        if (block.timestamp < startTime + duration && totalSold < totalOptions && msg.sender != vault) {
            revert Unauthorized();
        }

        return _finalizeAuction();
    }

    function _finalizeAuction() internal returns (uint256 sold, uint256 premium, uint256 unsold) {
        isConcluded = true;
        sold = totalSold;
        premium = totalPremium;
        unsold = totalOptions - totalSold;

        // Transfer all collected premium to the vault
        if (premium > 0) {
            IERC20(paymentToken).safeTransfer(vault, premium);
        }

        // Return unsold oTokens to the vault
        if (unsold > 0) {
            IERC20(oToken).safeTransfer(vault, unsold);
        }

        emit AuctionSettled(sold, premium, unsold);
    }
}
