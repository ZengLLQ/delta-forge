// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IDeltaVault
 * @notice Interface for DeltaForge Decentralized Options Vaults (DOV)
 * @dev Governs epoch lifecycles, options minting, Dutch auction integration, and settlement
 */
interface IDeltaVault {
    enum EpochState {
        PENDING,
        LOCKED,
        SETTLED
    }

    struct EpochData {
        uint256 epochId;
        EpochState state;
        address oToken;
        address auction;
        uint256 strikePrice;
        uint256 startTimestamp;
        uint256 expiryTimestamp;
        uint256 lockedCollateral;
        uint256 premiumCollected;
        uint256 settlementPrice;
        uint256 totalPayoutReserved;
        uint256 totalExercised;
    }

    event EpochStarted(
        uint256 indexed epochId,
        address indexed oToken,
        address indexed auction,
        uint256 strikePrice,
        uint256 expiryTimestamp,
        uint256 lockedCollateral
    );

    event AuctionFinalized(uint256 indexed epochId, uint256 optionsSold, uint256 premiumReceived);

    event EpochSettled(
        uint256 indexed epochId, uint256 settlementPrice, uint256 totalPayoutReserved, uint256 surplusReturned
    );

    event OptionExercised(
        uint256 indexed epochId, address indexed exerciser, uint256 oTokenBurned, uint256 payoutReceived
    );

    error InvalidEpochState();
    error EpochNotExpired();
    error EpochAlreadySettled();
    error AuctionStillActive();
    error ZeroAmount();
    error StaleOraclePrice();
    error InsufficientVaultLiquidity();
    error Unauthorized();
    error SlippageExceeded();

    function currentEpoch() external view returns (uint256);
    function isPutVault() external view returns (bool);
    function getEpoch(uint256 epochId) external view returns (EpochData memory);
    function rollToNextEpoch(uint256 targetDeltaWad, uint256 epochDuration, uint256 auctionDuration)
        external
        returns (uint256);
    function settleEpoch() external returns (uint256 settlementPrice, uint256 totalPayout);
    function exercise(uint256 epochId, uint256 oTokenAmount) external returns (uint256 payout);
}
