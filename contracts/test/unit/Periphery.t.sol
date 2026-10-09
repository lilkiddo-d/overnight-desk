// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {MockERC20, MockAggregator} from "../utils/Mocks.sol";
import {NoteMarket} from "../../src/periphery/NoteMarket.sol";
import {FeeCollector} from "../../src/periphery/FeeCollector.sol";
import {ProjectTokenHooks} from "../../src/periphery/ProjectTokenHooks.sol";
import {ComplianceRegistry} from "../../src/periphery/ComplianceRegistry.sol";
import {OvernightTimelock} from "../../src/periphery/OvernightTimelock.sol";
import {OracleAdapter} from "../../src/oracle/OracleAdapter.sol";
import {PushPriceFeed} from "../../src/oracle/PushPriceFeed.sol";
import {MarketClock} from "../../src/core/MarketClock.sol";
import {TermRegistry} from "../../src/core/TermRegistry.sol";
import {RepoNote} from "../../src/core/RepoNote.sol";
import {IRepoNote} from "../../src/interfaces/IRepoNote.sol";
import {ITermRegistry} from "../../src/interfaces/ITermRegistry.sol";
import {IMarketClock} from "../../src/interfaces/IMarketClock.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IProjectTokenHooks} from "../../src/interfaces/IProjectTokenHooks.sol";
import {IComplianceRegistry} from "../../src/interfaces/IComplianceRegistry.sol";
import {ProtocolAccess} from "../../src/access/ProtocolAccess.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract NoteMarketTest is BaseTest {
    uint256 internal seriesId;

    function setUp() public override {
        super.setUp();
        (, seriesId,,) = openSimpleRepo(book30, 10_000e6, 100e18, 400, 600);
    }

    function test_listBuyCancel() public {
        vm.prank(alice);
        uint256 id = d.noteMarket.list(seriesId, 5_000e6, 0.99e18);
        assertEq(d.note.balanceOf(address(d.noteMarket), seriesId), 5_000e6);
        (uint256 cost, uint256 fee) = d.noteMarket.quote(id, 1_000e6);
        assertEq(cost, 990e6);
        assertEq(fee, 0.99e6);

        uint256 a0 = usdc.balanceOf(alice);
        uint256 c0 = usdc.balanceOf(carol);
        vm.prank(carol);
        d.noteMarket.buy(id, 1_000e6, 0.99e18, block.timestamp);
        assertEq(d.note.balanceOf(carol, seriesId), 1_000e6);
        assertEq(usdc.balanceOf(alice), a0 + 990e6 - 0.99e6);
        assertEq(c0 - usdc.balanceOf(carol), 990e6);

        vm.prank(alice);
        d.noteMarket.updatePrice(id, 0.995e18);
        vm.prank(carol);
        vm.expectRevert(NoteMarket.PriceAboveMax.selector);
        d.noteMarket.buy(id, 1_000e6, 0.99e18, block.timestamp);
        vm.prank(carol);
        vm.expectRevert(NoteMarket.Expired.selector);
        d.noteMarket.buy(id, 1_000e6, 1e18, block.timestamp - 1);
        vm.prank(carol);
        vm.expectRevert(NoteMarket.ZeroAmount.selector);
        d.noteMarket.buy(id, 5_000e6, 1e18, block.timestamp);

        vm.prank(carol);
        vm.expectRevert(NoteMarket.NotSeller.selector);
        d.noteMarket.cancel(id);
        vm.prank(alice);
        d.noteMarket.cancel(id);
        assertEq(d.note.balanceOf(alice, seriesId), 9_000e6);
        vm.prank(alice);
        vm.expectRevert(NoteMarket.NotActive.selector);
        d.noteMarket.cancel(id);
        vm.prank(alice);
        vm.expectRevert(NoteMarket.NotActive.selector);
        d.noteMarket.updatePrice(id, 1e18);
        vm.prank(carol);
        vm.expectRevert(NoteMarket.NotActive.selector);
        d.noteMarket.buy(id, 1, 1e18, block.timestamp);
    }

    function test_buyOutClosesListing() public {
        vm.prank(alice);
        uint256 id = d.noteMarket.list(seriesId, 1_000e6, 1e18);
        vm.prank(carol);
        d.noteMarket.buy(id, 1_000e6, 1e18, block.timestamp);
        assertFalse(d.noteMarket.getListing(id).active);
    }

    function test_validationAndAdmin() public {
        vm.startPrank(alice);
        vm.expectRevert(NoteMarket.ZeroAmount.selector);
        d.noteMarket.list(seriesId, 0, 1e18);
        uint256 id = d.noteMarket.list(seriesId, 1_000e6, 1e18);
        vm.expectRevert(NoteMarket.ZeroAmount.selector);
        d.noteMarket.updatePrice(id, 0);
        vm.stopPrank();
        vm.prank(carol);
        vm.expectRevert(NoteMarket.NotSeller.selector);
        d.noteMarket.updatePrice(id, 1);

        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.noteMarket.setFee(101);
        d.noteMarket.setFee(0);
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        d.noteMarket.setFeeCollector(address(0));
        d.noteMarket.setFeeCollector(treasury);
        vm.prank(carol);
        d.noteMarket.buy(id, 10e6, 1e18, block.timestamp);
        assertTrue(d.noteMarket.supportsInterface(0x4e2312e0)); // ERC1155Receiver
    }

    function test_complianceGating() public {
        d.compliance.setEnabled(true);
        vm.prank(alice);
        vm.expectRevert(NoteMarket.NotAllowed.selector);
        d.noteMarket.list(seriesId, 1_000e6, 1e18);
        address[] memory l = new address[](1);
        l[0] = alice;
        vm.prank(guardian);
        d.compliance.setAllowed(l, true);
        vm.prank(alice);
        uint256 id = d.noteMarket.list(seriesId, 1_000e6, 1e18);
        vm.prank(carol);
        vm.expectRevert(NoteMarket.NotAllowed.selector);
        d.noteMarket.buy(id, 1, 1e18, block.timestamp);
        d.noteMarket.setCompliance(IComplianceRegistry(address(0)));
        vm.prank(carol);
        d.noteMarket.buy(id, 1e6, 1e18, block.timestamp);
    }

    function test_pauseKeepsCancelOpen() public {
        vm.prank(alice);
        uint256 id = d.noteMarket.list(seriesId, 1_000e6, 1e18);
        vm.prank(guardian);
        d.noteMarket.pause();
        vm.prank(carol);
        vm.expectRevert();
        d.noteMarket.buy(id, 1, 1e18, block.timestamp);
        vm.prank(alice);
        d.noteMarket.cancel(id);
    }
}

