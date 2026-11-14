// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaAuditBase } from "./ArenaAuditBase.sol";
import { NormiesArenaStorage } from "../../../src/NormiesArenaStorage.sol";
import { NormiesArena } from "../../../src/NormiesArena.sol";
import { NormiesCanvasStorageV2 } from "../../../src/NormiesCanvasStorageV2.sol";
import { ArenaAccess } from "../../../src/arena/ArenaAccess.sol";
import { Ownable } from "solady/auth/Ownable.sol";

/// @notice One test group per design decision (D1 to D7; D8 is in ArenaGas.t.sol). Real Normies collection and real
///         pixel ledger; delegate registries and adapter are audit models.
contract ArenaDecisionsTest is ArenaAuditBase {
    function setUp() public override {
        super.setUp();
        sponsorFreeRounds();
    }

    // ───────────── D1: storage = state, accessors, withdraw, owner rescue for burned ─────────────

    /// @notice The owner alone cannot reach a live Normie's balance: rescue needs a burned Normie, sweep only takes
    ///         surplus, and the owner is not a writer.
    function test_D1_ownerCannotReachALiveNormieBalance() public {
        join(1, alice, 50);
        vm.expectRevert(NormiesArenaStorage.NotBurned.selector);
        store.rescue(1, address(this));
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        store.sweep(address(this), 1);
        vm.expectRevert(NormiesArenaStorage.NotAuthorized.selector);
        store.chargeEntry(1, 1, 1);
        vm.expectRevert(NormiesArenaStorage.NotAuthorized.selector);
        store.releaseSponsorship(1, address(this), 1);
        assertEq(store.balanceOf(1), 50);
    }

    /// @notice rescue: owner only, burned only (real collection burn), whole balance, to the address given.
    function test_D1_rescueOnlyForBurnedOnlyOwner() public {
        join(1, alice, 50);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        store.rescue(1, alice);
        burnNormie(1);
        assertTrue(store.isBurned(1));
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Burned.selector);
        store.withdraw(1, 1);
        store.rescue(1, carol);
        assertEq(store.balanceOf(1), 0);
        assertEq(ledger.balanceOf(carol), 100_050);
        assertBacked();
    }

    /// @notice A rescue cannot be forced on a live Normie by starving the ownerOf call of gas: with any gas limit,
    ///         rescue of a live Normie either reverts NotBurned or runs out of gas, and the balance is untouched.
    function test_D1_rescueOfLiveNormieFailsAtEveryGasLimit() public {
        join(1, alice, 50);
        bytes memory data = abi.encodeCall(store.rescue, (1, address(this)));
        // Every gas value where the inner ownerOf call could be starved, then coarser steps up to 200,000.
        for (uint256 g = 1; g <= 45_000; g += (g < 20_000 ? 7 : 1)) {
            (bool ok,) = address(store).call{ gas: g }(data);
            assertFalse(ok);
        }
        for (uint256 g = 45_000; g <= 200_000; g += 101) {
            (bool ok,) = address(store).call{ gas: g }(data);
            assertFalse(ok);
        }
        assertEq(store.balanceOf(1), 50);
    }

    // ───────────── D2: pixels belong to the Normie; holder or delegate controls; withdraw pays the holder ─────────────

    function _delegate(uint256 kind, address to, address from, uint256 id, bool on) internal {
        if (kind == 0) regV2.delegateAll(to, from, on);
        if (kind == 1) regV2.delegateContract(to, from, address(normies), on);
        if (kind == 2) regV2.delegateERC721(to, from, address(normies), id, on);
        if (kind == 3) regV1.delegateForAll(to, from, on);
        if (kind == 4) regV1.delegateForContract(to, from, address(normies), on);
        if (kind == 5) regV1.delegateForToken(to, from, address(normies), id, on);
    }

    /// @notice For each delegation level (v2 wallet/contract/token, v1 wallet/contract/token): the delegate can top
    ///         up from its own wallet, join, pause and withdraw; the withdrawal lands in the holder's wallet.
    function test_D2_everyDelegationLevelControlsAndWithdrawPaysHolder() public {
        for (uint256 kind; kind < 6; ++kind) {
            uint256 id = 10 + kind;
            give(id, alice);
            vm.prank(alice);
            queue.bindAgent(id, id);
            vm.prank(hot);
            vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
            queue.deposit(id, 10, true);
            _delegate(kind, hot, alice, id, true);
            uint256 hotBefore = ledger.balanceOf(hot);
            uint256 aliceBefore = ledger.balanceOf(alice);
            vm.startPrank(hot);
            queue.deposit(id, 10, true);
            assertTrue(inLine(id));
            queue.pause(id);
            assertFalse(inLine(id));
            queue.resume(id);
            store.withdraw(id, 4);
            vm.stopPrank();
            assertEq(ledger.balanceOf(hot), hotBefore - 10, "delegate paid the top-up");
            assertEq(ledger.balanceOf(alice), aliceBefore + 4, "withdraw paid the holder");
            assertEq(store.balanceOf(id), 6);
            _delegate(kind, hot, alice, id, false);
            vm.prank(hot);
            vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
            store.withdraw(id, 1);
        }
        assertBacked();
    }

    /// @notice Scope: a contract-level delegation for another collection and a token-level delegation for another
    ///         token give nothing.
    function test_D2_wrongScopeDelegationsGiveNothing() public {
        join(1, alice, 10);
        give(2, alice);
        regV2.delegateContract(hot, alice, address(0xDEAD), true);
        regV1.delegateForContract(hot, alice, address(0xDEAD), true);
        regV2.delegateERC721(hot, alice, address(normies), 2, true);
        regV1.delegateForToken(hot, alice, address(normies), 2, true);
        vm.startPrank(hot);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        store.withdraw(1, 1);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        queue.pause(1);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        queue.deposit(1, 1, false);
        vm.stopPrank();
    }

    /// @notice After a sale the balance stays with the Normie: the old holder and its delegate lose control, the new
    ///         holder and its delegate gain it, and withdrawals pay the new holder.
    function test_D2_controlFollowsTheNft() public {
        join(1, alice, 30);
        regV2.delegateAll(hot, alice, true);
        transferNormie(1, bob);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        store.withdraw(1, 1);
        vm.prank(hot);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        store.withdraw(1, 1);
        regV1.delegateForAll(carol, bob, true);
        uint256 bobBefore = ledger.balanceOf(bob);
        uint256 carolBefore = ledger.balanceOf(carol);
        vm.prank(carol);
        store.withdraw(1, 30);
        assertEq(ledger.balanceOf(bob), bobBefore + 30);
        assertEq(ledger.balanceOf(carol), carolBefore);
    }

    /// @notice Fuzz: whoever calls withdraw, the only wallet whose ledger balance grows is the holder's.
    function testFuzz_D2_withdrawAlwaysPaysHolder(uint8 kind, uint96 deposit, uint96 amount, bool viaDelegate) public {
        deposit = uint96(bound(deposit, 1, 50_000));
        amount = uint96(bound(amount, 1, deposit));
        join(1, alice, deposit);
        address caller = alice;
        if (viaDelegate) {
            _delegate(kind % 6, hot, alice, 1, true);
            caller = hot;
        }
        uint256 holderBefore = ledger.balanceOf(alice);
        uint256 callerBefore = ledger.balanceOf(hot);
        vm.prank(caller);
        store.withdraw(1, amount);
        assertEq(ledger.balanceOf(alice), holderBefore + amount);
        assertEq(ledger.balanceOf(hot), callerBefore);
        assertEq(store.balanceOf(1), deposit - amount);
        assertBacked();
    }

    // ───────────── D3: a holder change never drops a Normie; burned Normies don't play ─────────────

    /// @notice A sale while in the line and a sale while seated change nothing on chain: same ticket, same seat, same
    ///         balance, the Normie plays the next round too.
    function test_D3_holderChangeKeepsLineAndSeat() public {
        join(1, alice, 20);
        join(2, bob, 20);
        uint64 t = ticketOf(1);
        transferNormie(1, carol);
        assertTrue(inLine(1));
        assertEq(ticketOf(1), t);
        admitAll(1);
        assertTrue(store.played(1, 1));
        // Sold again while seated.
        transferNormie(1, hot);
        assertTrue(inLine(1));
        finishAndSettle(1, ids1(1));
        assertEq(store.balanceOf(1), 120);
        admitAll(2);
        assertTrue(store.played(2, 1));
        vm.prank(hot);
        store.withdraw(1, 120);
    }

    /// @notice A Normie burned on the real collection is never seated, cannot be topped up, resumed or returned to the
    ///         line by a prize or a refund.
    function test_D3_burnedNormieNeverPlays() public {
        arena.setFreeRound(2, false);
        arena.setEntryPrice(5);
        join(1, alice, 5);
        join(2, bob, 50);
        admitAll(1);
        burnNormie(1);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Burned.selector);
        queue.deposit(1, 1, false);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Burned.selector);
        queue.resume(1);
        arena.finishRound(1);
        arena.postResults(1, keccak256("r"));
        admitAll(2);
        assertFalse(store.played(2, 1));
        assertFalse(inLine(1));
        // A prize is credited to the burned Normie (design Q10) but does not return it to the line.
        arena.settle(1, keccak256("r"), ids1(1));
        assertEq(store.balanceOf(1), 105);
        assertFalse(inLine(1));
        admitAll(3);
        assertFalse(store.played(3, 1));
    }

    // ───────────── D4: charged at the seat; short leaves; top-up / prize / refund return it ─────────────

    /// @notice The entry price is charged exactly once, at the moment the Normie is seated, and it is the price
    ///         recorded for the round (default 1 pixel; zero in a free round). Nothing is taken on joining the line.
    function test_D4_onePixelChargedExactlyAtSeat() public {
        join(1, alice, 10);
        assertEq(store.balanceOf(1), 10, "joining charges nothing");
        admitAll(1);
        assertEq(store.balanceOf(1), 10, "free round charges nothing");
        finishAndSettle(1, ids1(1));
        admitAll(2);
        finishAndSettle(2, ids1(1));
        uint256 before = store.balanceOf(1);
        arena.startRound(3);
        assertEq(store.balanceOf(1), before, "starting a round charges nothing");
        assertEq(store.rulesOf(3).price, 1);
        arena.admit(3, 50);
        assertEq(store.balanceOf(1), before - 1, "one pixel at the seat");
        assertEq(store.roundOf(3).fees, 1);
        assertBacked();
    }

    function _shortInRoundTwo() internal {
        arena.setFreeRound(1, false);
        arena.setFreeRound(2, false);
        arena.setEntryPrice(5);
        join(1, alice, 5);
        join(2, bob, 20);
        admitAll(1);
        arena.finishRound(1);
        arena.postResults(1, keccak256("r"));
        admitAll(2);
        assertTrue(shortOfFunds(1));
        assertFalse(inLine(1));
    }

    function test_D4_shortLeaves_topUpReturnsToTheEnd() public {
        _shortInRoundTwo();
        join(3, carol, 20);
        vm.prank(alice);
        queue.deposit(1, 1, false);
        assertTrue(inLine(1));
        assertEq(ticketOf(1), store.tail(), "at the end");
        assertGt(ticketOf(1), ticketOf(3));
    }

    function test_D4_shortLeaves_prizeReturnsToTheEnd() public {
        _shortInRoundTwo();
        arena.settle(1, keccak256("r"), ids1(1));
        assertTrue(inLine(1));
        assertEq(ticketOf(1), store.tail());
    }

    function test_D4_shortLeaves_refundReturnsToTheEnd() public {
        _shortInRoundTwo();
        arena.cancel(1);
        assertTrue(inLine(1));
        assertEq(ticketOf(1), store.tail());
        assertEq(store.balanceOf(1), 5);
    }

    // ───────────── D5: skins gifted, paid from caller wallet or allowance, never from the Arena balance ─────────────

    function test_D5_skinsGiftWalletAllowance_neverArenaBalance() public {
        join(1, alice, 40);
        uint256 arenaBalance = store.balanceOf(1);
        uint256 storeLedger = ledger.balanceOf(address(store));
        // Gift from a stranger's wallet.
        vm.prank(bob);
        skins.purchase(1, 5, bob);
        // Holder's own wallet.
        vm.prank(alice);
        skins.purchase(1, 5, alice);
        // Allowance: carol pays, bob calls.
        vm.prank(carol);
        ledger.approve(bob, 5);
        vm.prank(bob);
        skins.purchase(1, 5, carol);
        assertEq(ledger.balanceOf(treasury), 15);
        assertEq(store.purchased(1), 3);
        assertEq(store.balanceOf(1), arenaBalance, "Arena balance untouched");
        assertEq(ledger.balanceOf(address(store)), storeLedger, "storage custody untouched");
    }

    /// @notice Naming the storage, the queue or the skins contract as payer cannot spend Arena custody: they gave no
    ///         allowance and have no way to give one.
    function test_D5_payerCannotBeArenaCustody() public {
        join(1, alice, 40);
        address[3] memory payers = [address(store), address(queue), address(skins)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(
                    NormiesCanvasStorageV2.InsufficientAllowance.selector, payers[i], alice, uint256(0), uint256(5)
                )
            );
            skins.purchase(1, 5, payers[i]);
        }
        // Nor a wallet that gave no allowance.
        vm.prank(alice);
        vm.expectRevert();
        skins.purchase(1, 5, bob);
        assertEq(ledger.balanceOf(address(store)), store.totalAllocated() + store.totalPooled());
    }

    // ───────────── D6: free rounds need sponsorship; no migration, no activate() ─────────────

    function test_D6_freeRoundNeedsSponsorshipAtTheMomentItStarts() public {
        // Round 1 is free and sponsored with 100. Release all of it: it cannot start.
        arena.releaseSponsorship(1, treasury, 100);
        vm.expectRevert(abi.encodeWithSelector(NormiesArena.FreeRoundNotSponsored.selector, 1));
        arena.startRound(1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NormiesArena.FreeRoundNotSponsored.selector, 1));
        arena.startRound(1);
        vm.prank(sponsorWallet);
        queue.sponsor(1, 1);
        arena.startRound(1);
        assertEq(store.roundOf(1).unpaid, 1);
    }

    /// @notice Fuzz: whatever rounds are marked free and whatever is sponsored or released, a started free round
    ///         always has a non-zero pool backed by pixels.
    function testFuzz_D6_startedFreeRoundAlwaysHasAPool(uint256 seed) public {
        for (uint256 round = 1; round <= 6; ++round) {
            seed = uint256(keccak256(abi.encode(seed)));
            if (round > 2) arena.setFreeRound(round, seed & 1 == 1);
            if (seed & 2 == 2 && store.roundOf(round).sponsorship > 0) {
                arena.releaseSponsorship(round, treasury, store.roundOf(round).sponsorship);
            }
            if (seed & 4 == 4) {
                vm.prank(sponsorWallet);
                queue.sponsor(round, 1 + (seed >> 8) % 50);
            }
            try arena.startRound(round) { }
            catch {
                arena.setFreeRound(round, false);
                arena.startRound(round);
            }
            NormiesArenaStorage.Round memory g = store.roundOf(round);
            NormiesArenaStorage.Rules memory r = store.rulesOf(round);
            if (r.free) {
                assertGt(g.sponsorship, 0);
                assertEq(g.unpaid, g.sponsorship);
                assertEq(r.price, 0);
            }
            // Cancel half of them so sponsorship carries forward into the next round.
            if (seed & 16 == 16) arena.cancel(round);
            else arena.finishRound(round);
            assertBacked();
        }
    }

    /// @notice No activate(), no setActivated(), no migration or legacy import entry point on any of the four.
    function test_D6_noActivateNoMigration() public {
        string[8] memory gone = [
            "activate()",
            "setActivated()",
            "activated()",
            "migrate()",
            "importLegacy(uint256[],uint256[])",
            "importLegacyBatch(uint256[],address[],uint256[])",
            "migrateBatch(uint256[])",
            "finalizeMigration()"
        ];
        address[4] memory targets = [address(store), address(arena), address(queue), address(skins)];
        for (uint256 t; t < 4; ++t) {
            for (uint256 i; i < gone.length; ++i) {
                (bool ok,) = targets[t].call(abi.encodeWithSignature(gone[i]));
                assertFalse(ok);
            }
        }
    }

    // ───────────── D7: floor(pool / n) each, remainder 1 each to the first winners ─────────────

    /// @notice Fuzz over player count, winner share, price and sponsorship: every winner's balance grows by
    ///         floor(pool / n), the first pool % n in the list get 1 more, the pool is paid out in full.
    function testFuzz_D7_settleSplit(uint8 playersSeed, uint16 bpsSeed, uint16 priceSeed, uint32 sponsorSeed) public {
        uint256 nPlayers = bound(playersSeed, 1, 40);
        uint256 bps = bound(bpsSeed, 1, 10_000);
        uint256 price = bound(priceSeed, 1, 500);
        uint256 extra = bound(sponsorSeed, 0, 90_000);
        arena.setFreeRound(1, false);
        arena.setWinnerBps(bps);
        arena.setEntryPrice(price);
        if (extra > 0) {
            vm.prank(sponsorWallet);
            queue.sponsor(1, extra);
        }
        for (uint256 i = 1; i <= nPlayers; ++i) {
            address holder = address(uint160(0x9000 + i));
            ledger.mintTo(holder, price);
            join(i, holder, price);
        }
        admitAll(1);
        arena.finishRound(1);
        uint256 n = arena.winnerCountOf(1);
        assertEq(n, (nPlayers * bps + 9999) / 10_000);
        uint256 pool = arena.poolOf(1);
        assertEq(pool, 100 + extra + nPlayers * price);
        // Winners: the last n players, in reverse admission order (so rank order differs from id order).
        uint256[] memory winners = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            winners[i] = nPlayers - i;
        }
        bytes32 h = keccak256("r");
        arena.postResults(1, h);
        arena.settle(1, h, winners);
        uint256 paid;
        for (uint256 i; i < n; ++i) {
            uint256 expected = pool / n + (i < pool % n ? 1 : 0);
            assertEq(store.balanceOf(winners[i]), expected);
            paid += expected;
        }
        assertEq(paid, pool);
        assertEq(store.roundOf(1).unpaid, 0);
        for (uint256 i = 1; i <= nPlayers - n; ++i) {
            assertEq(store.balanceOf(i), 0);
        }
        assertBacked();
    }

    /// @notice Settle rejects: wrong count, a non-player, a repeated winner, an out-of-range id, a second settle.
    function test_D7_settleRejectsBadWinnerLists() public {
        arena.setWinnerBps(5000);
        for (uint256 i = 1; i <= 4; ++i) {
            join(i, alice, 1);
        }
        give(9, bob);
        admitAll(1);
        arena.finishRound(1);
        bytes32 h = keccak256("r");
        arena.postResults(1, h);
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        arena.settle(1, h, ids1(1));
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        arena.settle(1, h, ids2(1, 1));
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        arena.settle(1, h, ids2(1, 9));
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        arena.settle(1, h, ids2(1, 10_000));
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        arena.settle(1, h, ids2(1, type(uint256).max));
        arena.settle(1, h, ids2(2, 1));
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        arena.settle(1, h, ids2(2, 1));
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        arena.cancel(1);
        assertEq(store.balanceOf(2), 51);
        assertEq(store.balanceOf(1), 51);
    }

    // ───────────── line packing ─────────────

    /// @notice Fuzz: any sequence of ids pushed to the packed line reads back in order, 16 to a slot, the latest
    ///         ticket of each id is its current one, and tickets are taken from the head in the order issued.
    function testFuzz_linePacking(uint256 seed, uint8 countSeed, uint8 takeSeed) public {
        store.setAuthorizedWriter(address(this), true);
        uint256 count = bound(countSeed, 1, 150);
        uint256[] memory pushed = new uint256[](count + 1);
        for (uint256 t = 1; t <= count; ++t) {
            seed = uint256(keccak256(abi.encode(seed)));
            // A mix of both ends of the range, repeats, and every bit pattern below 10,000.
            uint256 id = seed % 7 == 0 ? 9999 : seed % 11 == 0 ? 0 : (seed >> 16) % 10_000;
            pushed[t] = id;
            store.pushTicket(id);
            (uint64 ticket, bool active, bool needs) = store.enrollment(id);
            assertTrue(ticket == t && active && !needs);
        }
        assertEq(store.tail(), count);
        for (uint64 t = 1; t <= count; ++t) {
            assertEq(store.tickets(t), pushed[t]);
        }
        assertEq(store.tickets(0), 0);
        assertEq(store.tickets(uint64(count) + 1), 0);
        store.setStarted(1);
        uint256 take = bound(takeSeed, 0, count);
        for (uint64 t = 1; t <= take; ++t) {
            (bool found, uint64 ticket, uint256 id) = store.popTicket(1);
            assertTrue(found && ticket == t && id == pushed[t]);
            assertEq(store.tickets(t), 0, "a taken ticket reads as empty");
        }
        assertEq(store.head(), take + 1);
        // A ticket issued after the round started is not taken by that round.
        store.pushTicket(1234);
        for (uint256 k = take; k < count; ++k) {
            (bool found,,) = store.popTicket(1);
            assertTrue(found);
        }
        (bool more,,) = store.popTicket(1);
        assertFalse(more);
        assertEq(store.tickets(uint64(count) + 1), 1234);
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        store.pushTicket(10_000);
    }
}
