// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaTestBase } from "./ArenaTestBase.sol";
import { NormiesArenaStorage } from "../../src/NormiesArenaStorage.sol";
import { Ownable } from "solady/auth/Ownable.sol";

/// @notice The storage on its own: writer gating, bookkeeping invariants, withdraw, rescue and sweep.
contract NormiesArenaStorageTest is ArenaTestBase {
    function testEveryWriterSetterIsWriterOnly() public {
        NormiesArenaStorage.Rules memory r;
        bytes[] memory calls = new bytes[](19);
        calls[0] = abi.encodeCall(store.addBalance, (1, alice, 1));
        calls[1] = abi.encodeCall(store.chargeEntry, (1, 1, 1));
        calls[2] = abi.encodeCall(store.creditFromPool, (1, ids1(1), ids1(1)));
        calls[3] = abi.encodeCall(store.addSponsorship, (1, alice, 1));
        calls[4] = abi.encodeCall(store.moveSponsorship, (1, 2, 1));
        calls[5] = abi.encodeCall(store.releaseSponsorship, (1, alice, 1));
        calls[6] = abi.encodeCall(store.recordPurchase, (1, alice, 5));
        calls[7] = abi.encodeCall(store.setRules, (1, r));
        calls[8] = abi.encodeCall(store.setStarted, (1));
        calls[9] = abi.encodeCall(store.addPlayer, (1, 1));
        calls[10] = abi.encodeCall(store.setClosed, (1));
        calls[11] = abi.encodeCall(store.setFinished, (1));
        calls[12] = abi.encodeCall(store.setResultHash, (1, bytes32(uint256(1))));
        calls[13] = abi.encodeCall(store.setSettled, (1));
        calls[14] = abi.encodeCall(store.setCancelled, (1, 2));
        calls[15] = abi.encodeCall(store.pushTicket, (1));
        calls[16] = abi.encodeCall(store.popTicket, (1));
        calls[17] = abi.encodeCall(store.deactivate, (1, false));
        calls[18] = abi.encodeCall(store.linkAgent, (1, 1));
        // The owner is not a writer either.
        address[2] memory callers = [alice, address(this)];
        for (uint256 c; c < 2; ++c) {
            for (uint256 i; i < calls.length; ++i) {
                vm.prank(callers[c]);
                (bool ok, bytes memory ret) = address(store).call(calls[i]);
                assertFalse(ok);
                assertEq(bytes4(ret), NormiesArenaStorage.NotAuthorized.selector);
            }
        }
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.NotAuthorized.selector);
        store.recordPurchase(1, alice, 5);
    }

    function testOwnerFunctionsAreOwnerOnly() public {
        vm.startPrank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        store.setAuthorizedWriter(alice, true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        store.setAdapter(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        store.sweep(alice, 1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        store.rescue(1, alice);
        vm.stopPrank();
    }

    /// @notice The storage holds no game rules: a writer can set rounds in any order, and the game functions of a
    ///         logic contract do not exist here.
    function testStorageHoldsNoGameLogic() public {
        store.setAuthorizedWriter(address(this), true);
        store.setStarted(7);
        assertEq(store.currentRound(), 7);
        store.setFinished(7);
        store.setSettled(7);
        assertTrue(store.roundOf(7).settled);
        string[8] memory gone = [
            "startRound(uint256)",
            "finishRound(uint256)",
            "admit(uint256,uint256)",
            "settle(uint256,bytes32,uint256[])",
            "cancel(uint256)",
            "settleRound(uint256,uint256[],uint256[])",
            "cancelRound(uint256)",
            "admitPlayer(uint256,uint256,address)"
        ];
        for (uint256 i; i < gone.length; ++i) {
            (bool ok,) = address(store).call(abi.encodeWithSignature(gone[i], 1, 1));
            assertFalse(ok);
        }
    }

    function testBackingIsCheckedOnEveryInflow() public {
        store.setAuthorizedWriter(address(this), true);
        vm.expectRevert(abi.encodeWithSelector(NormiesArenaStorage.BackingShortfall.selector, 200, 201));
        store.addBalance(1, alice, 1);
        vm.expectRevert(abi.encodeWithSelector(NormiesArenaStorage.BackingShortfall.selector, 200, 201));
        store.addSponsorship(3, alice, 1);
        ledger.mint(address(store), 2);
        store.addBalance(1, alice, 1);
        store.addSponsorship(3, alice, 1);
        assertBacked();
    }

    function testPoolBookkeeping() public {
        store.setAuthorizedWriter(address(this), true);
        ledger.mint(address(store), 10);
        store.addBalance(1, alice, 10);
        // Charging needs a started round and enough balance.
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        store.chargeEntry(1, 1, 1);
        store.setStarted(1);
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        store.chargeEntry(1, 1, 11);
        store.chargeEntry(1, 1, 4);
        assertEq(store.roundOf(1).unpaid, 104);
        // Credits cannot exceed the unpaid pool.
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        store.creditFromPool(1, ids1(2), ids1(105));
        store.creditFromPool(1, ids2(2, 3), ids2(50, 50));
        // Settled needs the whole pool paid.
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        store.setSettled(1);
        store.creditFromPool(1, ids1(2), ids1(4));
        store.setSettled(1);
        // A settled round's money is locked.
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        store.creditFromPool(1, ids1(2), ids1(0));
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        store.addSponsorship(1, alice, 1);
        assertEq(store.balanceOf(2), 54);
        assertEq(store.totalPooled(), 100);
        assertBacked();
    }

    function testSponsorshipMovesOnlyIntoRoundsNotStarted() public {
        store.setAuthorizedWriter(address(this), true);
        store.setStarted(1);
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        store.moveSponsorship(2, 1, 1);
        vm.expectRevert(NormiesArenaStorage.InvalidState.selector);
        store.moveSponsorship(1, 2, 101);
        store.moveSponsorship(1, 2, 100);
        assertEq(store.roundOf(1).unpaid, 0);
        assertEq(store.roundOf(1).sponsorship, 100);
        assertEq(store.roundOf(2).sponsorship, 200);
        assertEq(store.roundOf(2).unpaid, 200);
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        store.releaseSponsorship(2, alice, 201);
        store.releaseSponsorship(2, alice, 200);
        assertEq(ledger.balanceOf(alice), 100_200);
        assertBacked();
    }

    function testWithdrawPaysTheHolderAndNothingElse() public {
        join(1, alice, 30);
        vm.prank(bob);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        store.withdraw(1, 1);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        store.withdraw(1, 31);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        store.withdraw(1, 0);
        vm.prank(alice);
        store.withdraw(1, 10);
        assertEq(store.balanceOf(1), 20);
        assertEq(ledger.balanceOf(alice), 100_000 - 20);
        assertBacked();
    }

    function testDelegateWithdrawPaysTheVault() public {
        join(1, alice, 30);
        vm.prank(hot);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        store.withdraw(1, 5);
        registry.delegateERC721(hot, alice, address(identity), 1, true);
        uint256 hotBefore = ledger.balanceOf(hot);
        vm.prank(hot);
        store.withdraw(1, 5);
        assertEq(ledger.balanceOf(hot), hotBefore);
        assertEq(ledger.balanceOf(alice), 100_000 - 25);
        // A v1 delegation works the same way.
        registry.delegateERC721(hot, alice, address(identity), 1, false);
        registryV1.delegateForAll(carol, alice, true);
        vm.prank(carol);
        store.withdraw(1, 5);
        assertEq(ledger.balanceOf(alice), 100_000 - 20);
        assertEq(ledger.balanceOf(carol), 100_000);
    }

    function testWithdrawWorksWithEveryLogicPausedOrRevoked() public {
        join(1, alice, 30);
        arena.setPaused(true);
        queue.setPaused(true);
        skins.setPaused(true);
        store.setAuthorizedWriter(address(arena), false);
        store.setAuthorizedWriter(address(queue), false);
        store.setAuthorizedWriter(address(skins), false);
        vm.prank(alice);
        store.withdraw(1, 30);
        assertEq(store.balanceOf(1), 0);
    }

    function testWithdrawBatch() public {
        join(1, alice, 10);
        join(2, alice, 10);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        store.withdrawBatch(ids2(1, 2), ids1(1));
        vm.prank(alice);
        store.withdrawBatch(ids2(1, 2), ids2(4, 10));
        assertEq(store.balanceOf(1), 6);
        assertEq(store.balanceOf(2), 0);
        // One failure reverts the batch.
        give(3, bob);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        store.withdrawBatch(ids2(1, 3), ids2(1, 1));
        assertEq(store.balanceOf(1), 6);
    }

    function testBurnedNormieCanOnlyBeRescuedByTheOwner() public {
        join(1, alice, 30);
        vm.expectRevert(NormiesArenaStorage.NotBurned.selector);
        store.rescue(1, carol);
        identity.burn(1);
        assertTrue(store.isBurned(1));
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Burned.selector);
        store.withdraw(1, 1);
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        store.rescue(1, address(0));
        store.rescue(1, carol);
        assertEq(store.balanceOf(1), 0);
        assertEq(ledger.balanceOf(carol), 100_030);
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        store.rescue(1, carol);
        assertBacked();
    }

    function testIsBurnedIsFalseOutOfRange() public view {
        assertFalse(store.isBurned(10_000));
        assertTrue(store.isBurned(9999));
    }

    function testSweepTakesOnlySurplus() public {
        join(1, alice, 10);
        ledger.mint(address(store), 3);
        assertEq(store.surplus(), 3);
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        store.sweep(carol, 4);
        store.sweep(carol, 3);
        assertEq(store.surplus(), 0);
        assertBacked();
    }

    function testAdapterIsOwnerSettable() public {
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        store.setAdapter(address(0));
        store.setAdapter(carol);
        assertEq(address(store.adapter()), carol);
    }

    function testConstructorRejectsZeroAddresses() public {
        address[6] memory a = [address(1), address(2), address(3), address(4), address(5), address(6)];
        for (uint256 i; i < 6; ++i) {
            address[6] memory b = a;
            b[i] = address(0);
            vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
            new NormiesArenaStorage(b[0], b[1], b[2], b[3], b[4], b[5]);
        }
    }

    /// @notice games(round) returns sponsorship, fees and resultHash as its first three words, then the flags in
    ///         the order closed, settled, cancelled, started, finished, then ticketCutoff and unpaid.
    function testGamesGetterFieldOrder() public {
        join(1, alice, 1);
        admitAll(1);
        arena.finishRound(1);
        arena.postResults(1, bytes32(uint256(7)));
        (bool ok, bytes memory ret) = address(store).staticcall(abi.encodeWithSignature("games(uint256)", 1));
        assertTrue(ok);
        uint256[10] memory w = abi.decode(ret, (uint256[10]));
        assertEq(w[0], 100);
        assertEq(w[1], 0);
        assertEq(w[2], 7);
        assertEq(w[3], 1);
        assertEq(w[4], 0);
        assertEq(w[5], 0);
        assertEq(w[6], 1);
        assertEq(w[7], 1);
        assertEq(w[8], 1);
        assertEq(w[9], 100);
    }

    function testHolderForRejectsOutOfRange() public {
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        store.holderFor(10_000, alice);
    }

    /// @notice The packed line: ids at both ends of the range, across several 16-ticket slots, read back in order,
    ///         and nothing read outside head..tail.
    function testPackedLineAcrossSlotBoundaries() public {
        store.setAuthorizedWriter(address(this), true);
        uint256 count = 50;
        for (uint256 t = 1; t <= count; ++t) {
            store.pushTicket(_idFor(t));
        }
        assertEq(store.tail(), count);
        for (uint64 t = 1; t <= count; ++t) {
            assertEq(store.tickets(t), _idFor(t));
        }
        assertEq(store.tickets(0), 0);
        assertEq(store.tickets(uint64(count) + 1), 0);
        arena.startRound(1);
        // Take tickets 1 to 33, past two slot boundaries (16 and 32).
        for (uint64 t = 1; t <= 33; ++t) {
            (bool found, uint64 ticket, uint256 id) = store.popTicket(1);
            assertTrue(found);
            assertEq(ticket, t);
            assertEq(id, _idFor(t));
            assertEq(store.tickets(t), 0);
        }
        assertEq(store.head(), 34);
        // Tickets issued after the round started wait for the next round, and land in the slot already in use.
        store.pushTicket(9999);
        store.pushTicket(0);
        assertEq(store.tickets(51), 9999);
        assertEq(store.tickets(52), 0);
        assertEq(store.tickets(34), _idFor(34));
        for (uint64 t = 34; t <= count; ++t) {
            (bool found,, uint256 id) = store.popTicket(1);
            assertTrue(found);
            assertEq(id, _idFor(t));
        }
        (bool more,,) = store.popTicket(1);
        assertFalse(more);
        assertTrue(store.lineExhausted(1));
        // The next round takes the two later tickets, Normie #9999 then Normie #0.
        arena.finishRound(1);
        arena.startRound(2);
        (, uint64 t51, uint256 a) = store.popTicket(2);
        (, uint64 t52, uint256 b) = store.popTicket(2);
        assertEq(t51, 51);
        assertEq(a, 9999);
        assertEq(t52, 52);
        assertEq(b, 0);
        assertTrue(store.lineExhausted(2));
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        store.pushTicket(10_000);
    }

    /// @dev Ids that fill every bit of a 16-bit field and include both ends of the range.
    function _idFor(uint256 t) private pure returns (uint256) {
        if (t == 1) return 0;
        if (t == 16) return 9999;
        if (t == 17) return 8191;
        return (t * 997) % 10_000;
    }
}