contract TokenAndFeesTest is BaseTest {
    MockERC20 internal ovnd;

    function setUp() public override {
        super.setUp();
        ovnd = new MockERC20("Overnight", "OVND", 18);
        ovnd.mint(carol, 10_000e18);
        ovnd.mint(dave, 10_000e18);
        vm.prank(carol);
        ovnd.approve(address(d.hooks), type(uint256).max);
        vm.prank(dave);
        ovnd.approve(address(d.hooks), type(uint256).max);
    }

    function test_tokenFeaturesDisabledUntilSet() public {
        assertFalse(d.hooks.isActive());
        assertEq(d.hooks.feeDiscountBps(carol), 0);
        vm.prank(carol);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        d.hooks.stake(1);
        vm.prank(carol);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        d.hooks.requestUnstake(1);
        // all fees go to treasury
        usdc.mint(address(d.feeCollector), 100e6);
        (uint256 toS, uint256 toT) = d.feeCollector.distribute();
        assertEq(toS, 0);
        assertEq(toT, 100e6);
        assertEq(usdc.balanceOf(treasury), 10_000_000e6 + 100e6);
        (toS, toT) = d.feeCollector.distribute();
        assertEq(toT, 0);
    }

    function test_setProjectTokenOnce() public {
        vm.prank(carol);
        vm.expectRevert();
        d.hooks.setProjectToken(address(ovnd));
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        d.hooks.setProjectToken(address(0));
        vm.expectRevert(ProjectTokenHooks.NotAContract.selector);
        d.hooks.setProjectToken(carol);
        d.hooks.setProjectToken(address(ovnd));
        assertTrue(d.hooks.isActive());
        vm.expectRevert(ProjectTokenHooks.TokenAlreadySet.selector);
        d.hooks.setProjectToken(address(usdc));
    }

    function test_stakingRewardsAndCooldown() public {
        d.hooks.setProjectToken(address(ovnd));
        // fees arriving with no stakers go to treasury entirely
        vm.prank(carol);
        d.hooks.stake(1_000e18);
        vm.prank(dave);
        d.hooks.stake(3_000e18);
        usdc.mint(address(d.feeCollector), 1_000e6);
        (uint256 toS, uint256 toT) = d.feeCollector.distribute();
        assertEq(toS, 500e6);
        assertEq(toT, 500e6);
        assertEq(d.hooks.pendingRewards(carol), 125e6);
        assertEq(d.hooks.pendingRewards(dave), 375e6);

        uint256 c0 = usdc.balanceOf(carol);
        vm.prank(carol);
        d.hooks.claimRewards();
        assertEq(usdc.balanceOf(carol), c0 + 125e6);
        vm.prank(carol);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        d.hooks.claimRewards();

        vm.startPrank(dave);
        vm.expectRevert(ProjectTokenHooks.Insufficient.selector);
        d.hooks.requestUnstake(5_000e18);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        d.hooks.requestUnstake(0);
        d.hooks.requestUnstake(3_000e18);
        vm.expectRevert(ProjectTokenHooks.CooldownActive.selector);
        d.hooks.withdraw();
        vm.warp(block.timestamp + 7 days);
        d.hooks.withdraw();
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        d.hooks.withdraw();
        d.hooks.claimRewards(); // rewards accrued before unstake are kept
        vm.stopPrank();
        assertEq(ovnd.balanceOf(dave), 10_000e18);
        vm.prank(carol);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        d.hooks.stake(0);
    }

    function test_notifyWithNoStakersCarriesOver() public {
        d.hooks.setProjectToken(address(ovnd));
        usdc.mint(address(d.hooks), 100e6);
        vm.prank(address(d.feeCollector));
        d.hooks.notifyReward(100e6);
        assertEq(d.hooks.undistributed(), 100e6);
        vm.prank(carol);
        d.hooks.stake(1_000e18);
        usdc.mint(address(d.hooks), 50e6);
        vm.prank(address(d.feeCollector));
        d.hooks.notifyReward(50e6);
        assertEq(d.hooks.pendingRewards(carol), 150e6);
    }

    function test_discountTier() public {
        d.hooks.setProjectToken(address(ovnd));
        assertEq(d.hooks.feeDiscountBps(carol), 0); // tier threshold unset
        d.hooks.setTier(1_000e18, 2_500, 3 days);
        vm.prank(carol);
        d.hooks.stake(999e18);
        vm.warp(block.timestamp + 3 days);
        assertEq(d.hooks.feeDiscountBps(carol), 0);
        vm.prank(carol);
        d.hooks.stake(1e18); // resets age
        assertEq(d.hooks.feeDiscountBps(carol), 0);
        vm.warp(block.timestamp + 3 days);
        assertEq(d.hooks.feeDiscountBps(carol), 2_500);
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.hooks.setTier(1, 6_000, 1);
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.hooks.setUnstakeCooldown(31 days);
        d.hooks.setUnstakeCooldown(1 days);
    }

    function test_feeCollectorAdmin() public {
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        d.feeCollector.setTreasury(address(0));
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.feeCollector.setStakerShare(10_001);
        d.feeCollector.setStakerShare(10_000);
        d.feeCollector.setTreasury(dave);
        d.feeCollector.setHooks(IProjectTokenHooks(address(0)));
        usdc.mint(address(d.feeCollector), 10e6);
        d.feeCollector.distribute();
        assertEq(usdc.balanceOf(dave), 10_000_000e6 + 10e6);

        stock.mint(address(d.feeCollector), 1e18);
        d.feeCollector.sweep(IERC20(address(stock)));
        assertEq(stock.balanceOf(dave), 1_000_000e18 + 1e18);
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.feeCollector.sweep(IERC20(address(usdc)));
    }
}

