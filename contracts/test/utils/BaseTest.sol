// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolDeployer} from "../../script/ProtocolDeployer.sol";
import {MockERC20, MockAggregator} from "./Mocks.sol";
import {ITermRegistry} from "../../src/interfaces/ITermRegistry.sol";
import {IRepoLocker} from "../../src/interfaces/IRepoLocker.sol";
import {OracleAdapter} from "../../src/oracle/OracleAdapter.sol";
import {AuctionHouse} from "../../src/core/AuctionHouse.sol";

abstract contract BaseTest is Test, ProtocolDeployer {
    uint64 internal constant INTERVAL = 1 days;
    uint64 internal constant COMMIT = 18 hours;
    uint64 internal constant REVEAL = 2 hours;
    uint64 internal constant CLEARW = 1 days;
    uint256 internal constant START = 1_760_000_000; // 2025-10-09

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice"); // lender
    address internal bob = makeAddr("bob"); // borrower
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal keeper = makeAddr("keeper");

    MockERC20 internal usdc;
    MockERC20 internal stock; // 18-dec tokenized stock
    MockERC20 internal stock2;
    MockAggregator internal feed;
    MockAggregator internal feed2;
    Deployment internal d;

    uint32 internal bookON; // overnight
    uint32 internal book7;
    uint32 internal book30;
    uint32 internal book90;
    uint32 internal book7s2;

    uint256 internal saltNonce;

    function setUp() public virtual {
        vm.warp(START);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stock = new MockERC20("Tokenized Stock A", "STKA", 18);
        stock2 = new MockERC20("Tokenized Stock B", "STKB", 18);
        feed = new MockAggregator(8, 200e8); // $200
        feed2 = new MockAggregator(8, 50e8); // $50

        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;

        CoreConfig memory c = CoreConfig({
            deployer: address(this),
            guardian: guardian,
            treasury: treasury,
            stablecoin: address(usdc),
            params: defaultParams(),
            genesis: uint64(START),
            interval: INTERVAL,
            commitWindow: COMMIT,
            revealWindow: REVEAL,
            clearWindow: CLEARW,
            timelockDelay: 48 hours,
            proposers: proposers,
            executors: executors,
            noteUri: "https://overnightdesk.xyz/api/notes/{id}.json"
        });
        d = _deployProtocol(c);

        d.registry.addTerm(1 days, "Overnight");
        d.registry.addTerm(7 days, "7D");
        d.registry.addTerm(30 days, "30D");
        d.registry.addTerm(90 days, "90D");
        d.registry.configureCollateral(address(stock), defaultCollateral());
        d.registry.configureCollateral(address(stock2), defaultCollateral());
        bookON = d.registry.addBook(0, address(stock));
        book7 = d.registry.addBook(1, address(stock));
        book30 = d.registry.addBook(2, address(stock));
        book90 = d.registry.addBook(3, address(stock));
        book7s2 = d.registry.addBook(1, address(stock2));
        d.oracle.setFeed(address(stock), feedCfg(address(feed)));
        d.oracle.setFeed(address(stock2), feedCfg(address(feed2)));

        address[7] memory users = [alice, bob, carol, dave, keeper, admin, treasury];
        for (uint256 i; i < users.length; ++i) {
            usdc.mint(users[i], 10_000_000e6);
            stock.mint(users[i], 1_000_000e18);
            stock2.mint(users[i], 1_000_000e18);
            vm.startPrank(users[i]);
            usdc.approve(address(d.auctionHouse), type(uint256).max);
            usdc.approve(address(d.locker), type(uint256).max);
            usdc.approve(address(d.liquidator), type(uint256).max);
            usdc.approve(address(d.noteMarket), type(uint256).max);
            stock.approve(address(d.auctionHouse), type(uint256).max);
            stock.approve(address(d.locker), type(uint256).max);
            stock2.approve(address(d.auctionHouse), type(uint256).max);
            stock2.approve(address(d.locker), type(uint256).max);
            d.note.setApprovalForAll(address(d.noteMarket), true);
            vm.stopPrank();
        }
    }

    function defaultParams() internal pure returns (ITermRegistry.Params memory) {
        return ITermRegistry.Params({
            minOrderSize: 100e6,
            maxRateBps: 5_000,
            auctionFeeBpsPerYear: 25,
            noRevealPenaltyBps: 100,
            maxOrdersPerSide: 50,
            marginCallGracePeriod: 4 hours,
            maturityGracePeriod: 4 hours
        });
    }

    function defaultCollateral() internal pure returns (ITermRegistry.CollateralConfig memory) {
        return ITermRegistry.CollateralConfig({
            enabled: true,
            decimals: 0,
            initialHaircutBps: 2_000,
            maintenanceHaircutBps: 1_200,
            liquidationPenaltyBps: 500,
            maxCollateralPerAuction: 0
        });
    }

    function feedCfg(address primary) internal pure returns (OracleAdapter.FeedConfig memory) {
        return OracleAdapter.FeedConfig({
            primary: primary,
            secondary: address(0),
            maxStaleness: 1 days,
            maxStalenessClosed: 3 days,
            maxDeviationBps: 0
        });
    }

    // ------------------------------------------------------------------ auction helpers

    function epochNow() internal view returns (uint64) {
        return d.clock.currentEpoch();
    }

    function toReveal(uint64 e) internal {
        vm.warp(d.clock.commitEnd(e));
        refreshFeeds();
    }

    function toClearing(uint64 e) internal {
        vm.warp(d.clock.revealEnd(e));
        refreshFeeds();
    }

    function toNextCommit() internal {
        vm.warp(d.clock.epochStart(epochNow() + 1));
        refreshFeeds();
    }

    function refreshFeeds() internal {
        feed.set(feed.answer());
        feed2.set(feed2.answer());
    }

    function nextSalt() internal returns (bytes32) {
        return keccak256(abi.encode("salt", ++saltNonce));
    }

    function commitLend(address who, uint32 bookId, uint256 amount, uint32 rate, bool rollover)
        internal
        returns (uint256 id, bytes32 salt)
    {
        salt = nextSalt();
        bytes32 h =
            d.auctionHouse.commitmentHash(who, bookId, epochNow(), AuctionHouse.Side.Lend, amount, 0, rate, salt);
        vm.prank(who);
        id = d.auctionHouse.commitLend(bookId, amount, h, rollover);
    }

    function commitBorrow(address who, uint32 bookId, uint256 amount, uint256 coll, uint32 rate, bool rollover)
        internal
        returns (uint256 id, bytes32 salt)
    {
        salt = nextSalt();
        bytes32 h =
            d.auctionHouse.commitmentHash(who, bookId, epochNow(), AuctionHouse.Side.Borrow, amount, coll, rate, salt);
        vm.prank(who);
        id = d.auctionHouse.commitBorrow(bookId, amount, coll, h, rollover);
    }

    function reveal(uint256 id, uint32 rate, bytes32 salt) internal {
        d.auctionHouse.reveal(id, rate, salt);
    }

    /// @dev One lender + one borrower matched in `bookId`; returns the repo id and series id. Ends in clearing phase.
    function openSimpleRepo(uint32 bookId, uint256 principal, uint256 coll, uint32 lendRate, uint32 borrowRate)
        internal
        returns (uint256 repoId, uint256 seriesId, uint256 lendId, uint256 borrowId)
    {
        uint64 e = epochNow();
        bytes32 s1;
        bytes32 s2;
        (lendId, s1) = commitLend(alice, bookId, principal, lendRate, false);
        (borrowId, s2) = commitBorrow(bob, bookId, principal, coll, borrowRate, false);
        toReveal(e);
        reveal(lendId, lendRate, s1);
        reveal(borrowId, borrowRate, s2);
        toClearing(e);
        AuctionHouse.AuctionResult memory r = d.auctionHouse.clear(bookId, e);
        seriesId = r.seriesId;
        repoId = d.auctionHouse.getOrder(borrowId).repoId;
        d.auctionHouse.settle(lendId);
        d.auctionHouse.settle(borrowId);
    }

    function repo(uint256 id) internal view returns (IRepoLocker.Repo memory) {
        return d.locker.getRepo(id);
    }

    function setPrice(int256 p) internal {
        feed.set(p);
    }
}
