// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaTestBase } from "./ArenaTestBase.sol";
import { NormiesArenaStorage } from "../../src/NormiesArenaStorage.sol";
import { ArenaAccess } from "../../src/arena/ArenaAccess.sol";
import { Ownable } from "solady/auth/Ownable.sol";

/// @notice Top-ups, the line and sponsorship.
contract NormiesArenaQueueTest is ArenaTestBase {
    function testHolderTopsUpAndJoins() public {
        join(1, alice, 10);
        assertEq(store.balanceOf(1), 10);
        assertEq(ledger.balanceOf(alice), 99_990);
        assertTrue(inLine(1));
        assertEq(ticketOf(1), 1);
        assertBacked();
    }

    function testNoGifts() public {
        give(1, alice);
        vm.prank(alice);
        queue.bindAgent(1, 1);
        vm.prank(bob);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        queue.deposit(1, 10, false);
        vm.prank(bob);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        queue.resume(1);
    }

    function testDelegateTopsUpFromItsOwnWallet() public {
        give(1, alice);
        vm.prank(alice);
        queue.bindAgent(1, 1);
        registry.delegateContract(hot, alice, address(identity), true);
        vm.prank(hot);
        queue.deposit(1, 10, true);
        assertEq(ledger.balanceOf(hot), 99_990);
        assertEq(ledger.balanceOf(alice), 100_000);
        assertTrue(inLine(1));
        vm.prank(hot);
        queue.pause(1);
        assertFalse(inLine(1));
    }

    function testJoiningNeedsALinkedAgent() public {
        give(1, alice);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        queue.deposit(1, 10, true);
        // A top-up without joining works with no agent.
        vm.prank(alice);
        queue.deposit(1, 10, false);
        vm.prank(alice);
        queue.bindAgent(1, 1);
        // A link whose binding moved away no longer counts for joining.
        identity.bind(1, 2);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        queue.resume(1);
        identity.bind(1, 1);
        vm.prank(alice);
        queue.resume(1);
        assertTrue(inLine(1));
    }

    function testBindAgentChecksTheAdapter() public {
        give(1, alice);
        identity.bind(5, 2);
        vm.startPrank(alice);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        queue.bindAgent(1, 5);
        vm.expectRevert();
        queue.bindAgent(1, 6);
        queue.bindAgent(1, 1);
        vm.stopPrank();
        assertEq(store.agentOf(1), 1);
        assertTrue(store.agentBound(1));
    }

    function testOnlyTheHolderOrADelegateCanBind() public {
        give(1, alice);
        identity.bind(7, 1);
        // A stranger, the owner and the operator are refused.
        vm.prank(bob);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        queue.bindAgent(1, 1);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        queue.bindAgent(1, 1);
        vm.prank(operator);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        arena.bindAgent(1, 1);
        assertFalse(store.agentBound(1));
        // The holder.
        vm.prank(alice);
        queue.bindAgent(1, 1);
        assertEq(store.agentOf(1), 1);
        // A delegate.xyz v2 delegate (token level) and a v1 delegate (wallet level).
        registry.delegateERC721(hot, alice, address(identity), 1, true);
        vm.prank(hot);
        queue.bindAgent(1, 7);
        assertEq(store.agentOf(1), 7);
        registryV1.delegateForAll(carol, alice, true);
        vm.prank(carol);
        skins.bindAgent(1, 1);
        assertEq(store.agentOf(1), 1);
        // After a sale the former holder is refused and the new one can bind.
        identity.setOwner(1, bob);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        queue.bindAgent(1, 7);
        vm.prank(bob);
        queue.bindAgent(1, 7);
        assertEq(store.agentOf(1), 7);
        // A burned Normie cannot be bound.
        identity.burn(1);
        vm.prank(bob);
        vm.expectRevert(NormiesArenaStorage.Burned.selector);
        queue.bindAgent(1, 1);
    }

    function testRegisteredBatchesRefuseAStranger() public {
        give(1, alice);
        vm.prank(bob);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        queue.depositRegisteredBatch(ids1(1), ids1(5), ids1(1));
        vm.prank(bob);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        queue.resumeRegisteredBatch(ids1(1), ids1(1));
        assertFalse(store.agentBound(1));
    }

    function testTopUpKeepsTheTicket() public {
        join(1, alice, 10);
        join(2, bob, 10);
        vm.prank(alice);
        queue.deposit(1, 5, true);
        vm.prank(alice);
        queue.deposit(1, 5, false);
        assertEq(ticketOf(1), 1);
        assertEq(store.tail(), 2);
        assertEq(store.balanceOf(1), 20);
    }

    function testPauseDropsTheTicketAndResumeGoesToTheBack() public {
        join(1, alice, 10);
        join(2, bob, 10);
        vm.prank(alice);
        queue.pause(1);
        assertFalse(inLine(1));
        assertEq(store.balanceOf(1), 10);
        vm.prank(alice);
        queue.resume(1);
        assertEq(ticketOf(1), 3);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        queue.resume(1);
        admitAll(1);
        uint256[] memory seated = arena.players(1);
        assertEq(seated.length, 2);
        assertEq(seated[0], 2);
        assertEq(seated[1], 1);
    }

    function testPauseWorksWhilePausedAndDepositDoesNot() public {
        join(1, alice, 10);
        queue.setPaused(true);
        vm.prank(alice);
        queue.pause(1);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.Paused.selector);
        queue.deposit(1, 1, false);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.Paused.selector);
        queue.resume(1);
    }

    function testShortFundsLeaveAndATopUpReturnsToTheBack() public {
        arena.setFreeRound(2, false);
        arena.setEntryPrice(5);
        join(1, alice, 4);
        join(2, bob, 10);
        // Round 1 is free: both play.
        admitAll(1);
        assertEq(arena.players(1).length, 2);
        // Round 2 costs 5: Normie 1 has 4 and leaves, marked short of funds.
        admitAll(2);
        assertEq(arena.players(2).length, 1);
        assertFalse(inLine(1));
        assertTrue(shortOfFunds(1));
        // A top-up puts it back at the end.
        vm.prank(alice);
        queue.deposit(1, 1, false);
        assertTrue(inLine(1));
        assertFalse(shortOfFunds(1));
        assertEq(ticketOf(1), store.tail());
    }

    function testATopUpDoesNotReturnANormiePausedByHand() public {
        join(1, alice, 10);
        vm.prank(alice);
        queue.pause(1);
        vm.prank(alice);
        queue.deposit(1, 1, false);
        assertFalse(inLine(1));
        vm.prank(alice);
        queue.deposit(1, 1, true);
        assertTrue(inLine(1));
    }

    function testBatches() public {
        give(1, alice);
        give(2, alice);
        vm.prank(alice);
        queue.depositRegisteredBatch(ids2(1, 2), ids2(3, 4), ids2(1, 2));
        assertTrue(inLine(1) && inLine(2));
        assertEq(store.balanceOf(2), 4);
        vm.prank(alice);
        queue.pauseBatch(ids2(1, 2));
        assertFalse(inLine(1) || inLine(2));
        vm.prank(alice);
        queue.resumeBatch(ids2(1, 2));
        assertTrue(inLine(1) && inLine(2));
        vm.prank(alice);
        queue.pauseBatch(ids2(1, 2));
        vm.prank(alice);
        queue.resumeRegisteredBatch(ids2(1, 2), ids2(1, 2));
        vm.prank(alice);
        queue.depositBatch(ids2(1, 2), ids2(1, 1), false);
        assertEq(store.balanceOf(1), 4);
        queue.setMaxBatch(1);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        queue.depositBatch(ids2(1, 2), ids2(1, 1), false);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        queue.depositBatch(new uint256[](0), new uint256[](0), false);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        queue.setMaxBatch(51);
    }

    function testDepositRejectsZeroAndBurned() public {
        give(1, alice);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        queue.deposit(1, 0, false);
        identity.burn(1);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Burned.selector);
        queue.deposit(1, 1, false);
    }

    function testOnlyOwnerOrSponsorRoleSponsors() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        queue.sponsor(3, 1);
        vm.prank(sponsorWallet);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        queue.sponsor(0, 1);
        ledger.mint(address(this), 10);
        queue.sponsor(3, 10);
        assertEq(store.roundOf(3).sponsorship, 10);
        // Sponsoring works while paused.
        queue.setPaused(true);
        vm.prank(sponsorWallet);
        queue.sponsor(3, 5);
        assertEq(arena.poolOf(3), 15);
        assertBacked();
    }

    function testSponsorshipOfASettledRoundReverts() public {
        join(1, alice, 10);
        admitAll(1);
        finishAndSettle(1, ids1(1));
        vm.prank(sponsorWallet);
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        queue.sponsor(1, 1);
    }
}
