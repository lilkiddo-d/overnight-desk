// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title OvernightTimelock
/// @notice Holds DEFAULT_ADMIN_ROLE on every protocol contract. Enforces a minimum 48h delay on all
///         parameter changes, role grants, oracle swaps and `setProjectToken`. The effective delay can never be
///         lowered below 48h, even by a self-scheduled `updateDelay`.
contract OvernightTimelock is TimelockController {
    uint256 public constant MIN_DELAY_FLOOR = 48 hours;

    error DelayTooShort();

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController(minDelay, proposers, executors, address(0))
    {
        if (minDelay < MIN_DELAY_FLOOR) revert DelayTooShort();
    }

    function getMinDelay() public view override returns (uint256) {
        uint256 d = super.getMinDelay();
        return d < MIN_DELAY_FLOOR ? MIN_DELAY_FLOOR : d;
    }
}
