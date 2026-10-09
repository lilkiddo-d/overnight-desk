// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";

/// @title ComplianceRegistry
/// @notice Pluggable allowlist hook. OFF by default: `isAllowed` returns true for everyone until the admin
///         (Timelock) enables it. Allowlist maintenance is delegated to COMPLIANCE_ROLE (e.g. a KYC provider).
///         Gated actions: placing auction orders, listing and buying repo notes. Repaying, topping up collateral,
///         redeeming notes and claiming refunds are never gated, so existing positions can always be unwound.
contract ComplianceRegistry is AccessControl, IComplianceRegistry {
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    uint256 public constant MAX_BATCH = 200;

    bool public enabled;
    mapping(address => bool) public allowed;

    event EnabledSet(bool enabled);
    event AllowedSet(address indexed account, bool allowed);

    error BatchTooLarge();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setEnabled(bool enabled_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabled = enabled_;
        emit EnabledSet(enabled_);
    }

    function setAllowed(address[] calldata accounts, bool allowed_) external onlyRole(COMPLIANCE_ROLE) {
        if (accounts.length > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < accounts.length; ++i) {
            allowed[accounts[i]] = allowed_;
            emit AllowedSet(accounts[i], allowed_);
        }
    }

    function isAllowed(address account) external view override returns (bool) {
        return !enabled || allowed[account];
    }
}
