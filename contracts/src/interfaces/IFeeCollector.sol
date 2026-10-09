// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IFeeCollector {
    function distribute() external returns (uint256 toStakers, uint256 toTreasury);
}
