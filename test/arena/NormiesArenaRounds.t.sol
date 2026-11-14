// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaTestBase } from "./ArenaTestBase.sol";
import { NormiesArenaStorage } from "../../src/NormiesArenaStorage.sol";
import { NormiesArena } from "../../src/NormiesArena.sol";
import { ArenaAccess } from "../../src/arena/ArenaAccess.sol";
import { Ownable } from "solady/auth/Ownable.sol";

/// @notice Rounds: start, admission, sales, burns, settlement and cancellation.
contract NormiesArenaRoundsTest is ArenaTestBase {
    function testLifecycleFreeThenPaid() public {
        join(1, alice, 10);
        join(2, bob, 10);
        admitAll(1);
        assertEq(arena.players(1).length, 2);
        assertEq(store.balanceOf(1), 10);
        finishAndSettle(1, ids1(1));
        assertEq(store.balanceOf(1), 110);
        // Round 3 is paid at the entry price.
        admitAll(2);
        finishAndSettle(2, ids1(2));
        admitAll(3);
        assertEq(store.balanceOf(1), 109);
        assertEq(store.balanceOf(2), 109);
        assertEq(arena.poolOf(3), 2);
        assertBacked();
    }

    function testOnlyOwnerOrOperatorRunsRounds() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        arena.startRound(1);
        vm.prank(operator);
        arena.startRound(1);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        arena.admit(1, 1);
        vm.prank(operator);
        arena.finishRound(1);
        vm.prank(operator);
        arena.postResults(1, bytes32(uint256(1)));
        // The operator cannot settle.
        vm.prank(operator);
        vm.expectRevert(Ownable.Unauthorized.selector);
        arena.settle(1, bytes32(uint256(1)), new uint256[](0));
    }

    function testRoundsStartInOrder() public {
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        arena.startRound(2);
        arena.startRound(1);
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        arena.startRound(1);
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        arena.startRound(2);
        arena.finishRound(1);
        arena.startRound(2);
        assertEq(arena.currentRound(), 2);
    }

    /// @dev A fresh, unpaused Arena with no sponsorship on any round.
    function _unsponsored() private returns (NormiesArenaStorage s, NormiesArena a) {
        s = new NormiesArenaStorage(
            address(ledger), address(identity), address(identity), address(registry), address(registryV1), address(this)
        );
        a = new NormiesArena(address(s), address(this));
        s.setAuthorizedWriter(address(a), true);
        a.setPaused(false);
    }

    function testAFreeRoundWithoutSponsorshipCannotStart() public {
        (, NormiesArena a) = _unsponsored();
        vm.expectRevert(abi.encodeWithSelector(NormiesArena.FreeRoundNotSponsored.selector, 1));
        a.startRound(1);
        assertEq(a.currentRound(), 0);
    }

    function testASponsoredFreeRoundStarts() public {
        // setUp sponsored round 1 with 100.
        arena.startRound(1);
        assertTrue(store.roundOf(1).started);
        assertTrue(store.rulesOf(1).free);
        assertEq(arena.poolOf(1), 100);
    }

    function testAPaidRoundWithoutSponsorshipStarts() public {
        (NormiesArenaStorage s, NormiesArena a) = _unsponsored();
        a.setFreeRound(1, false);
        a.startRound(1);
        assertTrue(s.roundOf(1).started);
        assertEq(s.rulesOf(1).price, 1);
        assertEq(a.poolOf(1), 0);
    }

    function testReleasingAFreeRoundsWholeSponsorshipStopsItStarting() public {
        arena.releaseSponsorship(1, treasury, 40);
        arena.releaseSponsorship(1, treasury, 60);
        vm.expectRevert(abi.encodeWithSelector(NormiesArena.FreeRoundNotSponsored.selector, 1));
        arena.startRound(1);
        // Sponsoring it again lets it start.
        vm.prank(sponsorWallet);
        queue.sponsor(1, 1);
        arena.startRound(1);
        assertEq(arena.poolOf(1), 1);
        assertBacked();
    }

    function testALaterFreeRoundIsCheckedToo() public {
        arena.setFreeRound(3, true);
        openRound(2);
        arena.finishRound(2);
        vm.expectRevert(abi.encodeWithSelector(NormiesArena.FreeRoundNotSponsored.selector, 3));
        arena.startRound(3);
        // Marked paid, it starts without sponsorship.
        arena.setFreeRound(3, false);
        arena.startRound(3);
    }

    function testTicketCutoffIsTheLineAtStart() public {
        join(1, alice, 10);
        arena.startRound(1);
        join(2, bob, 10);
        admitAll(1);
        assertEq(arena.players(1).length, 1);
        assertTrue(inLine(2));
        admitAll(2);
        assertEq(arena.players(2).length, 2);
        // Normie 2 was in line first for round 2.
        assertEq(arena.players(2)[0], 2);
    }

    function testCapacityClosesAdmissions() public {
        arena.setCapacity(2);
        join(1, alice, 1);
        join(2, bob, 1);
        join(3, carol, 1);
        openRound(1);
        arena.admit(1, 50);
        assertTrue(store.roundOf(1).closed);
        assertEq(arena.players(1).length, 2);
        assertTrue(inLine(3));
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        arena.admit(1, 1);
    }

    /// @notice A sale mid-line: the Normie keeps its balance and ticket and plays; the new holder controls it and
    ///         the old wallet loses control.
    function testSaleMidLine() public {
        join(1, alice, 20);
        join(2, bob, 10);
        identity.setOwner(1, carol);
        assertEq(ticketOf(1), 1);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        store.withdraw(1, 1);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        queue.pause(1);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        queue.deposit(1, 1, false);
        admitAll(1);
        assertEq(arena.players(1)[0], 1);
        finishAndSettle(1, ids1(1));
        // The prize follows the NFT: the new holder takes it.
        vm.prank(carol);
        store.withdraw(1, 120);
        assertEq(ledger.balanceOf(carol), 100_120);
        assertEq(ledger.balanceOf(alice), 99_980);
        vm.prank(carol);
        queue.pause(1);
        assertFalse(inLine(1));
    }

    /// @notice The agent link is not checked at admission: a Normie whose binding moved still plays.
    function testBrokenAgentLinkStillPlays() public {
        join(1, alice, 10);
        identity.unbind(1);
        admitAll(1);
        assertEq(arena.players(1).length, 1);
        assertTrue(inLine(1));
    }

    function testBurnedNormieIsSkippedAndRescued() public {
        join(1, alice, 10);
        join(2, bob, 10);
        identity.burn(1);
        admitAll(1);
        assertEq(arena.players(1).length, 1);
        assertEq(arena.players(1)[0], 2);
        assertFalse(inLine(1));
        assertFalse(shortOfFunds(1));
        // Never plays again.
        admitAll(2);
        assertEq(arena.players(2).length, 1);
        store.rescue(1, carol);
        assertEq(ledger.balanceOf(carol), 100_010);
        assertBacked();
    }

    function testPrizeToABurnedNormieIsCreditedThenRescued() public {
        join(1, alice, 10);
        join(2, bob, 10);
        admitAll(1);
        arena.finishRound(1);
        identity.burn(1);
        finishAndSettle(1, ids1(1));
        assertEq(store.balanceOf(1), 110);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Burned.selector);
        store.withdraw(1, 1);
        store.rescue(1, treasury);
        assertEq(ledger.balanceOf(treasury), 110);
        assertEq(store.balanceOf(1), 0);
        assertBacked();
    }

    function testRefundToABurnedNormieIsCreditedThenRescued() public {
        arena.setFreeRound(1, false);
        arena.setEntryPrice(3);
        join(1, alice, 10);
        admitAll(1);
        identity.burn(1);
        arena.cancel(1);
        assertEq(store.balanceOf(1), 10);
        store.rescue(1, treasury);
        assertEq(ledger.balanceOf(treasury), 10);
    }

    function testWithdrawWhileInLineAndMidRound() public {
        arena.setFreeRound(2, false);
        arena.setEntryPrice(2);
        join(1, alice, 10);
        vm.prank(alice);
        store.withdraw(1, 5);
        assertTrue(inLine(1));
        admitAll(1);
        // Mid-round, all of it.
        vm.prank(alice);
        store.withdraw(1, 5);
        assertEq(store.balanceOf(1), 0);
        assertTrue(inLine(1));
        // Short at the next admission: leaves the line, marked short of funds.
        admitAll(2);
        assertEq(arena.players(2).length, 0);
        assertTrue(shortOfFunds(1));
        assertBacked();
    }

    function testSettlementSplitsFloorAndRemainderInRankOrder() public {
        arena.setWinnerBps(10_000);
        join(1, alice, 1);
        join(2, bob, 1);
        join(3, carol, 1);
        vm.prank(sponsorWallet);
        queue.sponsor(1, 1);
        admitAll(1);
        assertEq(arena.winnerCountOf(1), 3);
        // Pool 101 over 3 winners: 34, 34, 33 in list order.
        uint256[] memory w = new uint256[](3);
        w[0] = 3;
        w[1] = 1;
        w[2] = 2;
        finishAndSettle(1, w);
        assertEq(store.balanceOf(3), 35);
        assertEq(store.balanceOf(1), 35);
        assertEq(store.balanceOf(2), 34);
        assertEq(store.totalPooled(), 100);
        assertBacked();
    }

    function testSettleChecks() public {
        join(1, alice, 1);
        join(2, bob, 1);
        give(3, carol);
        admitAll(1);
        arena.finishRound(1);
        bytes32 h = keccak256("r");
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        arena.settle(1, h, ids1(1));
        arena.postResults(1, h);
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        arena.settle(1, keccak256("other"), ids1(1));
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        arena.settle(1, h, ids2(1, 2));
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        arena.settle(1, h, ids1(3));
        arena.settle(1, h, ids1(2));
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        arena.settle(1, h, ids1(2));
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        arena.postResults(1, h);
    }

    function testSettleRejectsRepeatedWinners() public {
        arena.setWinnerBps(10_000);
        join(1, alice, 1);
        join(2, bob, 1);
        admitAll(1);
        arena.finishRound(1);
        arena.postResults(1, keccak256("r"));
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        arena.settle(1, keccak256("r"), ids2(1, 1));
    }

    function testSettleIsPausedWithTheArena() public {
        join(1, alice, 1);
        admitAll(1);
        arena.finishRound(1);
        arena.postResults(1, keccak256("r"));
        arena.setPaused(true);
        vm.expectRevert(ArenaAccess.Paused.selector);
        arena.settle(1, keccak256("r"), ids1(1));
    }

    function testCancelRefundsToBalancesAndCarriesSponsorship() public {
        arena.setFreeRound(1, false);
        arena.setEntryPrice(3);
        join(1, alice, 10);
        join(2, bob, 10);
        admitAll(1);
        assertEq(store.balanceOf(1), 7);
        assertEq(arena.poolOf(1), 106);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        arena.cancel(1);
        vm.prank(guardian);
        arena.cancel(1);
        assertEq(store.balanceOf(1), 10);
        assertEq(store.balanceOf(2), 10);
        assertTrue(store.roundOf(1).cancelled);
        assertEq(store.roundOf(2).sponsorship, 200);
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        arena.cancel(1);
        assertBacked();
    }

    function testCancelFinishedRoundWhileNextIsOpenCarriesPastIt() public {
        join(1, alice, 10);
        admitAll(1);
        arena.finishRound(1);
        arena.startRound(2);
        arena.cancel(1);
        assertEq(store.roundOf(3).sponsorship, 100);
        assertEq(store.roundOf(2).sponsorship, 100);
        assertBacked();
    }

    function testCancelWorksWhilePaused() public {
        arena.startRound(1);
        arena.setPaused(true);
        arena.cancel(1);
        assertTrue(store.roundOf(1).cancelled);
        assertEq(store.roundOf(2).sponsorship, 200);
    }

    function testFinishWorksWhilePausedAndStartDoesNot() public {
        arena.startRound(1);
        arena.setPaused(true);
        arena.finishRound(1);
        vm.expectRevert(ArenaAccess.Paused.selector);
        arena.startRound(2);
    }

    function testReleaseSponsorshipOnlyBeforeStart() public {
        arena.releaseSponsorship(2, carol, 40);
        assertEq(ledger.balanceOf(carol), 100_040);
        arena.startRound(1);
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        arena.releaseSponsorship(1, carol, 1);
        vm.prank(operator);
        vm.expectRevert(Ownable.Unauthorized.selector);
        arena.releaseSponsorship(2, carol, 1);
    }

    function testInvalidateEnrollmentTakesOutOnlyTheObservedTicket() public {
        join(1, alice, 10);
        vm.prank(operator);
        arena.invalidateEnrollment(1, 5);
        assertTrue(inLine(1));
        vm.prank(operator);
        arena.invalidateEnrollment(1, 1);
        assertFalse(inLine(1));
        assertFalse(shortOfFunds(1));
    }

    function testSettingsBoundsAndFreeRoundLock() public {
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        arena.setCapacity(301);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        arena.setEntryPrice(0);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        arena.setWinnerBps(10_001);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        arena.setMaxScan(81);
        arena.startRound(1);
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        arena.setFreeRound(1, false);
        // A started round keeps its rules.
        arena.setCapacity(5);
        assertEq(arena.rulesOf(1).capacity, 200);
        assertEq(arena.rulesOf(2).capacity, 5);
    }

    /// @dev Round 1 paid at 5 with Normie 1 (alice, exactly 5 pixels) and Normie 2 (bob, 20), finished with results
    ///      posted; round 2, also paid, is open: Normie 2 plays it and Normie 1 is taken out short of funds.
    function _shortAfterRoundOne() private {
        arena.setFreeRound(1, false);
        arena.setFreeRound(2, false);
        arena.setEntryPrice(5);
        join(1, alice, 5);
        join(2, bob, 20);
        admitAll(1);
        arena.finishRound(1);
        arena.postResults(1, keccak256("r"));
        admitAll(2);
        assertEq(arena.players(2).length, 1);
        assertEq(store.balanceOf(1), 0);
        assertTrue(shortOfFunds(1));
        assertFalse(inLine(1));
    }

    function testAPrizeReturnsAShortNormieToTheBackOfTheLine() public {
        _shortAfterRoundOne();
        arena.settle(1, keccak256("r"), ids1(1));
        assertEq(store.balanceOf(1), 110);
        assertTrue(inLine(1));
        assertFalse(shortOfFunds(1));
        assertEq(ticketOf(1), store.tail());
        assertEq(store.tickets(ticketOf(1)), 1);
        assertBacked();
    }

    function testARefundReturnsAShortNormieToTheBackOfTheLine() public {
        _shortAfterRoundOne();
        uint64 before = ticketOf(2);
        arena.cancel(1);
        assertEq(store.balanceOf(1), 5);
        assertTrue(inLine(1));
        assertFalse(shortOfFunds(1));
        assertEq(ticketOf(1), store.tail());
        // Normie 2 is in line already: its refund leaves its ticket alone.
        assertEq(ticketOf(2), before);
        assertBacked();
    }

    function testAZeroCreditDoesNotReturnAShortNormie() public {
        // Round 3 free with a pool of 1 and every player a winner, round 4 paid at 5.
        arena.setFreeRound(3, true);
        arena.setWinnerBps(10_000);
        arena.setEntryPrice(5);
        vm.prank(sponsorWallet);
        queue.sponsor(3, 1);
        join(1, alice, 4);
        join(2, bob, 20);
        admitAll(1);
        admitAll(2);
        admitAll(3);
        arena.finishRound(3);
        arena.postResults(3, keccak256("r"));
        admitAll(4);
        assertTrue(shortOfFunds(1));
        // Normie 2 takes the 1 pixel; Normie 1 is credited 0 and stays out.
        arena.settle(3, keccak256("r"), ids2(2, 1));
        assertFalse(inLine(1));
        assertTrue(shortOfFunds(1));
        assertEq(store.balanceOf(1), 4);
    }

    function testANormiePausedByHandStaysOutAfterAPrizeOrARefund() public {
        arena.setFreeRound(1, false);
        arena.setEntryPrice(5);
        join(1, alice, 10);
        admitAll(1);
        vm.prank(alice);
        queue.pause(1);
        arena.finishRound(1);
        arena.postResults(1, keccak256("r"));
        uint256 snap = vm.snapshotState();
        arena.settle(1, keccak256("r"), ids1(1));
        assertFalse(inLine(1));
        assertEq(store.balanceOf(1), 110);
        assertTrue(vm.revertToState(snap));
        arena.cancel(1);
        assertFalse(inLine(1));
        assertEq(store.balanceOf(1), 10);
    }

    function testABurnedShortNormieStaysOutAfterAPrizeOrARefund() public {
        _shortAfterRoundOne();
        identity.burn(1);
        uint256 snap = vm.snapshotState();
        arena.settle(1, keccak256("r"), ids1(1));
        assertFalse(inLine(1));
        assertEq(store.balanceOf(1), 110);
        assertTrue(vm.revertToState(snap));
        arena.cancel(1);
        assertFalse(inLine(1));
        assertEq(store.balanceOf(1), 5);
    }

    /// @notice Worst case for settle and cancel: a full paid round of MAX_CAPACITY players, every one a winner, and
    ///         every one short of funds in the next round's admission, so each credit also returns it to the line.
    ///         Storage is cooled before each measured call so every slot is paid cold, as in its own transaction.
    function testFullRoundSettleAndCancelGas() public {
        arena.setCapacity(300);
        arena.setWinnerBps(10_000);
        arena.setMaxScan(80);
        arena.setFreeRound(1, false);
        arena.setFreeRound(2, false);
        for (uint256 i = 1; i <= 300; ++i) {
            address holder = address(uint160(0x10000 + i));
            ledger.mint(holder, 1);
            join(i, holder, 1);
        }
        admitAll(1);
        assertEq(arena.players(1).length, 300);
        arena.finishRound(1);
        arena.postResults(1, keccak256("r"));
        // Round 2 takes every one of them out of the line, short of funds.
        admitAll(2);
        assertEq(arena.players(2).length, 0);
        for (uint256 i = 1; i <= 300; ++i) {
            assertTrue(shortOfFunds(i));
        }
        uint256[] memory winners = arena.players(1);
        uint256 snap = vm.snapshotState();
        _cool();
        uint256 before = gasleft();
        arena.settle(1, keccak256("r"), winners);
        uint256 settleGas = before - gasleft();
        for (uint256 i = 1; i <= 300; ++i) {
            assertTrue(inLine(i));
        }
        assertTrue(vm.revertToState(snap));
        _cool();
        before = gasleft();
        arena.cancel(1);
        uint256 cancelGas = before - gasleft();
        for (uint256 i = 1; i <= 300; ++i) {
            assertTrue(inLine(i));
        }
        emit log_named_uint("settle 300 winners, all returning to the line", settleGas);
        emit log_named_uint("cancel 300 players, all returning to the line", cancelGas);
        assertLt(settleGas, 14_000_000);
        assertLt(cancelGas, 14_000_000);
    }

    /// @notice Worst admit call: maxScan at its highest, every ticket admitted to a paid round (charge, seat and a
    ///         new ticket each), storage cold.
    function testFullAdmitGas() public {
        arena.setCapacity(300);
        arena.setMaxScan(80);
        arena.setFreeRound(1, false);
        for (uint256 i = 1; i <= 80; ++i) {
            address holder = address(uint160(0x10000 + i));
            ledger.mint(holder, 2);
            join(i, holder, 2);
        }
        arena.startRound(1);
        _cool();
        uint256 before = gasleft();
        arena.admit(1, 80);
        uint256 used = before - gasleft();
        assertEq(arena.players(1).length, 80);
        emit log_named_uint("admit 80, all seated", used);
        assertLt(used, 14_000_000);
    }

    function _cool() private {
        vm.cool(address(store));
        vm.cool(address(arena));
        vm.cool(address(identity));
        vm.cool(address(ledger));
    }
}
