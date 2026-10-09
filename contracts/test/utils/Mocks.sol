// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Test-only ERC20 (also used as the mock $OVND project token). Never deployed to a live network.
contract MockERC20 is ERC20 {
    uint8 internal immutable _dec;
    mapping(address => bool) public blocked;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Simulates issuer-side transfer restrictions (blocklists / allowlists on tokenized stocks).
    function setBlocked(address who, bool b) external {
        blocked[who] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[from] && !blocked[to], "blocked");
        super._update(from, to, value);
    }
}

contract MockAggregator is IAggregatorV3 {
    uint8 public override decimals;
    string public override description = "mock";
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;
    uint256 public startedAt;

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
        startedAt = block.timestamp;
    }

    function set(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
        roundId += 1;
        answeredInRound = roundId;
    }

    function setRaw(int256 a, uint256 ts, uint80 rid, uint80 answered) external {
        answer = a;
        updatedAt = ts;
        roundId = rid;
        answeredInRound = answered;
    }

    function setStartedAt(uint256 s) external {
        startedAt = s;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
