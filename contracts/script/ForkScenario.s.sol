// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AuctionHouse} from "../src/core/AuctionHouse.sol";
import {MarketClock} from "../src/core/MarketClock.sol";
import {RepoLocker} from "../src/core/RepoLocker.sol";
import {RepoNote} from "../src/core/RepoNote.sol";
import {NoteMarket} from "../src/periphery/NoteMarket.sol";
import {TermRegistry} from "../src/core/TermRegistry.sol";

/// @notice LOCAL FORK ONLY (chain 31337). Drives a realistic auction through the deployed protocol so the frontend
///         and keeper can be exercised end-to-end. Signs with anvil's unlocked dev accounts (`--unlocked`); no keys.
///         PHASE=commit | reveal | settle
contract ForkScenario is Script {
    address constant LENDER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // anvil dev account #1
    address constant LENDER2 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906; // anvil dev account #3
    address constant BORROWER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // anvil dev account #2
    uint32 constant TSLA_ON = 0; // books are created term-major per asset: TSLA => 0..3
    uint32 constant TSLA_7D = 1;
    uint32 constant TSLA_30D = 2;

    AuctionHouse ah;
    MarketClock clock;
    IERC20 usdg;
    IERC20 tsla;

    function run() external {
        require(block.chainid == 31337, "fork only");
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../deployments/31337.json"));
        ah = AuctionHouse(vm.parseJsonAddress(json, ".AuctionHouse"));
        clock = MarketClock(vm.parseJsonAddress(json, ".MarketClock"));
        usdg = IERC20(vm.parseJsonAddress(json, ".stablecoin"));
        tsla = IERC20(TermRegistry(vm.parseJsonAddress(json, ".TermRegistry")).getBook(TSLA_7D).collateral);
        string memory phase = vm.envString("PHASE");
        bytes32 p = keccak256(bytes(phase));
        if (p == keccak256("commit")) _commit();
        else if (p == keccak256("reveal")) _reveal();
        else if (p == keccak256("settle")) _settle(vm.parseJsonAddress(json, ".NoteMarket"), vm.parseJsonAddress(json, ".RepoNote"));
        else revert("PHASE?");
    }

    function _salt(address who, uint32 book, uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("fork-scenario", who, book, i));
    }

    struct L {
        address who;
        uint32 book;
        uint256 amount;
        uint32 rate;
    }

    struct B {
        address who;
        uint32 book;
        uint256 amount;
        uint256 coll;
        uint32 rate;
    }

    function _lends() internal pure returns (L[4] memory l) {
        l[0] = L(LENDER, TSLA_7D, 30_000e6, 450);
        l[1] = L(LENDER2, TSLA_7D, 20_000e6, 520);
        l[2] = L(LENDER, TSLA_ON, 25_000e6, 380);
        l[3] = L(LENDER2, TSLA_30D, 15_000e6, 500);
    }

    function _borrows() internal pure returns (B[3] memory b) {
        b[0] = B(BORROWER, TSLA_7D, 35_000e6, 160e18, 650);
        b[1] = B(BORROWER, TSLA_ON, 10_000e6, 50e18, 420);
        b[2] = B(BORROWER, TSLA_30D, 12_000e6, 60e18, 610);
    }

    function _commit() internal {
        uint64 e = clock.currentEpoch();
        L[4] memory l = _lends();
        B[3] memory b = _borrows();
        for (uint256 i; i < l.length; ++i) {
            bytes32 h = ah.commitmentHash(l[i].who, l[i].book, e, AuctionHouse.Side.Lend, l[i].amount, 0, l[i].rate, _salt(l[i].who, l[i].book, i));
            vm.startBroadcast(l[i].who);
            usdg.approve(address(ah), type(uint256).max);
            ah.commitLend(l[i].book, l[i].amount, h, i == 3);
            vm.stopBroadcast();
        }
        for (uint256 i; i < b.length; ++i) {
            bytes32 h = ah.commitmentHash(
                b[i].who, b[i].book, e, AuctionHouse.Side.Borrow, b[i].amount, b[i].coll, b[i].rate, _salt(b[i].who, b[i].book, 10 + i)
            );
            vm.startBroadcast(b[i].who);
            tsla.approve(address(ah), type(uint256).max);
            ah.commitBorrow(b[i].book, b[i].amount, b[i].coll, h, false);
            vm.stopBroadcast();
        }
        console2.log("committed in epoch", e);
    }

    function _reveal() internal {
        L[4] memory l = _lends();
        B[3] memory b = _borrows();
        for (uint256 i; i < l.length; ++i) {
            uint256 id = _find(l[i].who, l[i].book, AuctionHouse.Side.Lend);
            vm.broadcast(l[i].who);
            ah.reveal(id, l[i].rate, _salt(l[i].who, l[i].book, i));
        }
        for (uint256 i; i < b.length; ++i) {
            uint256 id = _find(b[i].who, b[i].book, AuctionHouse.Side.Borrow);
            vm.broadcast(b[i].who);
            ah.reveal(id, b[i].rate, _salt(b[i].who, b[i].book, 10 + i));
        }
        console2.log("revealed");
    }

    function _settle(address market, address noteAddr) internal {
        address[3] memory who = [LENDER, LENDER2, BORROWER];
        for (uint256 w; w < who.length; ++w) {
            uint256[] memory ids = ah.ordersOf(who[w]);
            for (uint256 i; i < ids.length; ++i) {
                if (ah.getOrder(ids[i]).state != AuctionHouse.State.Revealed) continue;
                vm.broadcast(who[w]);
                try ah.settle(ids[i]) {} catch {}
            }
        }
        // the lender lists part of their 7D notes on the secondary market
        uint256 series = ah.getResult(TSLA_7D, ah.getOrder(_firstOrder(LENDER, TSLA_7D)).epoch).seriesId;
        vm.startBroadcast(LENDER);
        RepoNote(noteAddr).setApprovalForAll(market, true);
        NoteMarket(market).list(series, 5_000e6, 0.998e18);
        vm.stopBroadcast();
        console2.log("settled; listed notes of series", series);
    }

    function _find(address who, uint32 book, AuctionHouse.Side side) internal view returns (uint256) {
        uint256[] memory ids = ah.ordersOf(who);
        for (uint256 i = ids.length; i > 0; --i) {
            AuctionHouse.Order memory o = ah.getOrder(ids[i - 1]);
            if (o.bookId == book && o.side == side && o.state == AuctionHouse.State.Committed) return ids[i - 1];
        }
        revert("order not found");
    }

    function _firstOrder(address who, uint32 book) internal view returns (uint256) {
        uint256[] memory ids = ah.ordersOf(who);
        for (uint256 i; i < ids.length; ++i) {
            if (ah.getOrder(ids[i]).bookId == book) return ids[i];
        }
        revert("none");
    }
}
