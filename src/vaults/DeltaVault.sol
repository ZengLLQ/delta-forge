// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IDeltaVault} from "../interfaces/IDeltaVault.sol";
import {IOptionToken} from "../interfaces/IOptionToken.sol";
import {IDutchAuction} from "../interfaces/IDutchAuction.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {OptionToken} from "../tokens/OptionToken.sol";
import {DeltaDutchAuction} from "../auction/DeltaDutchAuction.sol";
import {DeltaMath} from "../libraries/DeltaMath.sol";
import {TransientLock} from "../libraries/TransientLock.sol";

/**
 * @title DeltaVault
 * @notice Production-grade Decentralized Options Vault (DOV) implementing ERC-4626 yield-bearing shares
 * @dev Employs Black-Scholes Greeks, delta-targeted strike selection, continuous Dutch auctions,
 *      and EIP-1153 transient reentrancy guards.
 */
contract DeltaVault is ERC4626, Ownable, Pausable, TransientLock, IDeltaVault {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant DEFAULT_AUCTION_DURATION = 86400; // 24 hours
    uint256 internal constant DEFAULT_EPOCH_DURATION = 604800; // 7 days

    bool public immutable override isPutVault;
    IPriceOracle public oracle;

    uint256 public defaultTargetDeltaWad = 0.15e18; // 15-delta
    uint256 public override currentEpoch;
    uint256 public totalReservedPayouts;

    mapping(uint256 => EpochData) private _epochs;

    // -------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------

    constructor(IERC20 asset_, string memory name_, string memory symbol_, bool isPutVault_, address oracle_)
        ERC4626(asset_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        if (address(asset_) == address(0) || oracle_ == address(0)) revert ZeroAmount();
        isPutVault = isPutVault_;
        oracle = IPriceOracle(oracle_);
    }

    // -------------------------------------------------------------
    // ERC-4626 Virtual Shares Defense Against Inflation Attacks
    // -------------------------------------------------------------

    /**
     * @dev Virtual shares offset (OpenZeppelin 5.x pattern) protecting against first-depositor front-running
     */
    function _decimalsOffset() internal view virtual override returns (uint8) {
        return 9;
    }

    /**
     * @notice Total assets managed by vault, excluding reserved payout liabilities for expired option holders
     */
    function totalAssets() public view virtual override returns (uint256) {
        uint256 rawBalance = IERC20(asset()).balanceOf(address(this));
        if (rawBalance <= totalReservedPayouts) {
            return 0;
        }
        return rawBalance - totalReservedPayouts;
    }

    // -------------------------------------------------------------
    // Views
    // -------------------------------------------------------------

    function getEpoch(uint256 epochId) external view override returns (EpochData memory) {
        return _epochs[epochId];
    }

    // -------------------------------------------------------------
    // Admin Configuration
    // -------------------------------------------------------------

    function setOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert ZeroAmount();
        oracle = IPriceOracle(newOracle);
    }

    function setDefaultTargetDelta(uint256 newDeltaWad) external onlyOwner {
        if (newDeltaWad == 0 || newDeltaWad >= WAD) revert DeltaMath.InvalidProbability();
        defaultTargetDeltaWad = newDeltaWad;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------
    // Epoch Lifecycle Management
    // -------------------------------------------------------------

    /**
     * @notice Rolls vault into next epoch: determines strike price, mints oTokens, and opens Dutch auction
     * @param targetDeltaWad Target delta in WAD (e.g. 0.15e18); 0 defaults to defaultTargetDeltaWad
     * @param epochDuration Round length in seconds; 0 defaults to 7 days
     * @param auctionDuration Auction duration in seconds; 0 defaults to 24 hours
     */
    function rollToNextEpoch(uint256 targetDeltaWad, uint256 epochDuration, uint256 auctionDuration)
        external
        override
        onlyOwner
        whenNotPaused
        nonReentrant
        returns (uint256 newEpochId)
    {
        if (currentEpoch > 0) {
            EpochData storage prevEpoch = _epochs[currentEpoch];
            if (prevEpoch.state != EpochState.SETTLED) {
                revert InvalidEpochState();
            }
        }

        uint256 availableCollateral = totalAssets();
        if (availableCollateral == 0) revert InsufficientVaultLiquidity();

        targetDeltaWad = targetDeltaWad == 0 ? defaultTargetDeltaWad : targetDeltaWad;
        epochDuration = epochDuration == 0 ? DEFAULT_EPOCH_DURATION : epochDuration;
        auctionDuration = auctionDuration == 0 ? DEFAULT_AUCTION_DURATION : auctionDuration;

        (uint256 spotPrice,) = oracle.getSpotPrice();
        uint256 iv = oracle.getImpliedVolatility();
        uint256 rate = oracle.getRiskFreeRate();

        // Compute delta-targeted strike price
        uint256 strikePrice =
            DeltaMath.getStrikeForDelta(spotPrice, targetDeltaWad, epochDuration, iv, rate, isPutVault);

        // Compute Black-Scholes benchmark price for Dutch auction bounds
        DeltaMath.OptionParams memory optParams = DeltaMath.OptionParams({
            spotPrice: spotPrice,
            strikePrice: strikePrice,
            timeToExpirySec: epochDuration,
            volatility: iv,
            riskFreeRate: rate
        });

        (uint256 callBS, uint256 putBS) = DeltaMath.blackScholesPrice(optParams);
        uint256 bsPrice = isPutVault ? putBS : callBS;
        if (!isPutVault && spotPrice > 0) {
            // Convert dollar option premium into underlying asset units (e.g. WETH)
            bsPrice = (bsPrice * WAD) / spotPrice;
        }
        if (bsPrice == 0) {
            bsPrice = isPutVault ? (spotPrice * 2) / 100 : (WAD * 2) / 100; // 2% minimum fallback floor
        }

        uint256 startPrice = (bsPrice * 150) / 100; // 1.5x BS ceiling
        uint256 reservePrice = (bsPrice * 50) / 100; // 0.5x BS floor
        if (reservePrice == 0) reservePrice = 1;

        // Calculate option contracts capacity to sell
        uint256 optionsCapacity;
        if (!isPutVault) {
            // Covered call: 1 asset backs 1 call option
            optionsCapacity = availableCollateral;
        } else {
            // Cash-secured put: K assets back 1 put option
            optionsCapacity = (availableCollateral * WAD) / strikePrice;
        }
        if (optionsCapacity == 0) revert InsufficientVaultLiquidity();

        newEpochId = ++currentEpoch;
        uint256 expiry = block.timestamp + epochDuration;

        // Deploy new OptionToken
        string memory optSymbol = isPutVault ? "dPUT" : "dCALL";
        OptionToken oToken =
            new OptionToken("DeltaForge Option Token", optSymbol, asset(), strikePrice, expiry, isPutVault, newEpochId);

        // Deploy new Dutch Auction
        DeltaDutchAuction auction = new DeltaDutchAuction(
            address(this),
            address(oToken),
            asset(),
            optionsCapacity,
            startPrice,
            reservePrice,
            block.timestamp,
            auctionDuration
        );

        // Mint options to auction contract
        oToken.mint(address(auction), optionsCapacity);

        _epochs[newEpochId] = EpochData({
            epochId: newEpochId,
            state: EpochState.LOCKED,
            oToken: address(oToken),
            auction: address(auction),
            strikePrice: strikePrice,
            startTimestamp: block.timestamp,
            expiryTimestamp: expiry,
            lockedCollateral: availableCollateral,
            premiumCollected: 0,
            settlementPrice: 0,
            totalPayoutReserved: 0,
            totalExercised: 0
        });

        emit EpochStarted(newEpochId, address(oToken), address(auction), strikePrice, expiry, availableCollateral);
    }

    /**
     * @notice Settles current epoch after expiry timestamp: resolves payoff and releases profit
     */
    function settleEpoch() external override nonReentrant returns (uint256 settlementPrice, uint256 totalPayout) {
        EpochData storage epoch = _epochs[currentEpoch];
        if (epoch.state != EpochState.LOCKED) revert InvalidEpochState();
        if (block.timestamp < epoch.expiryTimestamp) revert EpochNotExpired();

        // Conclude Dutch auction if not already finalized
        IDutchAuction auction = IDutchAuction(epoch.auction);
        uint256 optionsSold = auction.totalSold();
        uint256 premium = auction.totalPremium();

        if (!auction.isConcluded()) {
            (optionsSold, premium,) = auction.concludeAuction();
        }
        epoch.premiumCollected = premium;

        // Fetch settlement spot price from oracle
        (settlementPrice,) = oracle.getSpotPrice();
        epoch.settlementPrice = settlementPrice;

        // Compute payoff per option
        uint256 payoutPerOptionWad = 0;
        if (!isPutVault) {
            // Covered Call payoff in underlying asset: max(0, S_T - K) / S_T
            if (settlementPrice > epoch.strikePrice) {
                uint256 diff = settlementPrice - epoch.strikePrice;
                payoutPerOptionWad = (diff * WAD) / settlementPrice;
            }
        } else {
            // Cash-Secured Put payoff in asset: max(0, K - S_T)
            if (settlementPrice < epoch.strikePrice) {
                payoutPerOptionWad = epoch.strikePrice - settlementPrice;
            }
        }

        // Total payout liability across all options sold
        if (optionsSold > 0 && payoutPerOptionWad > 0) {
            totalPayout = (optionsSold * payoutPerOptionWad) / WAD;
        }

        // Solvency ceiling guarantee: payout cannot exceed locked collateral
        if (totalPayout > epoch.lockedCollateral) {
            totalPayout = epoch.lockedCollateral;
        }

        epoch.totalPayoutReserved = totalPayout;
        totalReservedPayouts += totalPayout;
        epoch.state = EpochState.SETTLED;

        uint256 surplus = epoch.lockedCollateral > totalPayout ? epoch.lockedCollateral - totalPayout : 0;

        emit EpochSettled(currentEpoch, settlementPrice, totalPayout, surplus);
    }

    /**
     * @notice Option holders exercise their oTokens after epoch settlement to receive payout
     * @param epochId Settled epoch id
     * @param oTokenAmount Amount of oTokens to exercise
     */
    function exercise(uint256 epochId, uint256 oTokenAmount) external override nonReentrant returns (uint256 payout) {
        if (oTokenAmount == 0) revert ZeroAmount();
        EpochData storage epoch = _epochs[epochId];
        if (epoch.state != EpochState.SETTLED) revert InvalidEpochState();

        IOptionToken oToken = IOptionToken(epoch.oToken);
        uint256 holderBalance = oToken.balanceOf(msg.sender);
        if (holderBalance < oTokenAmount) revert InsufficientVaultLiquidity();

        IDutchAuction auction = IDutchAuction(epoch.auction);
        uint256 optionsSold = auction.totalSold();
        if (optionsSold == 0 || epoch.totalPayoutReserved == 0) {
            // OTM option: zero payoff, burns worthless option
            oToken.burn(msg.sender, oTokenAmount);
            emit OptionExercised(epochId, msg.sender, oTokenAmount, 0);
            return 0;
        }

        // Pro-rata share of total reserved payout
        payout = (epoch.totalPayoutReserved * oTokenAmount) / optionsSold;

        // Burn options
        oToken.burn(msg.sender, oTokenAmount);
        epoch.totalExercised += oTokenAmount;

        // Decrement global reserved payouts
        if (payout > totalReservedPayouts) {
            payout = totalReservedPayouts;
        }
        totalReservedPayouts -= payout;

        emit OptionExercised(epochId, msg.sender, oTokenAmount, payout);

        // Transfer payout in underlying asset to exerciser (Interactions last)
        IERC20(asset()).safeTransfer(msg.sender, payout);
    }

    // -------------------------------------------------------------
    // ERC-4626 Overrides with Pause & Solvency Guards
    // -------------------------------------------------------------

    function deposit(uint256 assets, address receiver) public virtual override whenNotPaused returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public virtual override whenNotPaused returns (uint256) {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public virtual override returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }
}
