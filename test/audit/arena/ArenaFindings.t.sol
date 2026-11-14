// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaAuditBase } from "./ArenaAuditBase.sol";
import { NormiesArenaStorage } from "../../../src/NormiesArenaStorage.sol";
import { NormiesArena } from "../../../src/NormiesArena.sol";
import { NormiesArenaQueue } from "../../../src/NormiesArenaQueue.sol";
import { NormiesCanvasStorageV2 } from "../../../src/NormiesCanvasStorageV2.sol";
import { ArenaAccess } from "../../../src/arena/ArenaAccess.sol";

/// @notice A holder that is a contract with no way to use ledger pixels (a vault, an escrow, a marketplace).
contract InertVault { }

/// @notice PoCs for the findings in ARENA-AUDIT-REPORT.md. Real Normies collection and real pixel ledger; delegate
///         registries and adapter are audit models.
contract ArenaFindingsTest is ArenaAuditBase {
    event EnrollmentPaused(uint256 indexed id, bool needsFunds);

    function setUp() public override {
        super.setUp();
        sponsorFreeRounds();
    }

    // ───────────── L-01: stale tickets cost no pixels and the line has no bound ─────────────

    /// @notice One wallet with 50 Normies and no pixels at all fills the line with stale tickets by pausing and
    ///         resuming. A Normie that joins after it is seated only after the operator has scanned all of them.
    ///         Run with --isolate for the gas figures.
    function test_L01_staleTicketsPushALaterNormieBack() public {
        arena.setMaxScan(80);
        uint256[] memory ids = new uint256[](50);
        for (uint256 i; i < 50; ++i) {
            ids[i] = 5000 + i;
            give(ids[i], carol);
            vm.prank(carol);
            queue.bindAgent(ids[i], ids[i]);
        }
        uint256 carolPixels = ledger.balanceOf(carol);
        uint256 attackerGas;
        vm.startPrank(carol);
        queue.resumeBatch(ids);
        attackerGas += vm.lastCallGas().gasTotalUsed;
        uint256 cycleGas;
        for (uint256 k; k < 8; ++k) {
            queue.pauseBatch(ids);
            cycleGas = vm.lastCallGas().gasTotalUsed;
            queue.resumeBatch(ids);
            cycleGas += vm.lastCallGas().gasTotalUsed;
            attackerGas += cycleGas;
        }
        emit log_named_uint("attacker gas for one pauseBatch + resumeBatch cycle (50 stale tickets)", cycleGas);
        vm.stopPrank();
        assertEq(ledger.balanceOf(carol), carolPixels, "the attacker spent no pixels");
        assertEq(store.tail(), 450, "450 tickets, 400 of them stale");
        // A paying Normie joins behind them.
        join(1, alice, 10);
        assertEq(ticketOf(1), 451);
        arena.startRound(1);
        uint256 operatorGas;
        uint256 calls;
        while (!store.played(1, 1)) {
            vm.prank(operator);
            arena.admit(1, 80);
            operatorGas += vm.lastCallGas().gasTotalUsed;
            ++calls;
        }
        emit log_named_uint("admit calls before the paying Normie is seated (maxScan 80)", calls);
        emit log_named_uint("operator gas for those calls", operatorGas);
        emit log_named_uint("attacker gas for 450 tickets", attackerGas);
        assertEq(calls, 6);
    }

    /// @notice Joining the line needs no balance: a Normie with zero pixels takes a ticket, and in a paid round it
    ///         costs the operator one scan to take it out.
    function test_L01_joiningTheLineNeedsNoBalance() public {
        arena.setFreeRound(1, false);
        give(1, alice);
        vm.prank(alice);
        queue.bindAgent(1, 1);
        vm.prank(alice);
        queue.resume(1);
        assertTrue(inLine(1));
        assertEq(store.balanceOf(1), 0);
        arena.startRound(1);
        arena.admit(1, 1);
        assertFalse(inLine(1));
        assertTrue(shortOfFunds(1));
        // And again, as often as the holder likes.
        vm.prank(alice);
        queue.resume(1);
        assertTrue(inLine(1));
    }

    // ───────────── L-02: replacing NormiesArena resets every setting and free-round mark ─────────────

    function test_L02_replacingTheArenaResetsSettingsAndFreeRounds() public {
        arena.setCapacity(300);
        arena.setEntryPrice(7);
        arena.setWinnerBps(2500);
        arena.setFreeRound(3, true);
        vm.prank(sponsorWallet);
        queue.sponsor(3, 500);
        join(1, alice, 10);
        admitAll(1);
        finishAndSettle(1, ids1(1));
        admitAll(2);
        finishAndSettle(2, ids1(1));
        assertTrue(arena.rulesOf(3).free);
        assertEq(arena.rulesOf(3).price, 0);

        // The upgrade path from the existing suite: deploy, authorize, revoke, unpause.
        NormiesArena next = new NormiesArena(address(store), address(this));
        arena.setPaused(true);
        store.setAuthorizedWriter(address(next), true);
        store.setAuthorizedWriter(address(arena), false);
        next.setPaused(false);

        // Round 3 was announced free and is sponsored; under the new logic it is a paid round at the default price.
        NormiesArenaStorage.Rules memory r = next.rulesOf(3);
        assertFalse(r.free);
        assertEq(r.price, 1);
        assertEq(r.capacity, 200);
        assertEq(r.winnerBps, 1000);
        uint256 before = store.balanceOf(1);
        next.startRound(3);
        next.admit(3, 50);
        assertEq(store.balanceOf(1), before - 1, "charged in a round that was set free");
        assertFalse(store.rulesOf(3).free);
    }

    // ───────────── L-03: a paused or replaced logic contract keeps acting until its writer flag is revoked ─────────────

    function test_L03_pausedOldArenaStillWritesUntilRevoked() public {
        join(1, alice, 10);
        admitAll(1);
        // A new Arena takes over, the old one is paused, but its writer flag is not revoked yet.
        NormiesArena next = new NormiesArena(address(store), address(this));
        arena.setPaused(true);
        store.setAuthorizedWriter(address(next), true);
        next.setPaused(false);
        assertTrue(arena.paused());

        // Roles granted on the old contract still work through it: its operator finishes the open round, posts a
        // result and drops a Normie from the line; its guardian cancels the round.
        vm.startPrank(operator);
        arena.finishRound(1);
        arena.postResults(1, keccak256("old operator"));
        arena.invalidateEnrollment(1, ticketOf(1));
        vm.stopPrank();
        assertTrue(store.roundOf(1).finished);
        assertFalse(inLine(1));
        vm.prank(guardian);
        arena.cancel(1);
        assertTrue(store.roundOf(1).cancelled);
        // The old owner functions that are not pause-guarded work too.
        assertEq(store.roundOf(2).sponsorship, 200);
        arena.releaseSponsorship(2, treasury, 200);
        assertEq(ledger.balanceOf(treasury), 200);
    }

    // ───────────── I-01: an authorized writer has custody of every balance ─────────────

    /// @notice The owner authorizes any address as a writer; that writer moves a live Normie's balance into a pool,
    ///         re-labels it as sponsorship of a round that has not started and pays it out. rescue's "burned only"
    ///         limit binds the owner's own functions, not a writer the owner appoints.
    function test_I01_writerCanDrainALiveNormie() public {
        join(1, alice, 500);
        admitAll(1);
        address rogue = address(0xBADBAD);
        store.setAuthorizedWriter(rogue, true);
        vm.startPrank(rogue);
        store.chargeEntry(1, 1, 500);
        store.moveSponsorship(1, 9, 500);
        store.releaseSponsorship(9, rogue, 500);
        vm.stopPrank();
        assertEq(store.balanceOf(1), 0);
        assertEq(ledger.balanceOf(rogue), 500);
        assertFalse(store.isBurned(1));
    }

    // ───────────── L-04: a short Normie's top-up needs a matching agent link, with or without enroll ─────────────

    function test_L04_topUpOfAShortNormieRevertsWhenItsBindingMoved() public {
        arena.setFreeRound(1, false);
        arena.setEntryPrice(5);
        join(1, alice, 4);
        admitAll(1);
        assertTrue(shortOfFunds(1));
        // The agent's binding on the adapter moves away (re-registered, unbound, adapter replaced ...).
        adapter.unbind(1);
        // Both top-ups revert as a whole: no pixels in, not back in the line.
        vm.prank(alice);
        vm.expectRevert();
        queue.deposit(1, 10, true);
        vm.prank(alice);
        vm.expectRevert();
        queue.deposit(1, 10, false);
        assertEq(store.balanceOf(1), 4);
        assertFalse(inLine(1));
        assertTrue(shortOfFunds(1));
        // Once the binding points at the Normie again, the top-up without enroll returns it to the line.
        adapter.bind(1, 1);
        vm.prank(alice);
        queue.deposit(1, 10, false);
        assertTrue(inLine(1));
    }

    // ───────────── I-02: "burned" is "ownerOf reverts"; a missing id can be minted (again) ─────────────

    /// @notice On the real collection: a burned id minted again inherits the old balance, ticket and agent link, and
    ///         an id that was never minted reads as burned.
    function test_I02_remintedIdInheritsBalanceTicketAndLink() public {
        assertTrue(store.isBurned(4242), "never minted reads as burned");
        join(7, alice, 300);
        burnNormie(7);
        assertTrue(store.isBurned(7));
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Burned.selector);
        store.withdraw(7, 1);
        // The collection owner (or any minter it lists) mints id 7 again, to someone else.
        normies.mint(bob, 7);
        assertFalse(store.isBurned(7));
        // The team's rescue no longer applies ...
        vm.expectRevert(NormiesArenaStorage.NotBurned.selector);
        store.rescue(7, treasury);
        // ... the new token is still in the line with the old ticket and link, and is seated ...
        assertTrue(inLine(7));
        admitAll(1);
        assertTrue(store.played(1, 7));
        // ... and its holder takes the old balance.
        uint256 before = ledger.balanceOf(bob);
        vm.prank(bob);
        store.withdraw(7, 300);
        assertEq(ledger.balanceOf(bob), before + 300);
    }

    // ───────────── I-03: skin buyers restart the treasury's ledger cooldown ─────────────

    /// @notice Every skin purchase is an arrival that cools in the treasury wallet. Purchases less than a minute
    ///         apart keep all skin income since the last quiet minute locked. It costs the buyer the skin price each
    ///         time, which the treasury receives.
    function test_I03_skinPurchasesKeepTreasuryIncomeLocked() public {
        give(1, alice);
        for (uint256 i; i < 30; ++i) {
            vm.prank(bob);
            skins.purchase(1, 5, bob);
            vm.warp(block.timestamp + 59);
        }
        assertEq(ledger.balanceOf(treasury), 150);
        assertEq(ledger.availableBalance(treasury), 0, "half an hour of income, none of it usable");
        vm.warp(block.timestamp + 2);
        assertEq(ledger.availableBalance(treasury), 150);
    }

    // ───────────── I-04: withdrawals pay ownerOf even when that is a contract that cannot use pixels ─────────────

    function test_I04_delegateWithdrawStrandsPixelsInAContractHolder() public {
        join(1, alice, 200);
        InertVault vault = new InertVault();
        transferNormie(1, address(vault));
        // The vault has delegated the Normie back to its depositor, as lending and vault protocols do.
        regV2.delegateERC721(alice, address(vault), address(normies), 1, true);
        vm.prank(alice);
        store.withdraw(1, 200);
        assertEq(ledger.balanceOf(address(vault)), 200, "paid to the contract holder");
        assertEq(ledger.balanceOf(alice), 100_000 - 200);
        assertEq(store.balanceOf(1), 0);
    }

    /// @notice The balance is sold with the NFT, and the seller can take it out in the block before the sale.
    function test_I04_sellerWithdrawsJustBeforeTheSale() public {
        join(1, alice, 200);
        // The buyer saw a Normie with 200 pixels listed. The seller withdraws first, then the sale fills.
        vm.prank(alice);
        store.withdraw(1, 200);
        transferNormie(1, bob);
        assertEq(store.balanceOf(1), 0);
        assertTrue(inLine(1), "still in the line, with nothing to pay the next entry");
    }

    // ───────────── I-05: events and records an indexer must not take at face value ─────────────

    function test_I05_pauseEmitsForANormieNotInLineAndClearsTheShortMark() public {
        // (a) EnrollmentPaused for a Normie that was never in the line.
        give(2, bob);
        vm.expectEmit(true, false, false, true, address(store));
        emit EnrollmentPaused(2, false);
        vm.prank(bob);
        queue.pause(2);

        // (b) pause on a Normie that is out for lack of funds clears the mark, so a later prize or top-up no
        //     longer returns it to the line.
        arena.setFreeRound(1, false);
        arena.setFreeRound(2, false);
        arena.setEntryPrice(5);
        join(1, alice, 5);
        admitAll(1);
        arena.finishRound(1);
        arena.postResults(1, keccak256("r"));
        admitAll(2);
        assertTrue(shortOfFunds(1));
        vm.prank(alice);
        queue.pause(1);
        assertFalse(shortOfFunds(1));
        arena.settle(1, keccak256("r"), ids1(1));
        assertFalse(inLine(1), "a prize no longer returns it");
        vm.prank(alice);
        queue.deposit(1, 1, false);
        assertFalse(inLine(1), "nor does a top-up");

        // (c) a cancelled round still reports its old pool through poolOf, with nothing left in it.
        arena.cancel(2);
        assertEq(store.roundOf(2).unpaid, 0);
        assertEq(arena.poolOf(2), 100, "poolOf of a cancelled round is its history, not its content");
        assertEq(store.roundOf(3).sponsorship, 100);
    }

    // ───────────── I-06: the operator sets the pace of charges ─────────────

    /// @notice With no clock, the operator alone can run paid rounds back to back in one block. Each seat costs the
    ///         Normie its entry price; the pixels wait in the pools until the owner settles or cancels.
    function test_I06_operatorRunsPaidRoundsBackToBack() public {
        join(1, alice, 10);
        join(2, bob, 10);
        admitAll(1);
        arena.finishRound(1);
        arena.startRound(2);
        arena.admit(2, 50);
        arena.finishRound(2);
        vm.startPrank(operator);
        for (uint256 round = 3; round <= 12; ++round) {
            arena.startRound(round);
            arena.admit(round, 50);
            arena.finishRound(round);
        }
        vm.stopPrank();
        assertEq(store.balanceOf(1), 0);
        assertEq(store.balanceOf(2), 0);
        assertEq(store.totalPooled(), 200 + 20);
        // Only the owner (settle) or the owner / guardian (cancel) gives the pixels back.
        vm.prank(guardian);
        arena.cancel(12);
        assertEq(store.balanceOf(1), 1);
    }

    // ───────────── I-07: deployment order ─────────────

    /// @notice If the queue is a ledger mover and unpaused before the storage is a mover, deposits are accepted and
    ///         withdrawals revert until the ledger owner grants the storage its role.
    function test_I07_depositsAcceptedButWithdrawalsRevertUntilStorageIsAMover() public {
        ledger.setMoverRoles(address(store), 0);
        join(1, alice, 50);
        assertEq(store.balanceOf(1), 50);
        vm.prank(alice);
        vm.expectRevert(NormiesCanvasStorageV2.NotAuthorized.selector);
        store.withdraw(1, 50);
        ledger.setMoverRoles(address(store), ledger.ROLE_WRAPPER());
        vm.prank(alice);
        store.withdraw(1, 50);
    }

    // ───────────── L-05: only the holder or a delegate can re-point a Normie's agent link ─────────────

    /// @notice With two agents bound to the same Normie on the adapter (the real adapter allows it, see the fork
    ///         test), a stranger cannot choose which one the Arena records, on any of the three logic contracts,
    ///         paused or not. The holder can.
    function test_L05_strangerCannotFlipTheAgentLink() public {
        join(1, alice, 10);
        assertEq(store.agentOf(1), 1);
        adapter.bind(777, 1);
        address stranger = address(0xBEEF);
        vm.prank(stranger);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        queue.bindAgent(1, 777);
        skins.setPaused(true);
        vm.prank(stranger);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        skins.bindAgent(1, 777);
        vm.prank(stranger);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        arena.bindAgent(1, 777);
        assertEq(store.agentOf(1), 1);
        vm.prank(alice);
        queue.bindAgent(1, 777);
        assertEq(store.agentOf(1), 777);
        assertTrue(inLine(1));
    }

    /// @notice A new entry price applies to every Normie already in the line: it joined at 1, it is charged 10,000.
    function test_I06_priceChangeAppliesToNormiesAlreadyInLine() public {
        join(1, alice, 50_000);
        admitAll(1);
        arena.finishRound(1);
        arena.startRound(2);
        arena.admit(2, 50);
        arena.finishRound(2);
        assertEq(arena.entryPrice(), 1);
        arena.setEntryPrice(10_000);
        arena.startRound(3);
        arena.admit(3, 50);
        assertEq(store.balanceOf(1), 40_000);
    }

    // ───────────── I-09: nothing recovers a Normie, ETH or pixels held by an address that cannot act ─────────────

    /// @notice A Normie sent to the Arena storage with a plain transfer is stuck there, and so is its Arena
    ///         balance: the holder is the storage (which cannot call withdraw) and the Normie is not burned (so the
    ///         owner cannot rescue). A Normie sent to 0x...dEaD counts as burned, so the owner rescues its balance.
    function test_I09_normieSentToTheStorageIsStuckButOneSentToDeadIsRescued() public {
        join(1, alice, 300);
        transferNormie(1, address(store));
        assertEq(normies.ownerOf(1), address(store));
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        store.withdraw(1, 300);
        vm.expectRevert(NormiesArenaStorage.NotBurned.selector);
        store.rescue(1, alice);
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        store.sweep(alice, 300);
        assertEq(store.balanceOf(1), 300);

        join(2, bob, 100);
        transferNormie(2, address(0xdEaD));
        assertTrue(store.isBurned(2));
        uint256 before = ledger.balanceOf(bob);
        store.rescue(2, bob);
        assertEq(ledger.balanceOf(bob), before + 100);
        assertEq(store.balanceOf(2), 0);
    }

    /// @notice The inherited role and ownership functions are payable and the Arena contracts have no way to send
    ///         ETH out (the other Normies contracts inherit Lifebuoy for this).
    function test_I09_ethSentWithAnAdminCallIsStuck() public {
        vm.deal(address(this), 1 ether);
        arena.grantRoles{ value: 1 ether }(operator, 8);
        assertEq(address(arena).balance, 1 ether);
        (bool ok,) = address(arena).call(abi.encodeWithSignature("rescueETH(address,uint256)", address(this), 1 ether));
        assertFalse(ok);
        (ok,) = address(arena).call(abi.encodeWithSignature("withdraw()"));
        assertFalse(ok);
    }

    // ───────────── I-08: results hash and winners are not tied together on chain ─────────────

    /// @notice The contract checks that winners played and are distinct, and their number. Which players they are is
    ///         the owner's word: any subset of the right size settles against any posted hash.
    function test_I08_anySubsetOfTheRightSizeSettles() public {
        join(1, alice, 10);
        join(2, bob, 10);
        admitAll(1);
        arena.finishRound(1);
        vm.prank(operator);
        arena.postResults(1, keccak256("ranking that says Normie 1 won"));
        arena.settle(1, keccak256("ranking that says Normie 1 won"), ids1(2));
        assertEq(store.balanceOf(2), 110);
    }
}