contract OracleTest is BaseTest {
    function test_scalingAndStaleness() public {
        (uint256 p, uint256 t) = d.oracle.getPrice(address(stock));
        assertEq(p, 200e18);
        assertEq(t, block.timestamp);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert();
        d.oracle.getPrice(address(stock));
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoFeed.selector, address(usdc)));
        d.oracle.getPrice(address(usdc));
    }

    function test_closedMarketLongerStaleness() public {
        d.clock.setMarketHours(13 hours + 30 minutes, 20 hours, 0x1F, true);
        uint256 t = block.timestamp;
        while (((t / 1 days) + 3) % 7 != 4) t += 1 days; // Friday
        t = (t / 1 days) * 1 days + 19 hours;
        vm.warp(t);
        feed.set(200e8);
        vm.warp(t + 2 days); // Sunday 19:00 -> closed, 3d window
        (uint256 p,) = d.oracle.getPrice(address(stock));
        assertEq(p, 200e18);
        vm.warp(t + 3 days); // Monday 19:00, open, 1d window exceeded
        vm.expectRevert();
        d.oracle.getPrice(address(stock));
    }

    function test_invalidAnswers() public {
        feed.setRaw(0, block.timestamp, 2, 2);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidAnswer.selector, address(feed)));
        d.oracle.getPrice(address(stock));
        feed.setRaw(1e8, block.timestamp, 3, 2);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidAnswer.selector, address(feed)));
        d.oracle.getPrice(address(stock));
        feed.setRaw(1e8, block.timestamp + 10, 4, 4);
        vm.expectRevert();
        d.oracle.getPrice(address(stock));
        feed.setRaw(1e8, 0, 5, 5);
        vm.expectRevert();
        d.oracle.getPrice(address(stock));
    }

    function test_decimalsAbove18() public {
        MockAggregator f = new MockAggregator(20, 200e20);
        d.oracle.setFeed(address(usdc), feedCfg(address(f)));
        (uint256 p,) = d.oracle.getPrice(address(usdc));
        assertEq(p, 200e18);
        MockAggregator tiny = new MockAggregator(20, 1);
        d.oracle.setFeed(address(usdc), feedCfg(address(tiny)));
        vm.expectRevert();
        d.oracle.getPrice(address(usdc));
    }

    function test_deviationCheck() public {
        MockAggregator sec = new MockAggregator(8, 202e8);
        OracleAdapter.FeedConfig memory c = feedCfg(address(feed));
        c.secondary = address(sec);
        c.maxDeviationBps = 200;
        d.oracle.setFeed(address(stock), c);
        (uint256 p,) = d.oracle.getPrice(address(stock));
        assertEq(p, 200e18);
        sec.set(210e8);
        vm.expectRevert();
        d.oracle.getPrice(address(stock));
    }

    function test_sequencerUptime() public {
        MockAggregator seq = new MockAggregator(0, 0);
        seq.setStartedAt(block.timestamp - 2 hours);
        d.oracle.setSequencerUptimeFeed(IAggregatorV3(address(seq)), 1 hours);
        d.oracle.getPrice(address(stock));
        seq.setStartedAt(block.timestamp - 10 minutes);
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        d.oracle.getPrice(address(stock));
        seq.setRaw(1, block.timestamp, 2, 2);
        seq.setStartedAt(block.timestamp - 2 hours);
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        d.oracle.getPrice(address(stock));
    }

    function test_feedConfigValidation() public {
        OracleAdapter.FeedConfig memory c = feedCfg(address(feed));
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        d.oracle.setFeed(address(0), c);
        c.maxStaleness = 0;
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.oracle.setFeed(address(stock), c);
        c = feedCfg(address(feed));
        c.secondary = address(feed2);
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.oracle.setFeed(address(stock), c);
        assertEq(d.oracle.feedOf(address(stock)).primary, address(feed));
        d.oracle.setClock(IMarketClock(address(0)));
        d.oracle.getPrice(address(stock));
    }

    function test_pushPriceFeed() public {
        PushPriceFeed pf = new PushPriceFeed(address(this), 8, "STKA / USD", 1_000);
        pf.grantRole(pf.UPDATER_ROLE(), keeper);
        vm.startPrank(keeper);
        pf.push(200e8, block.timestamp);
        vm.expectRevert(PushPriceFeed.StaleObservation.selector);
        pf.push(201e8, block.timestamp);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(PushPriceFeed.JumpTooLarge.selector);
        pf.push(250e8, block.timestamp);
        vm.expectRevert(PushPriceFeed.BadAnswer.selector);
        pf.push(0, block.timestamp);
        vm.expectRevert(PushPriceFeed.StaleObservation.selector);
        pf.push(201e8, block.timestamp + 1);
        pf.push(210e8, block.timestamp);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
        pf.forcePush(300e8, block.timestamp);
        (uint80 rid, int256 a,,,) = pf.latestRoundData();
        assertEq(rid, 3);
        assertEq(a, 300e8);
        pf.setMaxJump(0);
        assertEq(pf.decimals(), 8);
        // usable as an adapter feed
        d.oracle.setFeed(address(stock2), feedCfg(address(pf)));
        (uint256 p,) = d.oracle.getPrice(address(stock2));
        assertEq(p, 300e18);
    }
}

