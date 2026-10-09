// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ProtocolAccess
/// @notice Shared roles: DEFAULT_ADMIN_ROLE is held by the 48h Timelock after deployment; GUARDIAN_ROLE is a
///         fast-acting emergency key that can pause/unpause but cannot change parameters or move funds.
abstract contract ProtocolAccess is AccessControl, Pausable {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    error ZeroAddress();
    error InvalidParam();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }
}
