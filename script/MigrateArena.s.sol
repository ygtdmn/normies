// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script, console } from "forge-std/src/Script.sol";
import { NormiesArenaMigrator, ILegacyArenaStorage } from "../src/arena/NormiesArenaMigrator.sol";

/**
 * @title MigrateArena
 * @notice Runs the Arena v2 to v3 migration after Safe multisend A (see DeployArena): moveFunds, registerTickets in
 *         chunks until the whole v2 line is read, copyPurchases, finish. The broadcaster must be the migrator's owner
 *         or hold its OPERATOR_ROLE (8). Every value moved is read on chain; moveFunds and finish revert if a list
 *         below misses an id, so a stale list cannot lose anything.
 *
 *         Rehearse on a fork first (forge script without --broadcast, against an anvil fork with multisend A
 *         applied, or see test/arena/NormiesArenaMigrationFork.t.sol).
 *
 *         Environment:
 *           ARENA_MIGRATOR                the NormiesArenaMigrator
 *           ARENA_MIGRATION_BALANCE_IDS   comma separated, ascending: every Normie id in a v2 Deposited event
 *           ARENA_MIGRATION_PURCHASE_IDS  comma separated: every Normie id in a v2 SkinPurchased event
 *           ARENA_MIGRATION_LAST_ROUND    optional, highest v2 round with a pool (default 2)
 *           ARENA_MIGRATION_CHUNK         optional, tickets per registerTickets transaction (default 100, about 6.6M
 *                                         gas on mainnet; 250 measured 16.6M, too close to the 16,777,216 cap)
 */
contract MigrateArena is Script {
    function run() external {
        NormiesArenaMigrator migrator = NormiesArenaMigrator(vm.envAddress("ARENA_MIGRATOR"));
        uint256[] memory balanceIds = vm.envUint("ARENA_MIGRATION_BALANCE_IDS", ",");
        uint256[] memory purchaseIds = vm.envUint("ARENA_MIGRATION_PURCHASE_IDS", ",");
        uint256 lastRound = vm.envOr("ARENA_MIGRATION_LAST_ROUND", uint256(2));
        uint256 chunk = vm.envOr("ARENA_MIGRATION_CHUNK", uint256(100));
        ILegacyArenaStorage legacy = migrator.legacy();
        uint256 tail = legacy.tail();
        console.log("v2 tickets", tail);
        console.log("v2 allocated", legacy.totalAllocated());
        console.log("v2 pooled", legacy.totalPooled());
        console.log("v2 purchases", legacy.purchaseCount());

        vm.startBroadcast();
        if (!migrator.fundsMoved()) migrator.moveFunds(balanceIds, lastRound);
        uint256 next = migrator.nextTicket();
        while (next == 0 || next <= tail) {
            migrator.registerTickets(chunk);
            next = next == 0 ? 1 + chunk : next + chunk;
        }
        migrator.copyPurchases(purchaseIds);
        migrator.finish();
        vm.stopBroadcast();
    }
}
