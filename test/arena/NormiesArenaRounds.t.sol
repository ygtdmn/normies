// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaTestBase } from "./ArenaTestBase.sol";
import { NormiesArena } from "../../src/NormiesArena.sol";
import { NormiesArenaStorage } from "../../src/NormiesArenaStorage.sol";
import { ArenaAccess } from "../../src/arena/ArenaAccess.sol";
import { Ownable } from "solady/auth/Ownable.sol";

/// @notice Round sequencing, roles, pause and limits on NormiesArena.
contract NormiesArenaRoundsTest is ArenaTestBase {
    function testRoundsRunInOrderAndOneAtATime() public {
        join(1, alice, 5);
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        arena.startRound(2);
        arena.startRound(1);
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        arena.startRound(1);
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        arena.startRound(2); // round 1 still open
        arena.endRound(1, none, none, none);
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        arena.endRound(1, none, none, none);
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        arena.cancel(1);
        arena.startRound(2);
        assertEq(store.currentRound(), 2);
    }

    function testFreeRoundNeedsAPool() public {
        next(0);
        next(0);
        arena.endRound(2, none, none, none); // rolls round 2's pool into round 3
        arena.setFreeRound(3, true);
        arena.startRound(3); // round 3 got rounds 1 and 2's pools
        arena.endRound(3, ids1(1), ids1(store.poolOf(3)), none);
        arena.setFreeRound(4, true);
        vm.expectRevert(abi.encodeWithSelector(NormiesArena.FreeRoundNotSponsored.selector, 4));
        arena.startRound(4);
        arena.setFreeRound(4, false);
        arena.startRound(4); // a paid round may start with nobody and no pool
        assertEq(store.roundOf(4).players, 0);
    }

    function testPriceIsFixedWhenTheRoundStarts() public {
        assertEq(arena.priceOf(1), 0);
        assertEq(arena.priceOf(3), 1);
        arena.setEntryPrice(7);
        assertEq(arena.priceOf(3), 7);
        next(0);
        next(0);
        next(7);
        arena.setEntryPrice(3);
        assertEq(arena.priceOf(3), 7);
        assertEq(store.roundOf(3).price, 7);
        assertEq(arena.priceOf(4), 3);
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        arena.setFreeRound(3, true);
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        arena.setFreeRound(0, true);
    }

    function testSettingBounds() public {
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        arena.setEntryPrice(0);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        arena.setEntryPrice(10_001);
        arena.setEntryPrice(10_000);
        vm.prank(operator);
        vm.expectRevert(Ownable.Unauthorized.selector);
        arena.setEntryPrice(2);
        vm.prank(operator);
        vm.expectRevert(Ownable.Unauthorized.selector);
        arena.setFreeRound(5, true);
    }

    function testRoles() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        arena.startRound(1);
        vm.prank(guardian);
        vm.expectRevert(Ownable.Unauthorized.selector);
        arena.startRound(1);
        vm.prank(operator);
        arena.startRound(1);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        arena.endRound(1, none, none, none);
        vm.prank(guardian);
        vm.expectRevert(Ownable.Unauthorized.selector);
        arena.payout(1, ids1(1), ids1(1), none);
        vm.prank(operator);
        vm.expectRevert(Ownable.Unauthorized.selector);
        arena.cancel(1);
        vm.prank(operator);
        vm.expectRevert(Ownable.Unauthorized.selector);
        arena.releaseSponsorship(5, alice, 1);
        vm.prank(guardian);
        arena.cancel(1);
        assertTrue(store.roundOf(1).cancelled);
    }

    function testPauseStopsStartsAndPayoutsButNotCancel() public {
        join(1, alice, 5);
        next(0);
        vm.prank(guardian);
        arena.setPaused(true);
        vm.prank(operator);
        vm.expectRevert(ArenaAccess.Paused.selector);
        arena.payout(1, ids1(1), ids1(1), none);
        vm.prank(operator);
        vm.expectRevert(ArenaAccess.Paused.selector);
        arena.endRound(1, none, none, none);
        vm.prank(guardian);
        arena.cancel(1);
        vm.prank(operator);
        vm.expectRevert(ArenaAccess.Paused.selector);
        arena.startRound(2);
        // Withdrawals never pause.
        vm.prank(alice);
        store.withdraw(1, 5);
    }

    function testPayoutListLimits() public {
        next(0);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        arena.payout(1, none, none, none);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        arena.payout(1, ids1(1), none, none);
        uint256 cap = arena.MAX_PAYOUT_ENTRIES();
        uint256[] memory many = new uint256[](cap);
        uint256[] memory amounts = new uint256[](cap);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        arena.endRound(1, many, amounts, ids1(1));
        for (uint256 i; i < cap; ++i) {
            many[i] = i;
        }
        amounts[0] = 50;
        arena.payout(1, many, amounts, none); // zeros are skipped
        assertEq(store.balanceOf(0), 50);
        arena.endRound(1, many, amounts, none);
        assertEq(store.balanceOf(0), 100);
        assertEq(store.roundOf(2).sponsorship, 100);
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        arena.payout(1, ids1(1), ids1(1), none); // ended
    }

    function testPayoutIsForTheOpenRoundOnly() public {
        next(0);
        arena.endRound(1, none, none, none);
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        arena.payout(1, ids1(1), ids1(1), none);
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        arena.payout(2, ids1(1), ids1(1), none);
    }

    function testReleaseOnlyFromRoundsNotStarted() public {
        next(0);
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        arena.releaseSponsorship(1, treasury, 1);
        arena.releaseSponsorship(2, treasury, 60);
        assertEq(ledger.balanceOf(treasury), 60);
        assertEq(store.poolOf(2), 40);
        arena.endRound(1, none, none, none); // rolls 100 into round 2
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        arena.releaseSponsorship(2, treasury, 141);
        arena.releaseSponsorship(2, treasury, 140); // rolled pixels are releasable too
        assertEq(store.poolOf(2), 0);
        assertBacked();
    }

    function testSponsorshipForOpenAndFutureRoundsOnly() public {
        next(0);
        vm.startPrank(sponsorWallet);
        queue.sponsor(1, 5); // the open round
        queue.sponsor(9, 5);
        vm.stopPrank();
        assertEq(store.poolOf(1), 105);
        arena.endRound(1, none, none, none);
        vm.prank(sponsorWallet);
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        queue.sponsor(1, 5);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        queue.sponsor(3, 5);
        vm.prank(sponsorWallet);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        queue.sponsor(0, 5);
    }

    function testOnlyWritersReachTheStorage() public {
        vm.expectRevert(NormiesArenaStorage.NotAuthorized.selector);
        store.startRound(1, 0, true);
        vm.expectRevert(NormiesArenaStorage.NotAuthorized.selector);
        store.register(1);
        vm.expectRevert(NormiesArenaStorage.NotAuthorized.selector);
        store.payout(1, none, none, none);
        vm.expectRevert(NormiesArenaStorage.NotAuthorized.selector);
        store.importPurchases(1, 1);
        store.setAuthorizedWriter(address(arena), false);
        vm.expectRevert(NormiesArenaStorage.NotAuthorized.selector);
        arena.startRound(1);
    }

    function testPreviewPlayers() public {
        join(1, alice, 0);
        join(2, bob, 3);
        assertEq(arena.previewPlayers(), 2); // round 1 is free
        next(0);
        next(0);
        arena.endRound(2, none, none, none);
        assertEq(arena.previewPlayers(), 1); // round 3 at price 1
        arena.startRound(3);
        assertEq(store.roundOf(3).players, 1);
    }
}
