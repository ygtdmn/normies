// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaTestBase } from "./ArenaTestBase.sol";
import { NormiesArenaStorage } from "../../src/NormiesArenaStorage.sol";
import { ArenaAccess } from "../../src/arena/ArenaAccess.sol";
import { Ownable } from "solady/auth/Ownable.sol";

/// @notice Joining, top-ups and agent links on NormiesArenaQueue.
contract NormiesArenaQueueTest is ArenaTestBase {
    function testJoinNeedsTheHolderAndAMatchingAgentLink() public {
        give(1, alice);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        queue.join(1); // not linked yet
        vm.prank(bob);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        queue.bindAgent(1, 1);
        vm.prank(alice);
        queue.bindAgent(1, 1);
        vm.prank(bob);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        queue.join(1);
        vm.prank(alice);
        queue.join(1);
        assertTrue(store.isRegistered(1));
        assertEq(store.registeredCount(), 1);
        assertEq(store.balanceOf(1), 0);
    }

    function testJoiningTwiceReverts() public {
        join(1, alice, 0);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        queue.join(1);
    }

    function testABrokenAgentLinkBlocksJoinAndTopUp() public {
        join(1, alice, 5);
        identity.unbind(1); // the adapter reverts for an unbound agent
        vm.prank(alice);
        vm.expectRevert();
        queue.deposit(1, 1);
        identity.bind(1, 2); // bound elsewhere: the link no longer matches
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        queue.deposit(1, 1);
        // It still plays and can still withdraw.
        next(0);
        assertTrue(store.isPlayer(1));
        vm.prank(alice);
        store.withdraw(1, 5);
    }

    function testDepositRegistersAndMovesPixelsFromTheCaller() public {
        give(1, alice);
        vm.prank(alice);
        queue.bindAgent(1, 1);
        vm.prank(alice);
        queue.deposit(1, 7);
        assertTrue(store.isRegistered(1));
        assertEq(store.balanceOf(1), 7);
        assertEq(ledger.balanceOf(alice), 100_000 - 7);
        assertEq(ledger.balanceOf(address(queue)), 0);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        queue.deposit(1, 0);
        assertBacked();
    }

    function testDelegatesActForTheHolderAndWithdrawalsGoToTheHolder() public {
        give(1, alice);
        registry.delegateAll(hot, alice, true);
        vm.prank(hot);
        queue.bindAgent(1, 1);
        vm.prank(hot);
        queue.deposit(1, 9);
        assertEq(ledger.balanceOf(hot), 100_000 - 9);
        vm.prank(hot);
        store.withdraw(1, 4);
        assertEq(ledger.balanceOf(alice), 100_000 + 4);
    }

    function testBalanceFollowsTheNormie() public {
        join(1, alice, 9);
        identity.setOwner(1, bob);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        store.withdraw(1, 1);
        vm.prank(bob);
        store.withdraw(1, 9);
        assertEq(ledger.balanceOf(bob), 100_000 + 9);
    }

    function testBatches() public {
        uint256[] memory ids = ids3(1, 2, 3);
        uint256[] memory amounts = ids3(1, 2, 3);
        for (uint256 i = 1; i <= 3; ++i) {
            give(i, alice);
        }
        vm.prank(alice);
        queue.depositRegisteredBatch(ids, amounts, ids);
        assertEq(store.registeredCount(), 3);
        assertEq(store.balanceOf(3), 3);
        vm.prank(alice);
        queue.depositBatch(ids, amounts);
        assertEq(store.balanceOf(3), 6);
        for (uint256 i = 4; i <= 6; ++i) {
            give(i, bob);
        }
        uint256[] memory more = ids3(4, 5, 6);
        vm.prank(bob);
        queue.joinRegisteredBatch(more, more);
        assertEq(store.registeredCount(), 6);
        give(7, carol);
        vm.prank(carol);
        queue.bindAgent(7, 7);
        vm.prank(carol);
        queue.joinBatch(ids1(7));
        assertEq(store.registeredCount(), 7);
        queue.setMaxBatch(2);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        queue.depositBatch(ids, amounts);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        queue.joinBatch(new uint256[](0));
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        queue.setMaxBatch(51);
        // Withdraw several at once from the storage.
        vm.prank(alice);
        store.withdrawBatch(ids, amounts);
        assertEq(store.balanceOf(3), 3);
        assertBacked();
    }

    function testPauseStopsJoinsAndTopUpsOnly() public {
        join(1, alice, 5);
        give(2, alice);
        queue.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.Paused.selector);
        queue.deposit(1, 1);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.Paused.selector);
        queue.join(2);
        vm.prank(sponsorWallet);
        queue.sponsor(3, 1);
        vm.prank(alice);
        store.withdraw(1, 5);
    }

    function testBurnedNormiesCannotJoin() public {
        give(1, alice);
        vm.prank(alice);
        queue.bindAgent(1, 1);
        identity.burn(1);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Burned.selector);
        queue.join(1);
        identity.setOwner(2, address(0xdEaD));
        vm.prank(address(0xdEaD));
        vm.expectRevert(NormiesArenaStorage.Burned.selector);
        queue.deposit(2, 1);
    }

    function testOnlyOwnerSetsMaxBatch() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        queue.setMaxBatch(10);
    }
}
