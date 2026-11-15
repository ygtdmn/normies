// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaTestBase } from "./ArenaTestBase.sol";
import { NormiesArenaStorage } from "../../src/NormiesArenaStorage.sol";
import { NormiesArenaMigrator } from "../../src/arena/NormiesArenaMigrator.sol";
import { LegacyNormiesArenaStorage } from "./legacy/LegacyNormiesArenaStorage.sol";
import { LegacyNormiesArena } from "./legacy/LegacyNormiesArena.sol";
import { LegacyNormiesArenaQueue } from "./legacy/LegacyNormiesArenaQueue.sol";
import { LegacyNormiesArenaSkins } from "./legacy/LegacyNormiesArenaSkins.sol";
import { Ownable } from "solady/auth/Ownable.sol";

/// @notice The v2 to v3 migration against the frozen v2 contracts, from a state shaped like mainnet's: a line of
///         mostly zero-balance Normies with stale duplicate tickets, a few deposits (one with no ticket), all
///         sponsorship in round 1, skin purchases (one for a Normie outside the line) and a burned Normie in line.
contract NormiesArenaMigrationTest is ArenaTestBase {
    LegacyNormiesArenaStorage legacy;
    LegacyNormiesArena legacyArena;
    LegacyNormiesArenaQueue legacyQueue;
    LegacyNormiesArenaSkins legacySkins;
    NormiesArenaMigrator migrator;

    uint256 constant LINE = 40;
    uint256 constant LONER = 77; // a deposit with no ticket
    uint256 constant GIFTED = 88; // a skin bought for a Normie that never joined
    uint256 constant BURNED = 5;

    uint256[] balanceIds;
    uint256[] purchaseIds;
    uint256 legacyBalances;

    function sponsorsLaunchRounds() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        legacy = new LegacyNormiesArenaStorage(
            address(ledger), address(identity), address(identity), address(registry), address(registryV1), address(this)
        );
        legacyArena = new LegacyNormiesArena(address(legacy), address(this));
        legacyQueue = new LegacyNormiesArenaQueue(address(legacy), address(this));
        legacySkins = new LegacyNormiesArenaSkins(address(legacy), address(this), treasury);
        legacy.setAuthorizedWriter(address(legacyArena), true);
        legacy.setAuthorizedWriter(address(legacyQueue), true);
        legacy.setAuthorizedWriter(address(legacySkins), true);
        ledger.authorize(address(legacy));
        ledger.authorize(address(legacyQueue));
        ledger.authorize(address(legacySkins));
        legacyQueue.grantRoles(sponsorWallet, legacyQueue.SPONSOR_ROLE());
        legacyArena.setPaused(false);
        legacyQueue.setPaused(false);
        legacySkins.setPaused(false);
        vm.prank(sponsorWallet);
        legacyQueue.sponsor(1, 200);

        // The line: zero-balance joins, a few deposits, and pause/resume duplicates.
        for (uint256 i; i < LINE; ++i) {
            address who = [alice, bob, carol][i % 3];
            give(i, who);
            vm.prank(who);
            legacyQueue.bindAgent(i, i);
            vm.prank(who);
            if (i % 9 == 0) legacyQueue.deposit(i, 1 + i, true);
            else legacyQueue.resume(i);
        }
        for (uint256 i = 3; i < LINE; i += 7) {
            address who = identity.holders(i);
            vm.prank(who);
            legacyQueue.pause(i);
            vm.prank(who);
            legacyQueue.resume(i); // a second ticket; the first one is stale
        }
        vm.prank(bob);
        legacyQueue.pause(10); // left the line and stayed out: still registered by the migration
        vm.prank(identity.holders(18));
        legacy.withdraw(18, 4); // part of a balance withdrawn
        give(LONER, bob);
        vm.prank(bob);
        legacyQueue.bindAgent(LONER, LONER);
        vm.prank(bob);
        legacyQueue.deposit(LONER, 6, false);
        // 16 skin purchases.
        give(GIFTED, carol);
        uint256 skinPrice = legacySkins.price();
        for (uint256 i; i < 15; ++i) {
            vm.prank(alice);
            legacySkins.purchase(i % 4, skinPrice, alice);
        }
        vm.prank(alice);
        legacySkins.purchase(GIFTED, skinPrice, alice);
        identity.burn(BURNED);

        for (uint256 i; i < 100; ++i) {
            if (legacy.balanceOf(i) != 0) {
                balanceIds.push(i);
                legacyBalances += legacy.balanceOf(i);
            }
            if (legacy.purchased(i) != 0) purchaseIds.push(i);
        }
        assertEq(legacyBalances, legacy.totalAllocated());
        assertEq(legacy.purchaseCount(), 16);

        migrator = new NormiesArenaMigrator(address(legacy), address(store), address(this));
        migrator.grantRoles(operator, migrator.OPERATOR_ROLE());
    }

    /// @dev Multisend A: freeze v2 and authorize the migrator on both storages.
    function _freeze() internal {
        legacyArena.setPaused(true);
        legacyQueue.setPaused(true);
        legacySkins.setPaused(true);
        legacy.setAuthorizedWriter(address(legacyArena), false);
        legacy.setAuthorizedWriter(address(legacyQueue), false);
        legacy.setAuthorizedWriter(address(legacySkins), false);
        legacy.setAuthorizedWriter(address(migrator), true);
        store.setAuthorizedWriter(address(migrator), true);
    }

    function _migrate() internal {
        _freeze();
        vm.startPrank(operator);
        migrator.moveFunds(balanceIds, 2);
        while (migrator.nextTicket() <= legacy.tail()) {
            migrator.registerTickets(17);
        }
        migrator.copyPurchases(purchaseIds);
        migrator.finish();
        vm.stopPrank();
        // Multisend B.
        legacy.setAuthorizedWriter(address(migrator), false);
        store.setAuthorizedWriter(address(migrator), false);
    }

    function testMigratesEverything() public {
        uint256[] memory before = new uint256[](100);
        for (uint256 i; i < 100; ++i) {
            before[i] = legacy.balanceOf(i);
        }
        _migrate();
        // Pools and balances.
        assertEq(store.poolOf(1), 200);
        assertEq(store.poolOf(2), 0);
        assertEq(ledger.balanceOf(address(store)), 200 + legacyBalances);
        assertEq(store.totalAllocated(), legacyBalances);
        assertEq(store.totalPooled(), 200);
        for (uint256 i; i < 100; ++i) {
            assertEq(store.balanceOf(i), before[i]);
            assertEq(legacy.balanceOf(i), 0);
        }
        assertEq(legacy.totalAllocated(), 0);
        assertEq(legacy.totalPooled(), 0);
        // The line: every Normie with a ticket, once, burned ones skipped; links copied.
        uint256 expected;
        for (uint256 i; i < LINE; ++i) {
            if (i == BURNED) {
                assertFalse(store.isRegistered(i));
                continue;
            }
            assertTrue(store.isRegistered(i));
            assertTrue(store.agentBound(i));
            assertEq(store.agentOf(i), i);
            ++expected;
        }
        assertEq(store.registeredCount(), expected);
        assertTrue(store.isRegistered(10)); // paused in v2
        // A balance without a ticket arrives unregistered.
        assertFalse(store.isRegistered(LONER));
        assertEq(store.balanceOf(LONER), 6);
        assertEq(store.stateOf(LONER), 0);
        assertTrue(store.agentBound(LONER));
        // Purchases.
        assertEq(store.purchaseCount(), 16);
        for (uint256 i; i < 100; ++i) {
            assertEq(store.purchased(i), legacy.purchased(i));
        }
        assertEq(store.purchased(GIFTED), 1);
        // v2 afterwards: round 1 started and finished, nothing left in it.
        assertEq(legacy.currentRound(), 1);
        assertTrue(legacy.roundOf(1).finished);
        assertEq(legacy.roundOf(1).unpaid, 0);
        assertEq(legacy.roundOf(2).unpaid, 0);
        // The migrator is locked.
        vm.prank(operator);
        vm.expectRevert(NormiesArenaMigrator.InvalidState.selector);
        migrator.registerTickets(1);
        assertBacked();
    }

    function testPlaysAfterMigration() public {
        _migrate();
        uint256 registered = store.registeredCount();
        arena.startRound(1);
        assertEq(store.roundOf(1).players, registered);
        assertTrue(store.isPlayer(0));
        assertFalse(store.isPlayer(LONER));
        arena.endRound(1, ids1(0), ids1(50), none);
        sponsorNext();
        arena.startRound(2);
        arena.endRound(2, none, none, none);
        arena.startRound(3); // paid, price 1
        // Only the Normies that deposited in v2 can pay.
        uint256 payers;
        for (uint256 i; i < LINE; ++i) {
            if (store.isPlayer(i)) ++payers;
        }
        assertEq(store.roundOf(3).players, payers);
        assertTrue(store.isPlayer(0)); // won 50 in round 1
        assertTrue(store.isPlayer(9));
        assertFalse(store.isPlayer(1));
        // The loner joins and plays the next one with its migrated balance.
        vm.prank(bob);
        queue.join(LONER);
        arena.endRound(3, none, none, none);
        arena.startRound(4);
        assertTrue(store.isPlayer(LONER));
        assertEq(store.balanceOf(LONER), 5);
        assertBacked();
    }

    function sponsorNext() internal {
        uint256 round = store.currentRound() + 1;
        vm.prank(sponsorWallet);
        queue.sponsor(round, 10);
    }

    function testMoveFundsChecksTotals() public {
        _freeze();
        balanceIds.pop();
        vm.prank(operator);
        vm.expectRevert(NormiesArenaMigrator.Mismatch.selector);
        migrator.moveFunds(balanceIds, 2);
        vm.prank(operator);
        vm.expectRevert(NormiesArenaMigrator.InvalidInput.selector);
        migrator.moveFunds(ids2(9, 0), 2);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        migrator.moveFunds(balanceIds, 2);
    }

    function testFinishNeedsEverything() public {
        _freeze();
        vm.startPrank(operator);
        migrator.moveFunds(balanceIds, 2);
        vm.expectRevert(NormiesArenaMigrator.InvalidState.selector);
        migrator.moveFunds(balanceIds, 2);
        migrator.registerTickets(10);
        vm.expectRevert(NormiesArenaMigrator.InvalidState.selector);
        migrator.finish();
        migrator.registerTickets(1000);
        vm.expectRevert(NormiesArenaMigrator.Mismatch.selector);
        migrator.finish(); // purchases not copied
        migrator.copyPurchases(purchaseIds);
        migrator.finish();
        vm.stopPrank();
    }

    function testNeedsFrozenV2() public {
        // Without writer access on v2 nothing moves.
        store.setAuthorizedWriter(address(migrator), true);
        vm.prank(operator);
        vm.expectRevert(LegacyNormiesArenaStorage.NotAuthorized.selector);
        migrator.moveFunds(balanceIds, 2);
    }

    function testRegisterTicketsIsIdempotentAcrossChunks() public {
        _freeze();
        vm.startPrank(operator);
        migrator.registerTickets(1);
        migrator.registerTickets(3);
        migrator.registerTickets(500);
        vm.stopPrank();
        assertEq(migrator.nextTicket(), uint256(legacy.tail()) + 1);
        assertEq(store.registeredCount(), LINE - 1);
    }
}
