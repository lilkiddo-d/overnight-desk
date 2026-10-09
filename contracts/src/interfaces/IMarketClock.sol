// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMarketClock {
    enum Phase {
        Pending,
        Commit,
        Reveal,
        Clearing,
        Expired
    }

    function interval() external view returns (uint64);
    function currentEpoch() external view returns (uint64);
    function epochStart(uint64 epoch) external view returns (uint64);
    function commitEnd(uint64 epoch) external view returns (uint64);
    function revealEnd(uint64 epoch) external view returns (uint64);
    function expiry(uint64 epoch) external view returns (uint64);
    function phase(uint64 epoch) external view returns (Phase);
    function isEquityMarketOpen() external view returns (bool);
}
