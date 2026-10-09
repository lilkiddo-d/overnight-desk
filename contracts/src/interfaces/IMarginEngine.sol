// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMarginEngine {
    function collateralValue(address token, uint256 amount) external view returns (uint256);
    function meetsInitialMargin(address token, uint256 collateralAmount, uint256 debt) external view returns (bool);
    function isHealthy(uint256 repoId) external view returns (bool);
}
