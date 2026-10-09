// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ProtocolDeployer} from "../../script/ProtocolDeployer.sol";
import {ITermRegistry} from "../../src/interfaces/ITermRegistry.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IRepoLocker} from "../../src/interfaces/IRepoLocker.sol";
import {OracleAdapter} from "../../src/oracle/OracleAdapter.sol";
import {AuctionHouse} from "../../src/core/AuctionHouse.sol";
import {MarginEngine} from "../../src/core/MarginEngine.sol";

/// @notice Fork tests against Robinhood Chain mainnet (chain id 4663) with the real USDG stablecoin, real stock tokens
///         and real Chainlink equity feeds. RPC: $ROBINHOOD_RPC_URL (defaults to the public endpoint).
///         Run: forge test --match-path test/fork/* -vv
contract RobinhoodForkTest is Test, ProtocolDeployer {
    // Sources: config/chains.ts and contracts/config/deploy.4663.json (all verified on-chain).
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address liquidatorBot = makeAddr("liquidatorBot");
    Deployment d;
    uint32 book7;
    int256 tslaAnswer;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        try vm.createSelectFork(rpc) {
            forked = true;
        } catch {
            return;
        }
        (, tslaAnswer,,,) = IAggregatorV3(TSLA_FEED).latestRoundData();

        address[] memory p = new address[](1);
        p[0] = address(this);
        d = _deployProtocol(
            CoreConfig({
                deployer: address(this),
                guardian: address(this),
                treasury: address(this),
                stablecoin: USDG,
                params: ITermRegistry.Params({
                    minOrderSize: 100e6,
                    maxRateBps: 5_000,
                    auctionFeeBpsPerYear: 25,
                    noRevealPenaltyBps: 100,
                    maxOrdersPerSide: 50,
                    marginCallGracePeriod: 4 hours,
                    maturityGracePeriod: 4 hours
                }),
                genesis: uint64(block.timestamp - 1 hours),
                interval: 1 days,
                commitWindow: 18 hours,
                revealWindow: 2 hours,
                clearWindow: 1 days,
                timelockDelay: 48 hours,
                proposers: p,
                executors: p,
                noteUri: ""
            })
        );
        d.registry.addTerm(1 days, "Overnight");
        d.registry.addTerm(7 days, "7D");
        ITermRegistry.CollateralConfig memory c = ITermRegistry.CollateralConfig({
            enabled: true,
            decimals: 0,
            initialHaircutBps: 3_500,
            maintenanceHaircutBps: 2_500,
            liquidationPenaltyBps: 500,
            maxCollateralPerAuction: 0
        });
        d.registry.configureCollateral(TSLA, c);
        d.registry.configureCollateral(AAPL, c);
        d.registry.addBook(0, TSLA);
        book7 = d.registry.addBook(1, TSLA);
        d.registry.addBook(1, AAPL);
        d.oracle.setFeed(TSLA, _feed(TSLA_FEED));
        d.oracle.setFeed(AAPL, _feed(AAPL_FEED));
        d.clock.setMarketHours(0, 1 days, 0x1F, false);
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
        }
        _;
    }

    function _feed(address f) internal pure returns (OracleAdapter.FeedConfig memory) {
        return OracleAdapter.FeedConfig({
            primary: f, secondary: address(0), maxStaleness: 26 hours, maxStalenessClosed: 3.5 days, maxDeviationBps: 0
        });
    }

    /// @dev Keep the real answer but mark it fresh after time travel.
    function _freshen(address feed, int256 answer) internal {
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), answer, block.timestamp, block.timestamp, uint80(1))
        );
    }

    function test_fork_chainAndAssets() public onlyFork {
        assertEq(block.chainid, 4663);
        assertEq(IERC20Metadata(USDG).decimals(), 6);
        assertEq(IERC20Metadata(USDG).symbol(), "USDG");
        assertEq(IERC20Metadata(TSLA).decimals(), 18);
        assertEq(IERC20Metadata(TSLA).symbol(), "TSLA");
        assertEq(IAggregatorV3(TSLA_FEED).decimals(), 8);
        (uint256 p,) = d.oracle.getPrice(TSLA);
        assertGt(p, 1e18); // > $1
        assertLt(p, 100_000e18);
        (uint256 pa,) = d.oracle.getPrice(AAPL);
        assertGt(pa, 1e18);
    }

    function _lend(uint64 e, uint256 amount, uint32 rate, bytes32 salt) internal returns (uint256 id) {
        bytes32 h = d.auctionHouse.commitmentHash(lender, book7, e, AuctionHouse.Side.Lend, amount, 0, rate, salt);
        vm.startPrank(lender);
        IERC20Metadata(USDG).approve(address(d.auctionHouse), type(uint256).max);
        id = d.auctionHouse.commitLend(book7, amount, h, false);
        vm.stopPrank();
    }

    function _borrow(uint64 e, uint256 amount, uint256 coll, uint32 rate, bytes32 salt) internal returns (uint256 id) {
        bytes32 h =
            d.auctionHouse.commitmentHash(borrower, book7, e, AuctionHouse.Side.Borrow, amount, coll, rate, salt);
        vm.startPrank(borrower);
        IERC20Metadata(TSLA).approve(address(d.auctionHouse), type(uint256).max);
        id = d.auctionHouse.commitBorrow(book7, amount, coll, h, false);
        vm.stopPrank();
    }

    /// @dev Commit, reveal and clear one lender + one borrower; returns (seriesId, repoId).
    function _match(uint256 principal, uint256 coll, uint32 lr, uint32 br) internal returns (uint256, uint256) {
        uint64 e = d.clock.currentEpoch();
        uint256 l = _lend(e, principal, lr, keccak256("s1"));
        uint256 b = _borrow(e, principal, coll, br, keccak256("s2"));
        vm.warp(d.clock.commitEnd(e));
        _freshen(TSLA_FEED, tslaAnswer);
        d.auctionHouse.reveal(l, lr, keccak256("s1"));
        d.auctionHouse.reveal(b, br, keccak256("s2"));
        vm.warp(d.clock.revealEnd(e));
        _freshen(TSLA_FEED, tslaAnswer);
        AuctionHouse.AuctionResult memory r = d.auctionHouse.clear(book7, e);
        assertEq(r.volume, principal);
        assertEq(r.clearingRateBps, (uint256(lr) + br) / 2);
        d.auctionHouse.settle(l);
        d.auctionHouse.settle(b);
        return (r.seriesId, d.auctionHouse.getOrder(b).repoId);
    }

    function test_fork_fullLifecycle_realTokens() public onlyFork {
        deal(USDG, lender, 1_000_000e6);
        deal(TSLA, borrower, 1_000e18);
        assertEq(IERC20Metadata(TSLA).balanceOf(borrower), 1_000e18);
        deal(USDG, liquidatorBot, 1_000_000e6);

        (uint256 price,) = d.oracle.getPrice(TSLA);
        uint256 coll = 100e18;
        // borrow 50% of the collateral value (initial limit is 65%)
        uint256 principal = (coll * price / 1e18) / 1e12 / 2;
        (uint256 seriesId, uint256 repoId) = _match(principal, coll, 450, 650);
        assertEq(d.note.balanceOf(lender, seriesId), principal);
        assertEq(IERC20Metadata(TSLA).balanceOf(address(d.locker)), coll);
        assertTrue(d.engine.isHealthy(repoId));

        // price gap: TSLA -50% => collateral no longer covers debt + penalty => immediate liquidation
        _freshen(TSLA_FEED, tslaAnswer * 50 / 100);
        assertEq(uint8(d.engine.poke(repoId)), uint8(MarginEngine.Action.Liquidated));
        uint256 aId = d.liquidator.auctionOfRepo(repoId);
        vm.startPrank(liquidatorBot);
        IERC20Metadata(USDG).approve(address(d.liquidator), type(uint256).max);
        d.liquidator.buy(aId, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();
        assertGt(IERC20Metadata(TSLA).balanceOf(liquidatorBot), 0);
        IRepoLocker.Series memory s = d.locker.getSeries(seriesId);
        assertEq(s.openRepos, 0);
        assertEq(uint8(d.locker.getRepo(repoId).status), uint8(IRepoLocker.RepoStatus.Closed));

        uint256 before = IERC20Metadata(USDG).balanceOf(lender);
        vm.prank(lender);
        d.locker.redeem(seriesId, principal);
        assertEq(IERC20Metadata(USDG).balanceOf(lender) - before, s.cash);
        assertGe(uint256(s.cash) + s.badDebt, principal);
    }

    function test_fork_repayReturnsRealCollateral() public onlyFork {
        deal(USDG, lender, 1_000_000e6);
        deal(USDG, borrower, 1_000_000e6);
        deal(TSLA, borrower, 1_000e18);
        (, uint256 repoId) = _match(1_000e6, 20e18, 300, 300);
        vm.warp(block.timestamp + 3 days);
        uint256 debt = d.locker.debtOf(repoId);
        assertGt(debt, 1_000e6);
        vm.startPrank(borrower);
        IERC20Metadata(USDG).approve(address(d.locker), type(uint256).max);
        uint256 t0 = IERC20Metadata(TSLA).balanceOf(borrower);
        d.locker.repay(repoId, type(uint256).max);
        vm.stopPrank();
        assertEq(IERC20Metadata(TSLA).balanceOf(borrower), t0 + 20e18);
    }
}
