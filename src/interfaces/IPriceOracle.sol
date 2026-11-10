// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IPriceOracle
 * @notice Standard interface for spot price feeds and volatility estimation in DeltaForge
 */
interface IPriceOracle {
    error StalePriceFeed(uint256 updatedAt, uint256 maxAge);
    error InvalidPriceValue(int256 price);

    function getSpotPrice() external view returns (uint256 priceWad, uint256 updatedAt);
    function getImpliedVolatility() external view returns (uint256 ivWad);
    function getRiskFreeRate() external view returns (uint256 rateWad);
    function maxStaleness() external view returns (uint256);
}
