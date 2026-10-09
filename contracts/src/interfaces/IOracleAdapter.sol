// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Price source used by the protocol. Implementations are swappable behind the Timelock.
interface IOracleAdapter {
    /// @return priceE18 USD price of ONE whole token with 18 decimals (the stablecoin is treated as $1).
    /// @return updatedAt timestamp of the underlying observation.
    /// @dev MUST revert if the price is stale, non-positive, or fails deviation checks.
    function getPrice(address asset) external view returns (uint256 priceE18, uint256 updatedAt);
}
