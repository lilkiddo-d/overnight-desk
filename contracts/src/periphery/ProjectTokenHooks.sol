// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolAccess} from "../access/ProtocolAccess.sol";
import {IProjectTokenHooks} from "../interfaces/IProjectTokenHooks.sol";

/// @title ProjectTokenHooks
/// @notice All $OVND features live here and stay dormant until the admin (Timelock) calls
///         `setProjectToken(address)` exactly once. This contract never mints or deploys a token.
///         - Staking: stake $OVND, earn a share of auction fees in stablecoin (accumulator, pull-based).
///         - Fee tier: stakers holding >= `tierThreshold` for >= `minStakeAge` get `discountBps` off auction fees.
///         - Unstaking has a cooldown so fees cannot be captured by flash-staking around a distribution.
contract ProjectTokenHooks is ProtocolAccess, ReentrancyGuard, IProjectTokenHooks {
    using SafeERC20 for IERC20;

    bytes32 public constant FEE_COLLECTOR_ROLE = keccak256("FEE_COLLECTOR_ROLE");
    uint256 internal constant ACC = 1e36;

    IERC20 public immutable stable;
    IERC20 public projectToken;

    uint256 public tierThreshold;
    uint16 public discountBps;
    uint32 public minStakeAge = 3 days;
    uint32 public unstakeCooldown = 7 days;

    uint256 public override totalStaked;
    uint256 public accRewardPerShare;
    uint256 public undistributed; // rewards received while nobody was staked (rolled into the next notify)

    struct StakerInfo {
        uint256 staked;
        uint256 rewardDebt;
        uint256 pendingRewards;
        uint64 stakedSince;
        uint256 unstakingAmount;
        uint64 unstakeReadyAt;
    }

    mapping(address => StakerInfo) public stakers;

    event ProjectTokenSet(address indexed token);
    event TierSet(uint256 threshold, uint16 discountBps, uint32 minStakeAge);
    event CooldownSet(uint32 cooldown);
    event Staked(address indexed user, uint256 amount);
    event UnstakeRequested(address indexed user, uint256 amount, uint64 readyAt);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardNotified(uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);

    error TokenAlreadySet();
    error TokenNotSet();
    error NotAContract();
    error ZeroAmount();
    error CooldownActive();
    error Insufficient();

    constructor(address admin, IERC20 stable_) ProtocolAccess(admin) {
        if (address(stable_) == address(0)) revert ZeroAddress();
        stable = stable_;
    }

    /// @notice One-shot wiring of the externally launched project token. Callable only by the admin (Timelock).
    function setProjectToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(projectToken) != address(0)) revert TokenAlreadySet();
        if (token == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert NotAContract();
        projectToken = IERC20(token);
        emit ProjectTokenSet(token);
    }

    function setTier(uint256 threshold, uint16 discountBps_, uint32 minStakeAge_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (discountBps_ > 5_000 || minStakeAge_ > 30 days) revert InvalidParam();
        tierThreshold = threshold;
        discountBps = discountBps_;
        minStakeAge = minStakeAge_;
        emit TierSet(threshold, discountBps_, minStakeAge_);
    }

    function setUnstakeCooldown(uint32 cooldown) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cooldown > 30 days) revert InvalidParam();
        unstakeCooldown = cooldown;
        emit CooldownSet(cooldown);
    }

    // ------------------------------------------------------------------ views

    function isActive() public view override returns (bool) {
        return address(projectToken) != address(0);
    }

    function feeDiscountBps(address account) external view override returns (uint256) {
        if (!isActive() || tierThreshold == 0) return 0;
        StakerInfo storage s = stakers[account];
        if (s.staked < tierThreshold) return 0;
        if (block.timestamp < uint256(s.stakedSince) + minStakeAge) return 0;
        return discountBps;
    }

    function pendingRewards(address account) public view returns (uint256) {
        StakerInfo storage s = stakers[account];
        return s.pendingRewards + (s.staked * accRewardPerShare) / ACC - s.rewardDebt;
    }

    // ------------------------------------------------------------------ staking

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (!isActive()) revert TokenNotSet();
        if (amount == 0) revert ZeroAmount();
        _checkpoint(msg.sender);
        StakerInfo storage s = stakers[msg.sender];
        s.staked += amount;
        s.stakedSince = uint64(block.timestamp);
        s.rewardDebt = (s.staked * accRewardPerShare) / ACC;
        totalStaked += amount;
        projectToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function requestUnstake(uint256 amount) external nonReentrant {
        if (!isActive()) revert TokenNotSet();
        StakerInfo storage s = stakers[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (amount > s.staked) revert Insufficient();
        _checkpoint(msg.sender);
        s.staked -= amount;
        s.rewardDebt = (s.staked * accRewardPerShare) / ACC;
        totalStaked -= amount;
        s.unstakingAmount += amount;
        s.unstakeReadyAt = uint64(block.timestamp + unstakeCooldown);
        emit UnstakeRequested(msg.sender, amount, s.unstakeReadyAt);
    }

    function withdraw() external nonReentrant {
        StakerInfo storage s = stakers[msg.sender];
        uint256 amount = s.unstakingAmount;
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < s.unstakeReadyAt) revert CooldownActive();
        s.unstakingAmount = 0;
        projectToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function claimRewards() external nonReentrant returns (uint256 amount) {
        _checkpoint(msg.sender);
        StakerInfo storage s = stakers[msg.sender];
        amount = s.pendingRewards;
        if (amount == 0) revert ZeroAmount();
        s.pendingRewards = 0;
        stable.safeTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, amount);
    }

    /// @inheritdoc IProjectTokenHooks
    function notifyReward(uint256 amount) external override onlyRole(FEE_COLLECTOR_ROLE) {
        uint256 total = amount + undistributed;
        if (totalStaked == 0) {
            undistributed = total;
        } else {
            undistributed = 0;
            accRewardPerShare += (total * ACC) / totalStaked;
        }
        emit RewardNotified(amount);
    }

    function _checkpoint(address account) internal {
        StakerInfo storage s = stakers[account];
        uint256 accrued = (s.staked * accRewardPerShare) / ACC;
        if (accrued > s.rewardDebt) s.pendingRewards += accrued - s.rewardDebt;
        s.rewardDebt = accrued;
    }
}
