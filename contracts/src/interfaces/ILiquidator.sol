// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILiquidator {
    function start(uint256 repoId) external returns (uint256 auctionId);
}