contract GovernanceTest is BaseTest {
    function test_timelockFloorAndHandoff() public {
        address[] memory a = new address[](1);
        a[0] = admin;
        vm.expectRevert(OvernightTimelock.DelayTooShort.selector);
        new OvernightTimelock(1 days, a, a);

        _handoff(d, address(this));
        bytes32 role = 0x00;
        assertTrue(d.auctionHouse.hasRole(role, address(d.timelock)));
        assertFalse(d.auctionHouse.hasRole(role, address(this)));
        assertTrue(d.hooks.hasRole(role, address(d.timelock)));
        vm.expectRevert();
        d.hooks.setProjectToken(address(usdc));

        // setProjectToken via the timelock after 48h
        MockERC20 ovnd = new MockERC20("Overnight", "OVND", 18);
        bytes memory data = abi.encodeCall(ProjectTokenHooks.setProjectToken, (address(ovnd)));
        vm.prank(admin);
        vm.expectRevert();
        d.timelock.schedule(address(d.hooks), 0, data, bytes32(0), bytes32(0), 1 days);
        vm.prank(admin);
        d.timelock.schedule(address(d.hooks), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.warp(block.timestamp + 48 hours - 1);
        vm.prank(admin);
        vm.expectRevert();
        d.timelock.execute(address(d.hooks), 0, data, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 1);
        vm.prank(admin);
        d.timelock.execute(address(d.hooks), 0, data, bytes32(0), bytes32(0));
        assertEq(address(d.hooks.projectToken()), address(ovnd));

        // lowering the delay below the floor has no effect
        bytes memory upd = abi.encodeCall(d.timelock.updateDelay, (1 hours));
        vm.prank(admin);
        d.timelock.schedule(address(d.timelock), 0, upd, bytes32(0), bytes32(uint256(1)), 48 hours);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(admin);
        d.timelock.execute(address(d.timelock), 0, upd, bytes32(0), bytes32(uint256(1)));
        assertEq(d.timelock.getMinDelay(), 48 hours);
    }

    function test_guardianCannotChangeParams() public {
        vm.startPrank(guardian);
        vm.expectRevert();
        d.registry.setParams(defaultParams());
        d.registry.pause();
        d.registry.unpause();
        vm.stopPrank();
    }
}

contract ClockAndRegistryTest is BaseTest {
    function test_clockPhases() public {
        assertEq(uint8(d.clock.phase(0)), uint8(IMarketClock.Phase.Commit));
        assertEq(uint8(d.clock.phase(1)), uint8(IMarketClock.Phase.Pending));
        vm.warp(START + COMMIT);
        assertEq(uint8(d.clock.phase(0)), uint8(IMarketClock.Phase.Reveal));
        vm.warp(START + COMMIT + REVEAL);
        assertEq(uint8(d.clock.phase(0)), uint8(IMarketClock.Phase.Clearing));
        vm.warp(START + COMMIT + REVEAL + CLEARW);
        assertEq(uint8(d.clock.phase(0)), uint8(IMarketClock.Phase.Expired));
        assertEq(d.clock.interval(), INTERVAL);
        assertTrue(d.clock.isEquityMarketOpen());
    }

    function test_clockValidation() public {
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        new MarketClock(admin, 0, 1 days, 0, 1, 1);
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        new MarketClock(admin, 0, 1 days, 20 hours, 4 hours, 1);
        MarketClock c = new MarketClock(admin, uint64(block.timestamp + 1), 1 days, 1 hours, 1 hours, 1 hours);
        vm.expectRevert(MarketClock.BeforeGenesis.selector);
        c.currentEpoch();
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.clock.setMarketHours(10, 5, 0x1F, true);
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.clock.setMarketHours(1, 5, 0xFF, true);
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        new MarketClock(address(0), 0, 1 days, 1 hours, 1 hours, 1 hours);
    }

    function test_marketHours() public {
        d.clock.setMarketHours(13 hours + 30 minutes, 20 hours, 0x1F, true);
        uint256 t = block.timestamp;
        while (((t / 1 days) + 3) % 7 != 0) t += 1 days; // Monday
        t = (t / 1 days) * 1 days;
        vm.warp(t + 13 hours);
        assertFalse(d.clock.isEquityMarketOpen());
        vm.warp(t + 14 hours);
        assertTrue(d.clock.isEquityMarketOpen());
        vm.warp(t + 20 hours);
        assertFalse(d.clock.isEquityMarketOpen());
        vm.warp(t + 5 days + 14 hours); // Saturday
        assertFalse(d.clock.isEquityMarketOpen());
    }

    function test_registryValidation() public {
        ITermRegistry.Params memory p = defaultParams();
        p.minOrderSize = 0;
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.registry.setParams(p);
        p = defaultParams();
        p.maxRateBps = 0;
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.registry.setParams(p);
        p = defaultParams();
        p.auctionFeeBpsPerYear = 501;
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.registry.setParams(p);
        p = defaultParams();
        p.noRevealPenaltyBps = 1_001;
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.registry.setParams(p);
        p = defaultParams();
        p.maxOrdersPerSide = 65;
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.registry.setParams(p);
        p = defaultParams();
        p.marginCallGracePeriod = 1;
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.registry.setParams(p);
        p = defaultParams();
        p.maturityGracePeriod = 8 days;
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.registry.setParams(p);

        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.registry.addTerm(1, "x");
        vm.expectRevert(TermRegistry.UnknownTerm.selector);
        d.registry.setTermEnabled(9, false);
        vm.expectRevert(TermRegistry.UnknownTerm.selector);
        d.registry.getTerm(9);
        vm.expectRevert(TermRegistry.UnknownTerm.selector);
        d.registry.addBook(9, address(stock));
        vm.expectRevert(TermRegistry.CollateralNotEnabled.selector);
        d.registry.addBook(0, address(usdc));
        vm.expectRevert(TermRegistry.DuplicateBook.selector);
        d.registry.addBook(0, address(stock));
        vm.expectRevert(TermRegistry.UnknownBook.selector);
        d.registry.setBookEnabled(99, false);
        vm.expectRevert(TermRegistry.UnknownBook.selector);
        d.registry.getBook(99);
        vm.expectRevert(TermRegistry.UnknownBook.selector);
        d.registry.bookDuration(99);
        assertFalse(d.registry.isBookActive(99));

        ITermRegistry.CollateralConfig memory c = defaultCollateral();
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        d.registry.configureCollateral(address(0), c);
        c.maintenanceHaircutBps = 2_500;
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.registry.configureCollateral(address(stock), c);
        c = defaultCollateral();
        c.initialHaircutBps = 9_500;
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.registry.configureCollateral(address(stock), c);
        c = defaultCollateral();
        c.liquidationPenaltyBps = 2_500;
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.registry.configureCollateral(address(stock), c);
        c = defaultCollateral();
        c.liquidationPenaltyBps = 1_200;
        vm.expectRevert(ProtocolAccess.InvalidParam.selector);
        d.registry.configureCollateral(address(stock), c);

        d.registry.setTermEnabled(1, false);
        assertFalse(d.registry.isBookActive(book7));
        d.registry.setTermEnabled(1, true);
        d.registry.setBookEnabled(book7, false);
        assertFalse(d.registry.isBookActive(book7));
        assertEq(d.registry.termCount(), 4);
        assertEq(d.registry.bookCount(), 5);
        assertEq(d.registry.getTerm(0).duration, 1 days);
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        new TermRegistry(admin, address(0), defaultParams());
    }

    function test_noteAdmin() public {
        d.note.setURI("ipfs://x/{id}");
        assertEq(d.note.uri(1), "ipfs://x/{id}");
        vm.prank(alice);
        vm.expectRevert();
        d.note.mint(alice, 1, 1);
        vm.prank(alice);
        vm.expectRevert();
        d.note.burn(alice, 1, 1);
        assertTrue(d.note.supportsInterface(0xd9b67a26));
        assertTrue(d.note.supportsInterface(type(IAccessControl).interfaceId));
    }

    function test_complianceBatchLimit() public {
        address[] memory l = new address[](201);
        vm.prank(guardian);
        vm.expectRevert(ComplianceRegistry.BatchTooLarge.selector);
        d.compliance.setAllowed(l, true);
        assertTrue(d.compliance.isAllowed(alice));
    }

    function test_constructorsZeroAddress() public {
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        new FeeCollector(admin, IERC20(address(0)), treasury);
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        new ProjectTokenHooks(admin, IERC20(address(0)));
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        new NoteMarket(admin, IRepoNote(address(d.note)), IERC20(address(usdc)), address(0));
    }
}
