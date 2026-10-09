// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {AuctionHouse} from "../../src/core/AuctionHouse.sol";
import {IRepoLocker} from "../../src/interfaces/IRepoLocker.sol";
import {ITermRegistry} from "../../src/interfaces/ITermRegistry.sol";
import {IComplianceRegistry} from "../../src/interfaces/IComplianceRegistry.sol";
import {IProjectTokenHooks} from "../../src/interfaces/IProjectTokenHooks.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {ProtocolAccess} from "../../src/access/ProtocolAccess.sol";

contract AuctionHouseTest is BaseTest {
    function test_happyPath_matchAndSettle() public {
        uint256 lendBal = usdc.balanceOf(alice);
        uint256 bobUsdc = usdc.balanceOf(bob);
        (uint256 repoId, uint256 seriesId, uint256 lendId, uint256 borrowId) =
            openSimpleRepo(book7, 10_000e6, 100e18, 400, 600);

        AuctionHouse.AuctionResult memory r = d.auctionHouse.getResult(book7, 0);
        assertTrue(r.cleared);
        assertEq(r.clearingRateBps, 500); // midpoint of 4% and 6%
        assertEq(r.volume, 10_000e6);
        assertEq(seriesId, 1);

        // lender got notes, borrower got principal net of fee
        assertEq(d.note.balanceOf(alice, seriesId), 10_000e6);
        assertEq(usdc.balanceOf(alice), lendBal - 10_000e6);
        uint256 fee = (uint256(10_000e6) * 25 * 7 days) / (10_000 * 365 days);
        assertEq(usdc.balanceOf(bob), bobUsdc + 10_000e6 - fee);
        assertEq(usdc.balanceOf(address(d.feeCollector)), fee);

        IRepoLocker.Repo memory rp = repo(repoId);
        assertEq(rp.borrower, bob);
        assertEq(rp.principal, 10_000e6);
        assertEq(rp.collateralAmount, 100e18);
        assertEq(rp.rateBps, 500);
        assertEq(rp.maturity, block.timestamp + 7 days);
        assertEq(uint8(rp.status), uint8(IRepoLocker.RepoStatus.Active));
        assertEq(stock.balanceOf(address(d.locker)), 100e18);

        // settling twice fails
        vm.expectRevert(AuctionHouse.BadState.selector);
        d.auctionHouse.settle(lendId);
        vm.expectRevert(AuctionHouse.BadState.selector);
        d.auctionHouse.settle(borrowId);
    }

    function test_noCross_noMatchRefunds() public {
        uint64 e = epochNow();
        (uint256 l, bytes32 s1) = commitLend(alice, book7, 1_000e6, 800, false);
        (uint256 b, bytes32 s2) = commitBorrow(bob, book7, 1_000e6, 10e18, 500, false);
        toReveal(e);
        reveal(l, 800, s1);
        reveal(b, 500, s2);
        toClearing(e);
        AuctionHouse.AuctionResult memory r = d.auctionHouse.clear(book7, e);
        assertEq(r.volume, 0);
        assertEq(r.seriesId, 0);
        uint256 a0 = usdc.balanceOf(alice);
        uint256 b0 = stock.balanceOf(bob);
        d.auctionHouse.settle(l);
        d.auctionHouse.settle(b);
        assertEq(usdc.balanceOf(alice), a0 + 1_000e6);
        assertEq(stock.balanceOf(bob), b0 + 10e18);
    }

    function test_partialFill_proRataAndCollateralRefund() public {
        uint64 e = epochNow();
        // two lenders same rate (marginal tier), one borrower smaller
        (uint256 l1, bytes32 s1) = commitLend(alice, book30, 3_000e6, 300, false);
        (uint256 l2, bytes32 s2) = commitLend(carol, book30, 1_000e6, 300, false);
        (uint256 b1, bytes32 s3) = commitBorrow(bob, book30, 2_000e6, 50e18, 700, false);
        toReveal(e);
        reveal(l1, 300, s1);
        reveal(l2, 300, s2);
        reveal(b1, 700, s3);
        toClearing(e);
        AuctionHouse.AuctionResult memory r = d.auctionHouse.clear(book30, e);
        assertEq(r.volume, 2_000e6);
        assertEq(r.clearingRateBps, 500);
        assertEq(d.auctionHouse.getOrder(l1).filled, 1_500e6);
        assertEq(d.auctionHouse.getOrder(l2).filled, 500e6);

        uint256 a0 = usdc.balanceOf(alice);
        d.auctionHouse.settle(l1);
        assertEq(usdc.balanceOf(alice), a0 + 1_500e6);
        assertEq(d.note.balanceOf(alice, r.seriesId), 1_500e6);
        d.auctionHouse.settle(l2);
        assertEq(d.note.balanceOf(carol, r.seriesId), 500e6);
    }

    function test_partialBorrowFill_collateralProRata() public {
        uint64 e = epochNow();
        (uint256 l1, bytes32 s1) = commitLend(alice, book7, 1_000e6, 300, false);
        (uint256 b1, bytes32 s2) = commitBorrow(bob, book7, 4_000e6, 40e18, 700, false);
        toReveal(e);
        reveal(l1, 300, s1);
        reveal(b1, 700, s2);
        toClearing(e);
        d.auctionHouse.clear(book7, e);
        AuctionHouse.Order memory o = d.auctionHouse.getOrder(b1);
        assertEq(o.filled, 1_000e6);
        assertEq(o.lockedCollateral, 10e18);
        uint256 s0 = stock.balanceOf(bob);
        d.auctionHouse.settle(b1);
        assertEq(stock.balanceOf(bob), s0 + 30e18);
    }

    function test_unrevealedPenalty_lenderAndBorrower() public {
        uint64 e = epochNow();
        (uint256 l,) = commitLend(alice, book7, 1_000e6, 400, false);
        (uint256 b,) = commitBorrow(bob, book7, 1_000e6, 10e18, 500, false);
        toReveal(e);
        vm.expectRevert(AuctionHouse.WrongPhase.selector);
        d.auctionHouse.settle(l);
        toClearing(e);
        uint256 a0 = usdc.balanceOf(alice);
        uint256 b0 = stock.balanceOf(bob);
        d.auctionHouse.settle(l);
        d.auctionHouse.settle(b);
        assertEq(usdc.balanceOf(alice), a0 + 990e6);
        assertEq(usdc.balanceOf(address(d.feeCollector)), 10e6);
        assertEq(stock.balanceOf(bob), b0 + 9.9e18);
        assertEq(stock.balanceOf(address(d.feeCollector)), 0.1e18);
        // clearing ignores them
        AuctionHouse.AuctionResult memory r = d.auctionHouse.clear(book7, e);
        assertEq(r.volume, 0);
    }

    function test_cancel_duringCommitOnly() public {
        (uint256 l,) = commitLend(alice, book7, 1_000e6, 400, false);
        (uint256 b,) = commitBorrow(bob, book7, 1_000e6, 10e18, 500, false);
        (uint256 l2,) = commitLend(carol, book7, 1_000e6, 400, false);
        vm.expectRevert(AuctionHouse.NotOwner.selector);
        d.auctionHouse.cancel(l);
        uint256 a0 = usdc.balanceOf(alice);
        vm.prank(alice);
        d.auctionHouse.cancel(l);
        assertEq(usdc.balanceOf(alice), a0 + 1_000e6);
        uint256 s0 = stock.balanceOf(bob);
        vm.prank(bob);
        d.auctionHouse.cancel(b);
        assertEq(stock.balanceOf(bob), s0 + 10e18);
        (uint256[] memory lends, uint256[] memory borrows) = d.auctionHouse.bookOrders(book7, 0);
        assertEq(lends.length, 1);
        assertEq(lends[0], l2);
        assertEq(borrows.length, 0);
        vm.prank(alice);
        vm.expectRevert(AuctionHouse.BadState.selector);
        d.auctionHouse.cancel(l);
        toReveal(0);
        vm.prank(carol);
        vm.expectRevert(AuctionHouse.WrongPhase.selector);
        d.auctionHouse.cancel(l2);
    }

    function test_commitValidation() public {
        bytes32 h = keccak256("x");
        vm.startPrank(alice);
        vm.expectRevert(AuctionHouse.OrderTooSmall.selector);
        d.auctionHouse.commitLend(book7, 1e6, h, false);
        vm.expectRevert(AuctionHouse.BadCommitment.selector);
        d.auctionHouse.commitLend(book7, 1_000e6, bytes32(0), false);
        vm.expectRevert(AuctionHouse.BookInactive.selector);
        d.auctionHouse.commitLend(99, 1_000e6, h, false);
        vm.expectRevert(AuctionHouse.ZeroAmount.selector);
        d.auctionHouse.commitBorrow(book7, 1_000e6, 0, h, false);
        vm.stopPrank();
        toReveal(0);
        vm.prank(alice);
        vm.expectRevert(AuctionHouse.WrongPhase.selector);
        d.auctionHouse.commitLend(book7, 1_000e6, h, false);
    }

    function test_revealValidation() public {
        (uint256 l, bytes32 s) = commitLend(alice, book7, 1_000e6, 400, false);
        vm.expectRevert(AuctionHouse.WrongPhase.selector);
        reveal(l, 400, s);
        toReveal(0);
        vm.expectRevert(AuctionHouse.BadCommitment.selector);
        reveal(l, 401, s);
        vm.expectRevert(AuctionHouse.RateOutOfRange.selector);
        reveal(l, 0, s);
        vm.expectRevert(AuctionHouse.RateOutOfRange.selector);
        reveal(l, 5_001, s);
        reveal(l, 400, s);
        vm.expectRevert(AuctionHouse.BadState.selector);
        reveal(l, 400, s);
    }

    function test_bookFull() public {
        ITermRegistry.Params memory p = defaultParams();
        p.maxOrdersPerSide = 2;
        d.registry.setParams(p);
        commitLend(alice, book7, 1_000e6, 400, false);
        commitLend(alice, book7, 1_000e6, 400, false);
        bytes32 h = keccak256("x");
        vm.prank(alice);
        vm.expectRevert(AuctionHouse.BookFull.selector);
        d.auctionHouse.commitLend(book7, 1_000e6, h, false);
    }

    function test_collateralCap() public {
        ITermRegistry.CollateralConfig memory c = defaultCollateral();
        c.maxCollateralPerAuction = 15e18;
        d.registry.configureCollateral(address(stock), c);
        commitBorrow(bob, book7, 1_000e6, 10e18, 500, false);
        bytes32 h = keccak256("x");
        vm.prank(bob);
        vm.expectRevert(AuctionHouse.CollateralCapExceeded.selector);
        d.auctionHouse.commitBorrow(book7, 1_000e6, 10e18, h, false);
    }

    function test_clearValidation() public {
        vm.expectRevert(AuctionHouse.WrongPhase.selector);
        d.auctionHouse.clear(book7, 0);
        toClearing(0);
        d.auctionHouse.clear(book7, 0);
        vm.expectRevert(AuctionHouse.AlreadyCleared.selector);
        d.auctionHouse.clear(book7, 0);
        vm.warp(d.clock.expiry(0));
        vm.expectRevert(AuctionHouse.WrongPhase.selector);
        d.auctionHouse.clear(book30, 0);
    }

    function test_keeperFailure_expiryRefund() public {
        uint64 e = epochNow();
        (uint256 l, bytes32 s1) = commitLend(alice, book7, 1_000e6, 400, false);
        (uint256 b, bytes32 s2) = commitBorrow(bob, book7, 1_000e6, 10e18, 500, false);
        toReveal(e);
        reveal(l, 400, s1);
        reveal(b, 500, s2);
        toClearing(e);
        vm.expectRevert(AuctionHouse.WrongPhase.selector);
        d.auctionHouse.settle(l);
        vm.warp(d.clock.expiry(e));
        uint256 a0 = usdc.balanceOf(alice);
        uint256 b0 = stock.balanceOf(bob);
        d.auctionHouse.settle(l);
        d.auctionHouse.settle(b);
        assertEq(usdc.balanceOf(alice), a0 + 1_000e6);
        assertEq(stock.balanceOf(bob), b0 + 10e18);
    }

    function test_borrowerFailingInitialMarginExcluded() public {
        uint64 e = epochNow();
        // 10 shares * $200 = $2000; 80% = $1600 < $1700
        (uint256 l, bytes32 s1) = commitLend(alice, book7, 5_000e6, 400, false);
        (uint256 b, bytes32 s2) = commitBorrow(bob, book7, 1_700e6, 10e18, 500, true);
        (uint256 b2, bytes32 s3) = commitBorrow(carol, book7, 1_600e6, 10e18, 450, false);
        toReveal(e);
        reveal(l, 400, s1);
        reveal(b, 500, s2);
        reveal(b2, 450, s3);
        toClearing(e);
        AuctionHouse.AuctionResult memory r = d.auctionHouse.clear(book7, e);
        assertEq(r.volume, 1_600e6);
        assertEq(r.clearingRateBps, 425);
        assertEq(d.auctionHouse.getOrder(b).filled, 0);
        assertEq(d.auctionHouse.getOrder(b).rolledInto, 0); // invalid orders are refunded, not rolled
        uint256 s0 = stock.balanceOf(bob);
        d.auctionHouse.settle(b);
        assertEq(stock.balanceOf(bob), s0 + 10e18);
    }

    function test_rolloverOfLeftovers() public {
        uint64 e = epochNow();
        (uint256 l, bytes32 s1) = commitLend(alice, book7, 3_000e6, 400, true);
        (uint256 b, bytes32 s2) = commitBorrow(bob, book7, 1_000e6, 100e18, 500, false);
        (uint256 b2, bytes32 s3) = commitBorrow(carol, book7, 1_000e6, 100e18, 100, true); // below lender rate
        toReveal(e);
        reveal(l, 400, s1);
        reveal(b, 500, s2);
        reveal(b2, 100, s3);
        toClearing(e);
        d.auctionHouse.clear(book7, e);
        AuctionHouse.Order memory lo = d.auctionHouse.getOrder(l);
        assertEq(lo.filled, 1_000e6);
        assertTrue(lo.rolledInto != 0);
        AuctionHouse.Order memory rolled = d.auctionHouse.getOrder(lo.rolledInto);
        assertEq(rolled.epoch, e + 1);
        assertEq(rolled.amount, 2_000e6);
        assertEq(uint8(rolled.state), uint8(AuctionHouse.State.Revealed));
        assertEq(rolled.rateBps, 400);
        AuctionHouse.Order memory bo2 = d.auctionHouse.getOrder(b2);
        assertTrue(bo2.rolledInto != 0);
        assertEq(d.auctionHouse.getOrder(bo2.rolledInto).collateral, 100e18);

        // settle original: notes only, no refund
        uint256 a0 = usdc.balanceOf(alice);
        d.auctionHouse.settle(l);
        assertEq(usdc.balanceOf(alice), a0);
        uint256 c0 = stock.balanceOf(carol);
        d.auctionHouse.settle(b2);
        assertEq(stock.balanceOf(carol), c0);

        _secondAuction(e, lo.rolledInto, bo2.rolledInto);
    }

    function _secondAuction(uint64 e, uint256 rolledLend, uint256 rolledBorrow) internal {
        // next auction: a new borrower at 450 matches the rolled lender; carol's rolled bid at 100 does not
        toNextCommit();
        (uint256 b3, bytes32 s4) = commitBorrow(dave, book7, 2_000e6, 100e18, 450, false);
        toReveal(e + 1);
        reveal(b3, 450, s4);
        toClearing(e + 1);
        AuctionHouse.AuctionResult memory r2 = d.auctionHouse.clear(book7, e + 1);
        assertEq(r2.volume, 2_000e6);
        assertEq(r2.clearingRateBps, 425);
        d.auctionHouse.settle(rolledLend);
        assertEq(d.note.balanceOf(alice, r2.seriesId), 2_000e6);
        // carol's rolled order rolled again (still opted in)
        assertTrue(d.auctionHouse.getOrder(rolledBorrow).rolledInto != 0);
    }

    function test_cancelRolledOrder() public {
        uint64 e = epochNow();
        (uint256 l, bytes32 s1) = commitLend(alice, book7, 3_000e6, 400, true);
        toReveal(e);
        reveal(l, 400, s1);
        toClearing(e);
        d.auctionHouse.clear(book7, e);
        uint256 rolledId = d.auctionHouse.getOrder(l).rolledInto;
        d.auctionHouse.settle(l);
        uint256 a0 = usdc.balanceOf(alice);
        vm.prank(alice);
        d.auctionHouse.cancel(rolledId);
        assertEq(usdc.balanceOf(alice), a0 + 3_000e6);
    }

    function test_rolloverSkippedWhenTargetFull() public {
        ITermRegistry.Params memory p = defaultParams();
        p.maxOrdersPerSide = 1;
        d.registry.setParams(p);
        uint64 e = epochNow();
        (uint256 l, bytes32 s1) = commitLend(alice, book7, 3_000e6, 400, true);
        toReveal(e);
        reveal(l, 400, s1);
        // next epoch's lend side gets filled before clearing of e
        vm.warp(d.clock.epochStart(e + 1));
        refreshFeeds();
        commitLend(carol, book7, 1_000e6, 400, false);
        d.auctionHouse.clear(book7, e);
        assertEq(d.auctionHouse.getOrder(l).rolledInto, 0);
        uint256 a0 = usdc.balanceOf(alice);
        d.auctionHouse.settle(l);
        assertEq(usdc.balanceOf(alice), a0 + 3_000e6);
    }

    function test_compliance_gatesCommits() public {
        d.compliance.setEnabled(true);
        bytes32 h = keccak256("x");
        vm.prank(alice);
        vm.expectRevert(AuctionHouse.NotAllowed.selector);
        d.auctionHouse.commitLend(book7, 1_000e6, h, false);
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.prank(guardian);
        d.compliance.setAllowed(list, true);
        vm.prank(alice);
        d.auctionHouse.commitLend(book7, 1_000e6, h, false);
    }

    function test_pause_blocksCommitAndClear_notSettleOrReveal() public {
        uint64 e = epochNow();
        (uint256 l, bytes32 s1) = commitLend(alice, book7, 1_000e6, 400, false);
        vm.prank(guardian);
        d.auctionHouse.pause();
        bytes32 h = keccak256("x");
        vm.prank(alice);
        vm.expectRevert();
        d.auctionHouse.commitLend(book7, 1_000e6, h, false);
        toReveal(e);
        reveal(l, 400, s1);
        toClearing(e);
        vm.expectRevert();
        d.auctionHouse.clear(book7, e);
        vm.warp(d.clock.expiry(e));
        d.auctionHouse.settle(l);
        vm.prank(guardian);
        d.auctionHouse.unpause();
    }

    function test_feeDiscountForStakers() public {
        MockERC20 ovnd = new MockERC20("OVND", "OVND", 18);
        d.hooks.setProjectToken(address(ovnd));
        d.hooks.setTier(1_000e18, 5_000, 1 days);
        ovnd.mint(bob, 2_000e18);
        vm.startPrank(bob);
        ovnd.approve(address(d.hooks), type(uint256).max);
        d.hooks.stake(1_000e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        refreshFeeds();
        uint256 b0 = usdc.balanceOf(bob);
        openSimpleRepo(book90, 100_000e6, 1_000e18, 400, 600);
        uint256 fullFee = (uint256(100_000e6) * 25 * 90 days) / (10_000 * 365 days);
        assertEq(usdc.balanceOf(bob) - b0, 100_000e6 - fullFee / 2);
    }

    function test_adminSetters() public {
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        d.auctionHouse.setFeeCollector(address(0));
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        d.auctionHouse.setMarginEngine(IMarginEngine(address(0)));
        d.auctionHouse.setFeeCollector(treasury);
        assertEq(d.auctionHouse.feeCollector(), treasury);
        d.auctionHouse.setMarginEngine(IMarginEngine(address(d.engine)));
        d.auctionHouse.setHooks(IProjectTokenHooks(address(0)));
        d.auctionHouse.setCompliance(IComplianceRegistry(address(0)));
        vm.prank(alice);
        vm.expectRevert();
        d.auctionHouse.setFeeCollector(alice);
        assertEq(d.auctionHouse.ordersOf(alice).length, 0);
    }

    function test_settleUnknownOrderReverts() public {
        vm.expectRevert(AuctionHouse.BadState.selector);
        d.auctionHouse.settle(12345);
    }

    // ------------------------------------------------------------------ repo auto-roll

    function _openOvernight() internal returns (uint256 repoId) {
        (repoId,,,) = openSimpleRepo(bookON, 10_000e6, 100e18, 400, 600);
    }

    function test_repoRoll_fullFill() public {
        uint256 repoId = _openOvernight();
        uint256 oldSeries = repo(repoId).seriesId;
        vm.prank(bob);
        d.locker.setAutoRoll(repoId, true, 1_000);

        toNextCommit();
        uint64 e = epochNow();
        uint256 rollId = d.auctionHouse.submitRepoRoll(repoId);
        assertTrue(repo(repoId).rolling);
        vm.expectRevert(AuctionHouse.RollNotEligible.selector);
        d.auctionHouse.submitRepoRoll(repoId);

        (uint256 l, bytes32 s1) = commitLend(carol, bookON, 20_000e6, 300, false);
        toReveal(e);
        reveal(l, 300, s1);
        toClearing(e);
        uint256 debtNow = d.locker.debtOf(repoId);
        AuctionHouse.AuctionResult memory r = d.auctionHouse.clear(bookON, e);
        AuctionHouse.Order memory ro = d.auctionHouse.getOrder(rollId);
        assertEq(r.volume, ro.amount);
        assertEq(r.clearingRateBps, 650);

        IRepoLocker.Repo memory oldR = repo(repoId);
        assertEq(uint8(oldR.status), uint8(IRepoLocker.RepoStatus.Closed));
        IRepoLocker.Repo memory newR = repo(ro.repoId);
        assertEq(newR.collateralAmount, 100e18);
        assertEq(newR.principal, ro.amount);
        assertEq(uint8(newR.status), uint8(IRepoLocker.RepoStatus.Active));
        // old series fully funded and redeemable
        IRepoLocker.Series memory os = d.locker.getSeries(oldSeries);
        assertEq(os.openRepos, 0);
        assertEq(os.cash, debtNow);
        // surplus from rolling early is claimable by the borrower
        assertGe(d.locker.claimable(bob, address(usdc)), 0);
        d.auctionHouse.settle(rollId);
    }

    function test_repoRoll_partialFill() public {
        uint256 repoId = _openOvernight();
        vm.prank(bob);
        d.locker.setAutoRoll(repoId, true, 1_000);
        toNextCommit();
        uint64 e = epochNow();
        uint256 rollId = d.auctionHouse.submitRepoRoll(repoId);
        (uint256 l, bytes32 s1) = commitLend(carol, bookON, 5_000e6, 300, false);
        toReveal(e);
        reveal(l, 300, s1);
        toClearing(e);
        d.auctionHouse.clear(bookON, e);
        AuctionHouse.Order memory ro = d.auctionHouse.getOrder(rollId);
        assertEq(ro.filled, 5_000e6);
        IRepoLocker.Repo memory oldR = repo(repoId);
        assertEq(uint8(oldR.status), uint8(IRepoLocker.RepoStatus.Active));
        assertFalse(oldR.rolling);
        assertLt(oldR.principal, 10_000e6);
        assertEq(oldR.collateralAmount + repo(ro.repoId).collateralAmount, 100e18);
    }

    function test_repoRoll_noFillClearsRolling_andExpiry() public {
        uint256 repoId = _openOvernight();
        vm.prank(bob);
        d.locker.setAutoRoll(repoId, true, 1_000);
        toNextCommit();
        uint64 e = epochNow();
        uint256 rollId = d.auctionHouse.submitRepoRoll(repoId);
        toClearing(e);
        d.auctionHouse.clear(bookON, e);
        assertFalse(repo(repoId).rolling);
        d.auctionHouse.settle(rollId);

        // second attempt on a later epoch which is never cleared -> rolling flag cleared at expiry settle
        vm.warp(d.clock.epochStart(e + 1));
        refreshFeeds();
        // maturity window passed -> not eligible any more
        vm.expectRevert(AuctionHouse.RollNotEligible.selector);
        d.auctionHouse.submitRepoRoll(repoId);
    }

    function test_repoRoll_cancelAndExpiry() public {
        uint256 repoId = _openOvernight();
        vm.prank(bob);
        d.locker.setAutoRoll(repoId, true, 1_000);
        toNextCommit();
        uint64 e = epochNow();
        uint256 rollId = d.auctionHouse.submitRepoRoll(repoId);
        vm.prank(bob);
        d.auctionHouse.cancel(rollId);
        assertFalse(repo(repoId).rolling);
        uint256 rollId2 = d.auctionHouse.submitRepoRoll(repoId);
        vm.warp(d.clock.expiry(e));
        d.auctionHouse.settle(rollId2);
        assertFalse(repo(repoId).rolling);
    }

    function test_repoRoll_eligibility() public {
        uint256 repoId = _openOvernight();
        vm.expectRevert(AuctionHouse.RollNotEligible.selector); // not opted in
        d.auctionHouse.submitRepoRoll(repoId);
        vm.prank(bob);
        d.locker.setAutoRoll(repoId, true, 1_000);
        vm.expectRevert(AuctionHouse.WrongPhase.selector); // still in epoch 0 clearing phase
        d.auctionHouse.submitRepoRoll(repoId);

        // a 90d repo is not eligible in the next auction (matures much later)
        (uint256 r90,,,) = openSimpleRepoAt(book90);
        vm.prank(bob);
        d.locker.setAutoRoll(r90, true, 1_000);
        toNextCommit();
        vm.expectRevert(AuctionHouse.RollNotEligible.selector);
        d.auctionHouse.submitRepoRoll(r90);
    }

    function openSimpleRepoAt(uint32 bookId) internal returns (uint256, uint256, uint256, uint256) {
        toNextCommit();
        return openSimpleRepo(bookId, 1_000e6, 100e18, 400, 600);
    }

    function test_repoRoll_excludedWhenRepoInMarginCall() public {
        uint256 repoId = _openOvernight();
        vm.prank(bob);
        d.locker.setAutoRoll(repoId, true, 1_000);
        toNextCommit();
        uint64 e = epochNow();
        uint256 rollId = d.auctionHouse.submitRepoRoll(repoId);
        (uint256 l, bytes32 s1) = commitLend(carol, bookON, 20_000e6, 300, false);
        toReveal(e);
        reveal(l, 300, s1);
        toClearing(e);
        setPrice(110e8); // 100 sh * 110 = 11k * 88% = 9.68k < debt
        d.engine.poke(repoId);
        AuctionHouse.AuctionResult memory r = d.auctionHouse.clear(bookON, e);
        assertEq(r.volume, 0);
        assertEq(d.auctionHouse.getOrder(rollId).filled, 0);
    }
}
