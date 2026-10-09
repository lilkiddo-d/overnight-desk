// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolAccess} from "../access/ProtocolAccess.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {IMarketClock} from "../interfaces/IMarketClock.sol";

/// @title OracleAdapter
/// @notice Routes each collateral asset to a primary (and optional secondary) AggregatorV3-compatible feed and
///         enforces: positive answer, completed round, staleness (tighter while the equity market is open),
///         primary/secondary deviation, and an optional L2 sequencer-uptime check. The whole adapter is
///         swappable by the Timelock in every consumer, and every feed is swappable per asset.
contract OracleAdapter is ProtocolAccess, IOracleAdapter {
    struct FeedConfig {
        address primary;
        address secondary; // optional cross-check
        uint32 maxStaleness; // seconds, while the equity market is open
        uint32 maxStalenessClosed; // seconds, while the equity market is closed (weekends / overnight)
        uint16 maxDeviationBps; // max |primary - secondary| / secondary
    }

    IMarketClock public clock;
    IAggregatorV3 public sequencerUptimeFeed;
    uint32 public sequencerGracePeriod = 1 hours;
    mapping(address => FeedConfig) internal _feeds;

    event FeedSet(address indexed asset, FeedConfig config);
    event ClockSet(address clock);
    event SequencerFeedSet(address feed, uint32 gracePeriod);

    error NoFeed(address asset);
    error InvalidAnswer(address feed);
    error StalePrice(address feed, uint256 updatedAt);
    error Deviation(uint256 primary, uint256 secondary);
    error SequencerDown();

    constructor(address admin, IMarketClock clock_) ProtocolAccess(admin) {
        clock = clock_;
    }

    function setFeed(address asset, FeedConfig calldata cfg) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0) || cfg.primary == address(0)) revert ZeroAddress();
        if (cfg.maxStaleness == 0 || cfg.maxStalenessClosed < cfg.maxStaleness || cfg.maxStalenessClosed > 4 days) {
            revert InvalidParam();
        }
        if (cfg.secondary != address(0) && (cfg.maxDeviationBps == 0 || cfg.maxDeviationBps > 2_000)) {
            revert InvalidParam();
        }
        _feeds[asset] = cfg;
        emit FeedSet(asset, cfg);
    }

    function setClock(IMarketClock clock_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        clock = clock_;
        emit ClockSet(address(clock_));
    }

    function setSequencerUptimeFeed(IAggregatorV3 feed, uint32 gracePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        sequencerUptimeFeed = feed;
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedSet(address(feed), gracePeriod);
    }

    function feedOf(address asset) external view returns (FeedConfig memory) {
        return _feeds[asset];
    }

    function getPrice(address asset) external view override returns (uint256 priceE18, uint256 updatedAt) {
        FeedConfig memory cfg = _feeds[asset];
        if (cfg.primary == address(0)) revert NoFeed(asset);
        _checkSequencer();
        bool open = address(clock) == address(0) || clock.isEquityMarketOpen();
        uint256 maxAge = open ? cfg.maxStaleness : cfg.maxStalenessClosed;
        (priceE18, updatedAt) = _read(cfg.primary, maxAge);
        if (cfg.secondary != address(0)) {
            (uint256 s,) = _read(cfg.secondary, maxAge);
            uint256 diff = priceE18 > s ? priceE18 - s : s - priceE18;
            if (diff * 10_000 > s * cfg.maxDeviationBps) revert Deviation(priceE18, s);
        }
    }

    // unused tuple fields of latestRoundData are intentionally ignored
    // slither-disable-start unused-return
    function _read(address feed, uint256 maxAge) internal view returns (uint256 priceE18, uint256 updatedAt) {
        (uint80 roundId, int256 answer,, uint256 ts, uint80 answeredInRound) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0 || answeredInRound < roundId) revert InvalidAnswer(feed);
        if (ts == 0 || ts > block.timestamp || block.timestamp - ts > maxAge) revert StalePrice(feed, ts);
        uint8 dec = IAggregatorV3(feed).decimals();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 a = uint256(answer);
        priceE18 = dec <= 18 ? a * 10 ** (18 - dec) : a / 10 ** (dec - 18);
        if (priceE18 == 0) revert InvalidAnswer(feed);
        updatedAt = ts;
    }

    function _checkSequencer() internal view {
        if (address(sequencerUptimeFeed) == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
        // Chainlink convention: 0 = up, 1 = down
        if (answer != 0) revert SequencerDown();
        if (block.timestamp - startedAt <= sequencerGracePeriod) revert SequencerDown();
    }
    // slither-disable-end unused-return
}
