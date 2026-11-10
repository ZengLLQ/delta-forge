// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title DeltaOracle
 * @notice Oracle feeding spot prices, implied volatility, and risk-free rates to DeltaForge vaults
 * @dev Supports standalone administration or Chainlink AggregatorV3 price feeds with staleness validation
 */
contract DeltaOracle is IPriceOracle, Ownable {
    uint256 public override maxStaleness;
    uint256 public override getImpliedVolatility;
    uint256 public override getRiskFreeRate;

    uint256 private _manualSpotPrice;
    uint256 private _lastManualUpdate;

    address public chainlinkFeed;

    event SpotPriceUpdated(uint256 newPriceWad, uint256 timestamp);
    event ImpliedVolatilityUpdated(uint256 newIvWad);
    event RiskFreeRateUpdated(uint256 newRateWad);
    event ChainlinkFeedConfigured(address indexed feed);

    constructor(uint256 initialPriceWad, uint256 initialIvWad, uint256 initialRateWad, uint256 maxStaleness_)
        Ownable(msg.sender)
    {
        if (initialPriceWad == 0 || initialIvWad == 0) revert InvalidPriceValue(0);
        _manualSpotPrice = initialPriceWad;
        _lastManualUpdate = block.timestamp;
        getImpliedVolatility = initialIvWad;
        getRiskFreeRate = initialRateWad;
        maxStaleness = maxStaleness_ == 0 ? 3600 : maxStaleness_;
    }

    function setSpotPrice(uint256 newPriceWad) external onlyOwner {
        if (newPriceWad == 0) revert InvalidPriceValue(0);
        _manualSpotPrice = newPriceWad;
        _lastManualUpdate = block.timestamp;
        emit SpotPriceUpdated(newPriceWad, block.timestamp);
    }

    function setImpliedVolatility(uint256 newIvWad) external onlyOwner {
        if (newIvWad == 0) revert InvalidPriceValue(0);
        getImpliedVolatility = newIvWad;
        emit ImpliedVolatilityUpdated(newIvWad);
    }

    function setRiskFreeRate(uint256 newRateWad) external onlyOwner {
        getRiskFreeRate = newRateWad;
        emit RiskFreeRateUpdated(newRateWad);
    }

    function setMaxStaleness(uint256 newMaxAge) external onlyOwner {
        maxStaleness = newMaxAge;
    }

    function setChainlinkFeed(address feed) external onlyOwner {
        if (feed == address(0)) revert InvalidPriceValue(0);
        chainlinkFeed = feed;
        emit ChainlinkFeedConfigured(feed);
    }

    /**
     * @notice Returns current spot price in WAD (18 decimals) and last updated timestamp
     */
    function getSpotPrice() external view override returns (uint256 priceWad, uint256 updatedAt) {
        if (chainlinkFeed != address(0)) {
            try IAggregatorV3(chainlinkFeed).latestRoundData() returns (
                uint80, int256 answer, uint256, uint256 clUpdatedAt, uint80
            ) {
                if (answer <= 0) revert InvalidPriceValue(answer);
                if (clUpdatedAt == 0 || clUpdatedAt > block.timestamp || block.timestamp - clUpdatedAt > maxStaleness) {
                    revert StalePriceFeed(clUpdatedAt, maxStaleness);
                }

                uint8 decimals = IAggregatorV3(chainlinkFeed).decimals();
                if (decimals == 18) {
                    priceWad = uint256(answer);
                } else if (decimals < 18) {
                    priceWad = uint256(answer) * (10 ** (18 - decimals));
                } else {
                    priceWad = uint256(answer) / (10 ** (decimals - 18));
                }
                return (priceWad, clUpdatedAt);
            } catch {
                // Fall back to manual price if Chainlink call fails
            }
        }

        if (block.timestamp - _lastManualUpdate > maxStaleness) {
            revert StalePriceFeed(_lastManualUpdate, maxStaleness);
        }
        return (_manualSpotPrice, _lastManualUpdate);
    }
}
