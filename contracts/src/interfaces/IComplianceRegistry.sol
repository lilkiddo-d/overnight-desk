// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IComplianceRegistry {
    /// @notice Returns true if `account` may perform gated actions. Always true while the registry is disabled.
    function isAllowed(address account) external view returns (bool);
}
