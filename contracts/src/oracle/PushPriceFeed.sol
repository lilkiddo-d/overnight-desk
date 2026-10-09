// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @title PushPriceFeed
/// @notice AggregatorV3-compatible feed written by an authorised updater (e.g. a relayer of an off-chain oracle
///         network's signed reports). It is the documented fallback for assets without a native on-chain feed and
///         is intended to be used as the SECONDARY cross-check (or as primary only with a tight deviation guard).
///         Each push is bounded by `maxJumpBps` unless the admin (Timelock) forces it.
contract PushPriceFeed is AccessControl, IAggregatorV3 {
    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");

    uint8 public immutable override decimals;
    string public override description;
    uint16 public maxJumpBps;

    uint80 internal _roundId;
    int256 internal _answer;
    uint256 internal _updatedAt;

    event PricePushed(uint80 indexed roundId, int256 answer, uint256 observedAt);
    event MaxJumpSet(uint16 bps);

    error BadAnswer();
    error StaleObservation();
    error JumpTooLarge();

    constructor(address admin, uint8 decimals_, string memory description_, uint16 maxJumpBps_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        decimals = decimals_;
        description = description_;
        maxJumpBps = maxJumpBps_;
    }

    function setMaxJump(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxJumpBps = bps;
        emit MaxJumpSet(bps);
    }

    function push(int256 answer, uint256 observedAt) external onlyRole(UPDATER_ROLE) {
        _push(answer, observedAt, false);
    }

    /// @notice Admin override for genuine large moves (e.g. corporate actions); goes through the Timelock.
    function forcePush(int256 answer, uint256 observedAt) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _push(answer, observedAt, true);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }

    function _push(int256 answer, uint256 observedAt, bool force) internal {
        if (answer <= 0) revert BadAnswer();
        if (observedAt <= _updatedAt || observedAt > block.timestamp) revert StaleObservation();
        if (!force && _answer > 0 && maxJumpBps > 0) {
            int256 diff = answer > _answer ? answer - _answer : _answer - answer;
            if (diff * 10_000 > _answer * int256(uint256(maxJumpBps))) revert JumpTooLarge();
        }
        _roundId += 1;
        _answer = answer;
        _updatedAt = observedAt;
        emit PricePushed(_roundId, answer, observedAt);
    }
}
