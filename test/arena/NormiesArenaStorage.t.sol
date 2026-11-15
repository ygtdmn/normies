// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaTestBase } from "./ArenaTestBase.sol";
import { NormiesArenaStorage } from "../../src/NormiesArenaStorage.sol";

/// @notice The lazy accounting: who plays, what each Normie pays, and what it keeps.
contract NormiesArenaStorageTest is ArenaTestBase {
    uint8 constant UNREGISTERED = 0;
    uint8 constant ACTIVE = 1;
    uint8 constant SHORT = 2;
    uint8 constant CLEARED = 3;

    function testFreeRoundsAreForEveryRegisteredNormie() public {
        join(1, alice, 3);
        join(2, bob, 0);
        give(3, carol); // never registered
        next(0);
        assertEq(store.roundOf(1).players, 2);
        assertTrue(store.isPlayer(1));
        assertTrue(store.isPlayer(2));
        assertFalse(store.isPlayer(3));
        assertEq(store.balanceOf(1), 3);
        assertEq(store.roundOf(1).fees, 0);
    }

    function testPaidRoundChargesOnlyNormiesThatCoverThePrice() public {
        join(1, alice, 3);
        join(2, bob, 1);
        join(3, carol, 0);
        next(0);
        next(0);
        next(1); // round 3, price 1
        NormiesArenaStorage.Round memory r = store.roundOf(3);
        assertEq(r.players, 2);
        assertEq(r.fees, 2);
        assertEq(store.balanceOf(1), 2);
        assertEq(store.balanceOf(2), 0);
        assertEq(store.balanceOf(3), 0);
        assertEq(store.stateOf(2), ACTIVE); // paid its last pixel, still in until the next paid round
        assertEq(store.stateOf(3), SHORT);
        assertTrue(store.isPlayer(1) && store.isPlayer(2));
        assertFalse(store.isPlayer(3));
        assertEq(store.activeCount(), 2);
        assertBacked();
    }

    function testShortNormieKeepsLeftoverAndIgnoresAPriceDrop() public {
        join(1, alice, 3);
        next(0);
        next(0);
        next(1); // balance 2
        next(5); // cannot cover 5: sits out with 2
        assertEq(store.roundOf(4).players, 0);
        assertEq(store.balanceOf(1), 2);
        assertEq(store.stateOf(1), SHORT);
        next(1); // 2 would cover 1, but a price drop does not bring it back
        assertFalse(store.isPlayer(1));
        assertEq(store.balanceOf(1), 2);
        assertEq(store.roundOf(5).players, 0);
        topUp(1, 1); // back in from the next round
        assertEq(store.stateOf(1), ACTIVE);
        assertEq(store.balanceOf(1), 3);
        assertFalse(store.isPlayer(1)); // joined round 5 mid-way
        next(1);
        assertTrue(store.isPlayer(1));
        assertEq(store.balanceOf(1), 2);
        assertBacked();
    }

    function testDepositDuringAnOpenRoundWaitsForTheNext() public {
        join(1, alice, 5);
        next(0);
        next(0);
        next(2); // round 3
        join(2, bob, 5); // mid-round
        assertEq(store.balanceOf(2), 5);
        assertFalse(store.isPlayer(2));
        assertEq(store.roundOf(3).players, 1);
        assertEq(store.roundOf(3).fees, 2);
        next(2); // round 4
        assertTrue(store.isPlayer(2));
        assertEq(store.balanceOf(2), 3);
        assertEq(store.balanceOf(1), 1);
        assertBacked();
    }

    function testRefundsThenWinnersAndTheRestRollsForward() public {
        join(1, alice, 5);
        join(2, bob, 5);
        next(0);
        next(0);
        next(2); // round 3: 200 rolled from rounds 1 and 2, plus 4 in fees
        assertEq(store.poolOf(3), 204);
        vm.prank(operator);
        arena.endRound(3, ids1(1), ids1(150), ids1(2));
        assertEq(store.balanceOf(2), 5); // refunded its 2
        assertEq(store.balanceOf(1), 153);
        NormiesArenaStorage.Round memory r = store.roundOf(3);
        assertEq(r.paid, 152);
        assertEq(r.unpaid, 0);
        assertTrue(r.ended);
        assertEq(store.roundOf(4).sponsorship, 52);
        assertBacked();
    }

    function testPayoutCannotExceedThePool() public {
        join(1, alice, 5);
        next(0);
        vm.prank(operator);
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        arena.endRound(1, ids1(1), ids1(101), none);
        vm.prank(operator);
        arena.endRound(1, ids1(1), ids1(100), none);
        assertEq(store.balanceOf(1), 105);
        assertEq(store.roundOf(2).sponsorship, 100);
    }

    function testFreeRoundRefundsAndZeroAmountsAreSkipped() public {
        join(1, alice, 0);
        next(0);
        next(0);
        next(1); // drops: balance 0
        assertEq(store.stateOf(1), SHORT);
        uint256[] memory zero = ids1(0);
        vm.prank(operator);
        arena.endRound(3, ids1(1), zero, none); // a zero prize does not bring it back
        assertEq(store.stateOf(1), SHORT);
    }

    function testCreditToAShortNormieBringsItBack() public {
        join(1, alice, 1);
        next(0);
        next(0);
        next(5); // round 3: short with 1
        vm.prank(operator);
        arena.endRound(3, ids1(1), ids1(9), none);
        assertEq(store.stateOf(1), ACTIVE);
        assertEq(store.balanceOf(1), 10);
        next(5);
        assertTrue(store.isPlayer(1));
        assertEq(store.balanceOf(1), 5);
    }

    function testCreditToAnUnregisteredNormieWaitsForItsHolder() public {
        join(1, alice, 1);
        give(7, carol);
        next(0);
        uint256 registered = store.registeredCount();
        vm.prank(operator);
        arena.endRound(1, ids1(7), ids1(10), none);
        assertEq(store.balanceOf(7), 10);
        assertEq(store.stateOf(7), UNREGISTERED);
        assertFalse(store.isRegistered(7));
        assertEq(store.registeredCount(), registered);
        next(0);
        assertFalse(store.isPlayer(7));
        vm.prank(carol);
        queue.bindAgent(7, 7);
        vm.prank(carol);
        queue.join(7);
        assertEq(store.stateOf(7), ACTIVE);
        assertEq(store.balanceOf(7), 10);
        next(4);
        assertTrue(store.isPlayer(7));
        assertEq(store.balanceOf(7), 6);
        // The holder can also take it out before ever joining.
        give(8, carol);
        vm.prank(operator);
        arena.endRound(3, ids1(8), ids1(3), none);
        vm.prank(carol);
        store.withdraw(8, 3);
        assertEq(store.balanceOf(8), 0);
        assertBacked();
    }

    function testCancelRollsThePoolAndKeepsCharges() public {
        join(1, alice, 5);
        next(0);
        next(0);
        next(2);
        uint256 c = store.cumulative();
        vm.prank(operator);
        vm.expectRevert();
        arena.cancel(3);
        arena.setPaused(true);
        vm.prank(guardian);
        arena.cancel(3);
        assertTrue(store.roundOf(3).cancelled);
        assertEq(store.cumulative(), c);
        assertEq(store.balanceOf(1), 3);
        assertEq(store.roundOf(4).sponsorship, 202);
        assertBacked();
    }

    function testCancelAfterAPartialPayoutKeepsTheCredits() public {
        join(1, alice, 5);
        next(0);
        vm.prank(operator);
        arena.payout(1, ids1(1), ids1(30), none);
        arena.cancel(1);
        assertEq(store.balanceOf(1), 35);
        assertEq(store.roundOf(1).paid, 30);
        assertEq(store.roundOf(2).sponsorship, 170);
    }

    function testClearAndRescueABurnedNormie() public {
        join(1, alice, 5);
        join(2, bob, 1);
        next(0);
        next(0);
        next(1); // 1 has 4, 2 has 0
        next(1); // 2 drops
        assertEq(store.stateOf(2), SHORT);
        identity.burn(1);
        identity.burn(2);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Burned.selector);
        store.withdraw(1, 1);
        uint256 registered = store.registeredCount();
        uint256 active = store.activeCount();
        store.clear(1);
        store.clear(2);
        assertTrue(store.isPlayer(1)); // it played the round it was cleared in
        assertEq(store.stateOf(1), CLEARED);
        assertEq(store.balanceOf(1), 3);
        assertEq(store.registeredCount(), registered - 2);
        assertEq(store.activeCount(), active - 1);
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        store.clear(1);
        give(3, carol);
        vm.expectRevert(NormiesArenaStorage.NotBurned.selector);
        store.clear(3);
        next(1);
        assertEq(store.roundOf(5).players, 0);
        assertEq(store.balanceOf(1), 3); // frozen
        vm.prank(alice);
        vm.expectRevert();
        store.rescue(1, alice);
        store.rescue(1, treasury);
        assertEq(ledger.balanceOf(treasury), 3);
        assertEq(store.balanceOf(1), 0);
        assertBacked();
    }

    function testRescueClearsFirstAndRefusesLiveOrEmptyNormies() public {
        join(1, alice, 5);
        join(2, bob, 0);
        vm.expectRevert(NormiesArenaStorage.NotBurned.selector);
        store.rescue(1, treasury);
        identity.burn(1);
        identity.burn(2);
        store.rescue(1, treasury);
        assertEq(store.stateOf(1), CLEARED);
        assertEq(ledger.balanceOf(treasury), 5);
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        store.rescue(2, treasury);
        assertEq(store.registeredCount(), 1);
    }

    function testWithdrawDuringARoundCannotTakeItsCharge() public {
        join(1, alice, 5);
        next(0);
        next(0);
        next(2);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        store.withdraw(1, 4);
        vm.prank(alice);
        store.withdraw(1, 3);
        assertEq(store.balanceOf(1), 0);
        assertEq(store.stateOf(1), ACTIVE);
        next(2);
        assertEq(store.stateOf(1), SHORT);
        assertBacked();
    }

    function testWithdrawWhileShort() public {
        join(1, alice, 3);
        next(0);
        next(0);
        next(5);
        vm.prank(alice);
        store.withdraw(1, 2);
        assertEq(store.balanceOf(1), 1);
        assertEq(store.stateOf(1), SHORT);
        next(1);
        assertFalse(store.isPlayer(1));
        assertEq(store.balanceOf(1), 1);
        assertBacked();
    }

    function testLeftoverIsFoundAfterManyRounds() public {
        join(1, alice, 10);
        join(2, bob, 7);
        next(0);
        next(0);
        uint256[7] memory prices = [uint256(1), 0, 2, 0, 3, 1, 5];
        for (uint256 i; i < prices.length; ++i) {
            next(prices[i]);
        }
        // 1: 10 -> 9 -> 9 -> 7 -> 7 -> 4 -> 3, then 5 > 3: out with 3. 2: 7 -> 6 -> 6 -> 4 -> 4 -> 1, then 1 > 1? no:
        // pays 1 -> 0, then 5 > 0: out with 0.
        for (uint256 i; i < 40; ++i) {
            next(1);
        }
        assertEq(store.balanceOf(1), 3);
        assertEq(store.balanceOf(2), 0);
        assertEq(store.stateOf(1), SHORT);
        assertEq(store.normieOf(1).checkpoint, 0); // still lazy: nothing touched it
        vm.prank(alice);
        store.withdraw(1, 1);
        assertEq(store.balanceOf(1), 2);
        assertEq(store.normieOf(1).checkpoint, store.currentRound());
        assertBacked();
    }

    function testLevelsAcrossLaneSlots() public {
        // Levels 1..40 cross slot boundaries at 16 and 32.
        for (uint256 i = 1; i <= 40; ++i) {
            join(i, alice, i);
        }
        next(0);
        next(0);
        assertEq(store.countCovering(16), 25);
        assertEq(store.countCovering(17), 24);
        assertEq(store.countCovering(33), 8);
        next(17);
        assertEq(store.roundOf(3).players, 24);
        assertEq(store.countCovering(16), 8); // balances now 0..23 for ids 17..40
        next(16);
        assertEq(store.roundOf(4).players, 8);
        assertEq(store.balanceOf(40), 7);
        assertEq(store.balanceOf(20), 3); // 20 - 17 = 3 < 16: out with 3
        assertBacked();
    }

    function testMaxPrice() public {
        join(1, alice, 10_000);
        join(2, bob, 9999);
        next(0);
        next(0);
        next(1); // misalign C
        assertEq(arena.previewPlayers(), 2);
        arena.setEntryPrice(10_000);
        assertEq(arena.previewPlayers(), 0);
        topUp(1, 1);
        assertEq(arena.previewPlayers(), 1);
        next(10_000);
        assertEq(store.roundOf(4).players, 1);
        assertEq(store.balanceOf(1), 0);
        assertEq(store.balanceOf(2), 9998);
        assertBacked();
    }

    /// @dev The lazy balances, states and players match a plain charge loop over random rounds.
    function testFuzzMatchesAChargeLoop(uint256 seed) public {
        uint256 n = 24;
        uint256[] memory bal = new uint256[](n);
        bool[] memory short_ = new bool[](n);
        bool[] memory player = new bool[](n);
        for (uint256 i; i < n; ++i) {
            bal[i] = uint256(keccak256(abi.encode(seed, "bal", i))) % 60;
            join(i, alice, bal[i]);
        }
        for (uint256 round; round < 30; ++round) {
            uint256 rnd = uint256(keccak256(abi.encode(seed, round)));
            uint256 price = rnd % 4 == 0 ? 0 : 1 + (rnd >> 8) % 20;
            // Between rounds: a top-up or a withdraw on a random Normie.
            uint256 who = (rnd >> 32) % n;
            uint256 amount = 1 + (rnd >> 64) % 10;
            if ((rnd >> 96) % 2 == 0) {
                topUp(who, amount);
                bal[who] += amount;
                short_[who] = false;
            } else if (bal[who] >= amount) {
                vm.prank(alice);
                store.withdraw(who, amount);
                bal[who] -= amount;
            }
            next(price);
            uint256 players;
            for (uint256 i; i < n; ++i) {
                if (price == 0) {
                    player[i] = true;
                } else if (!short_[i] && bal[i] >= price) {
                    bal[i] -= price;
                    player[i] = true;
                } else {
                    short_[i] = true;
                    player[i] = false;
                }
                if (player[i]) ++players;
            }
            assertEq(store.roundOf(store.currentRound()).players, players);
            uint256 total;
            for (uint256 i; i < n; ++i) {
                assertEq(store.balanceOf(i), bal[i], "balance");
                assertEq(store.isPlayer(i), player[i], "player");
                assertEq(store.stateOf(i), short_[i] ? SHORT : ACTIVE, "state");
                total += bal[i];
            }
            assertEq(store.totalAllocated(), total);
            assertBacked();
        }
    }
}
