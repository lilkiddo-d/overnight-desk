// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IProjectTokenHooks {
    function isActive() external view returns (bool);
    function totalStaked() external view returns (uint256);
    /// @notice Discount (bps) applied to the auction fee for `account`. 0 while the token is not set.
    function feeDiscountBps(address account) external view returns (uint256);
    /// @notice Called by the FeeCollector after transferring `amount` stablecoin to this contract.
    function notifyReward(uint256 amount) external;
}
