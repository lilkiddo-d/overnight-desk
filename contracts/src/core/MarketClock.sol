// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolAccess} from "../access/ProtocolAccess.sol";
import {IMarketClock} from "../interfaces/IMarketClock.sol";

/// @title MarketClock
/// @notice Deterministic auction calendar. Epoch `e` starts at `genesis + e * interval` and runs:
///         [start, commitEnd)            commit phase   (sealed orders accepted)
///         [commitEnd, revealEnd)        reveal phase   (orders opened)
///         [revealEnd, expiry)           clearing phase (anyone may clear the books)
///         [expiry, ...)                 expired        (uncleared orders are refundable in full)
///         The cadence is immutable so epoch numbering can never be re-mapped under live orders.
///         It also exposes an (optional, admin-configured) equity-market-hours schedule used to treat
///         weekend/overnight price gaps conservatively.
contract MarketClock is ProtocolAccess, IMarketClock {
    uint64 public immutable genesis;
    uint64 public immutable override interval;
    uint64 public immutable commitWindow;
    uint64 public immutable revealWindow;
    uint64 public immutable clearWindow;

    /// @notice Regular trading session in seconds after 00:00 UTC, and a Mon..Sun bitmask (bit 0 = Monday).
    uint32 public sessionOpen = 13 hours + 30 minutes; // 09:30 New York (EDT)
    uint32 public sessionClose = 20 hours; // 16:00 New York (EDT)
    uint8 public tradingDays = 0x1F; // Mon-Fri
    bool public marketHoursEnforced;

    event MarketHoursUpdated(uint32 open, uint32 close, uint8 daysMask, bool enforced);

    error BeforeGenesis();

    constructor(address admin, uint64 genesis_, uint64 interval_, uint64 commit_, uint64 reveal_, uint64 clear_)
        ProtocolAccess(admin)
    {
        if (interval_ == 0 || commit_ == 0 || reveal_ == 0 || clear_ == 0) revert InvalidParam();
        if (commit_ + reveal_ >= interval_) revert InvalidParam();
        genesis = genesis_;
        interval = interval_;
        commitWindow = commit_;
        revealWindow = reveal_;
        clearWindow = clear_;
    }

    function setMarketHours(uint32 open_, uint32 close_, uint8 daysMask, bool enforced)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (open_ >= close_ || close_ > 1 days || daysMask > 0x7F) revert InvalidParam();
        sessionOpen = open_;
        sessionClose = close_;
        tradingDays = daysMask;
        marketHoursEnforced = enforced;
        emit MarketHoursUpdated(open_, close_, daysMask, enforced);
    }

    function currentEpoch() public view override returns (uint64) {
        if (block.timestamp < genesis) revert BeforeGenesis();
        return uint64((block.timestamp - genesis) / interval);
    }

    function epochStart(uint64 epoch) public view override returns (uint64) {
        return genesis + epoch * interval;
    }

    function commitEnd(uint64 epoch) public view override returns (uint64) {
        return epochStart(epoch) + commitWindow;
    }

    function revealEnd(uint64 epoch) public view override returns (uint64) {
        return commitEnd(epoch) + revealWindow;
    }

    function expiry(uint64 epoch) public view override returns (uint64) {
        return revealEnd(epoch) + clearWindow;
    }

    function phase(uint64 epoch) external view override returns (Phase) {
        uint256 t = block.timestamp;
        if (t < epochStart(epoch)) return Phase.Pending;
        if (t < commitEnd(epoch)) return Phase.Commit;
        if (t < revealEnd(epoch)) return Phase.Reveal;
        if (t < expiry(epoch)) return Phase.Clearing;
        return Phase.Expired;
    }

    /// @notice True when the reference equity market is in its regular session (or when hours are not enforced).
    /// @dev Holidays are not modelled on-chain; the guardian can pause during exceptional closures.
    // calendar arithmetic on block.timestamp (day of week / second of day), not randomness
    // slither-disable-start weak-prng,incorrect-equality
    function isEquityMarketOpen() external view override returns (bool) {
        if (!marketHoursEnforced) return true;
        uint256 t = block.timestamp;
        // 1970-01-01 was a Thursday -> Monday-based day index = (days + 3) % 7
        uint256 dayIdx = ((t / 1 days) + 3) % 7;
        if ((tradingDays >> dayIdx) & 1 == 0) return false;
        uint256 secOfDay = t % 1 days;
        return secOfDay >= sessionOpen && secOfDay < sessionClose;
        // slither-disable-end weak-prng,incorrect-equality
    }
}
