// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IDutchAuction
 * @notice Interface for the continuous Dutch auction mechanism distributing oTokens in DeltaForge
 */
interface IDutchAuction {
    struct AuctionParams {
        address vault;
        address oToken;
        address paymentToken;
        uint256 totalOptions;
        uint256 startPrice;
        uint256 reservePrice;
        uint256 startTime;
        uint256 duration;
    }

    event BidPlaced(address indexed bidder, uint256 optionAmount, uint256 clearingPrice, uint256 totalCost);

    event AuctionSettled(uint256 totalSold, uint256 totalPremium, uint256 unsoldReturned);

    error AuctionNotStarted();
    error AuctionAlreadyConcluded();
    error InsufficientAuctionSupply();
    error SlippageExceeded();
    error ZeroAmount();
    error Unauthorized();

    function currentPrice() external view returns (uint256);
    function isConcluded() external view returns (bool);
    function totalSold() external view returns (uint256);
    function totalPremium() external view returns (uint256);
    function buy(uint256 optionAmount, uint256 maxPricePerOption) external returns (uint256 premiumPaid);
    function concludeAuction() external returns (uint256 sold, uint256 premium, uint256 unsold);
}
