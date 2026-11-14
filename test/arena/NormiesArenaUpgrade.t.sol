// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaTestBase } from "./ArenaTestBase.sol";
import { NormiesArenaStorage } from "../../src/NormiesArenaStorage.sol";
import { NormiesArena } from "../../src/NormiesArena.sol";
import { NormiesArenaQueue } from "../../src/NormiesArenaQueue.sol";

/// @notice Swapping a logic contract around the same storage.
contract NormiesArenaUpgradeTest is ArenaTestBase {
    function testArenaSwapMidRoundKeepsEverythingAndLocksOutTheOldLogic() public {
        join(1, alice, 10);
        join(2, bob, 10);
        join(3, carol, 10);
        arena.setMaxScan(2);
        openRound(1);
        arena.admit(1, 2);
        assertEq(arena.players(1).length, 2);
        // The new logic takes over with its own settings; the open round keeps its recorded rules.
        NormiesArena next = new NormiesArena(address(store), address(this));
        arena.setPaused(true);
        store.setAuthorizedWriter(address(next), true);
        store.setAuthorizedWriter(address(arena), false);
        next.setCapacity(1);
        next.setPaused(false);
        next.admit(1, 5);
        assertEq(next.players(1).length, 3);
        next.finishRound(1);
        next.postResults(1, keccak256("r"));
        next.settle(1, keccak256("r"), _one(3));
        assertEq(store.balanceOf(3), 110);
        // The old logic can no longer write, even unpaused.
        arena.setPaused(false);
        vm.expectRevert(NormiesArenaStorage.NotAuthorized.selector);
        arena.startRound(2);
        next.startRound(2);
        assertEq(store.currentRound(), 2);
        assertBacked();
    }

    function testQueueSwapKeepsBalancesAndTickets() public {
        join(1, alice, 10);
        NormiesArenaQueue next = new NormiesArenaQueue(address(store), address(this));
        store.setAuthorizedWriter(address(next), true);
        store.setAuthorizedWriter(address(queue), false);
        ledger.authorize(address(next));
        ledger.revoke(address(queue));
        next.setPaused(false);
        vm.prank(alice);
        next.deposit(1, 5, true);
        assertEq(store.balanceOf(1), 15);
        assertEq(ticketOf(1), 1);
        vm.prank(alice);
        vm.expectRevert();
        queue.deposit(1, 5, false);
    }

    function _one(uint256 id) private pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = id;
    }
}
