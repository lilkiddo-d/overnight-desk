// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RepoNote} from "../../src/core/RepoNote.sol";
import {OvernightTimelock} from "../../src/periphery/OvernightTimelock.sol";

contract RepoNoteDirectTest is Test {
    RepoNote note;
    address minter = makeAddr("minter");
    address burner = makeAddr("burner");
    address user = makeAddr("user");

    function setUp() public {
        note = new RepoNote(address(this), "uri/{id}");
        note.grantRole(note.MINTER_ROLE(), minter);
        note.grantRole(note.BURNER_ROLE(), burner);
    }

    function test_metadataAndSupply() public {
        assertEq(note.name(), "Overnight Desk Repo Note");
        assertEq(note.symbol(), "ODRN");
        vm.prank(minter);
        note.mint(user, 7, 1_000);
        assertEq(note.totalSupply(7), 1_000);
        assertEq(note.balanceOf(user, 7), 1_000);
        vm.prank(burner);
        note.burn(user, 7, 400);
        assertEq(note.totalSupply(7), 600);
        vm.prank(user);
        note.safeTransferFrom(user, minter, 7, 100, "");
        assertEq(note.balanceOf(minter, 7), 100);
        note.setURI("ipfs://new/{id}");
        assertEq(note.uri(7), "ipfs://new/{id}");
    }
}

contract TimelockDirectTest is Test {
    function _arr(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function test_constructorFloor() public {
        vm.expectRevert(OvernightTimelock.DelayTooShort.selector);
        new OvernightTimelock(48 hours - 1, _arr(address(this)), _arr(address(this)));
        OvernightTimelock t = new OvernightTimelock(72 hours, _arr(address(this)), _arr(address(this)));
        assertEq(t.getMinDelay(), 72 hours);
        assertEq(t.MIN_DELAY_FLOOR(), 48 hours);
    }

    function test_delayCannotDropBelowFloor() public {
        OvernightTimelock t = new OvernightTimelock(48 hours, _arr(address(this)), _arr(address(this)));
        bytes memory upd = abi.encodeCall(t.updateDelay, (1));
        t.schedule(address(t), 0, upd, bytes32(0), bytes32(0), 48 hours);
        vm.warp(block.timestamp + 48 hours);
        t.execute(address(t), 0, upd, bytes32(0), bytes32(0));
        assertEq(t.getMinDelay(), 48 hours);
        vm.expectRevert();
        t.schedule(address(1), 0, "", bytes32(0), bytes32(0), 1 hours);
    }
}
