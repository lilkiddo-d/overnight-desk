// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

/// @notice Helper used by the local-fork scenario: prints the storage slot holding `balanceOf(holder)` for the real
///         USDG and TSLA contracts, so `anvil_setStorageAt` can fund test accounts on a fork.
contract BalanceSlotsForkTest is Test {
    using stdStorage for StdStorage;

    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;

    function test_fork_balanceSlots() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        try vm.createSelectFork(rpc) {}
        catch {
            vm.skip(true);
        }
        address holder = vm.envOr("SLOT_HOLDER", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));
        uint256 s1 = stdstore.target(USDG).sig("balanceOf(address)").with_key(holder).find();
        uint256 s2 = stdstore.target(TSLA).sig("balanceOf(address)").with_key(holder).find();
        console2.log("USDG slot");
        console2.logBytes32(bytes32(s1));
        console2.log("TSLA slot");
        console2.logBytes32(bytes32(s2));
    }
}
