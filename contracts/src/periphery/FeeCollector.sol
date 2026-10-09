// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolAccess} from "../access/ProtocolAccess.sol";
import {IFeeCollector} from "../interfaces/IFeeCollector.sol";
import {IProjectTokenHooks} from "../interfaces/IProjectTokenHooks.sol";

/// @title FeeCollector
/// @notice Receives protocol fees (auction fees, liquidation penalties, note-market fees, no-reveal penalties).
///         `distribute()` (permissionless) sends `stakerShareBps` of the stablecoin balance to ProjectTokenHooks
///         when the project token is live and has stakers, and the rest to the treasury. Before the token is set,
///         100% goes to the treasury. Non-stablecoin balances (e.g. collateral no-reveal penalties) can be swept
///         to the treasury by the admin.
contract FeeCollector is ProtocolAccess, ReentrancyGuard, IFeeCollector {
    using SafeERC20 for IERC20;

    IERC20 public immutable stable;
    IProjectTokenHooks public hooks;
    address public treasury;
    uint16 public stakerShareBps = 5_000;

    event HooksSet(address hooks);
    event TreasurySet(address treasury);
    event StakerShareSet(uint16 bps);
    event Distributed(uint256 toStakers, uint256 toTreasury);
    event Swept(address indexed token, uint256 amount);

    constructor(address admin, IERC20 stable_, address treasury_) ProtocolAccess(admin) {
        if (address(stable_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        stable = stable_;
        treasury = treasury_;
    }

    function setHooks(IProjectTokenHooks hooks_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hooks = hooks_;
        emit HooksSet(address(hooks_));
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setStakerShare(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 10_000) revert InvalidParam();
        stakerShareBps = bps;
        emit StakerShareSet(bps);
    }

    // bal == 0 is an early-exit for an empty balance; donations cannot cause harm
    // slither-disable-start incorrect-equality
    function distribute() external override nonReentrant whenNotPaused returns (uint256 toStakers, uint256 toTreasury) {
        uint256 bal = stable.balanceOf(address(this));
        if (bal == 0) return (0, 0);
        IProjectTokenHooks h = hooks;
        if (address(h) != address(0) && h.isActive() && h.totalStaked() > 0) {
            toStakers = (bal * stakerShareBps) / 10_000;
        }
        toTreasury = bal - toStakers;
        if (toStakers > 0) {
            stable.safeTransfer(address(h), toStakers);
            h.notifyReward(toStakers);
        }
        if (toTreasury > 0) stable.safeTransfer(treasury, toTreasury);
        emit Distributed(toStakers, toTreasury);
    }

    // slither-disable-end incorrect-equality

    /// @notice Sweep a non-stablecoin token (e.g. forfeited collateral) to the treasury.
    function sweep(IERC20 token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(token) == address(stable)) revert InvalidParam();
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(treasury, amount);
        emit Swept(address(token), amount);
    }
}
