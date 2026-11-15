// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { NormiesCanvasStorageV2 } from "../../src/NormiesCanvasStorageV2.sol";
import { NormiesArenaStorage } from "../../src/NormiesArenaStorage.sol";
import { NormiesArenaQueue } from "../../src/NormiesArenaQueue.sol";
import { NormiesArena } from "../../src/NormiesArena.sol";
import { NormiesArenaSkins } from "../../src/NormiesArenaSkins.sol";
import { NormiesArenaMigrator } from "../../src/arena/NormiesArenaMigrator.sol";
import { LegacyNormiesArenaStorage } from "./legacy/LegacyNormiesArenaStorage.sol";
import { LegacyNormiesArena } from "./legacy/LegacyNormiesArena.sol";
import { LegacyNormiesArenaQueue } from "./legacy/LegacyNormiesArenaQueue.sol";
import { LegacyNormiesArenaSkins } from "./legacy/LegacyNormiesArenaSkins.sol";

/**
 * @notice Mainnet rehearsal of the cutover against the live v2 contracts: deploy v3, Safe multisend A, the migrator,
 *         Safe multisend B, then play two free rounds and a paid one. Opt in with ARENA_FORK_RPC_URL (optionally
 *         ARENA_FORK_BLOCK); skipped otherwise.
 *
 *         Ids with a v2 balance and ids with skin purchases come from the v2 Deposited and SkinPurchased events
 *         (ARENA_MIGRATION_BALANCE_IDS / ARENA_MIGRATION_PURCHASE_IDS, comma separated, sorted ascending), defaulting
 *         to the lists read on Nov 14 2026. moveFunds and finish check the totals, so a stale list fails loudly.
 */
contract NormiesArenaMigrationForkTest is Test {
    address constant SAFE = 0xAF8e9BDcF6463EA1f50f8f70ECF13d85a092a1Aa;
    address constant LEDGER = 0x96F2DA32Bb9D429d59ac13dB469f4950cBe02084;
    address constant COLLECTION = 0x9Eb6E2025B64f340691e424b7fe7022fFDE12438;
    address constant ADAPTER = 0xde152AfB7db5373F34876E1499fbD893A82dD336;
    address constant REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;
    address constant REGISTRY_V1 = 0x00000000000076A84feF008CDAbe6409d2FE638B;
    LegacyNormiesArenaStorage constant OLD_STORE =
        LegacyNormiesArenaStorage(0x980D97E7B77Cd204707daedA6C9E51FbcAE84E1e);
    LegacyNormiesArena constant OLD_ARENA = LegacyNormiesArena(0x6A80F157BFC981098132c344Ee4879f8E8CF1d22);
    LegacyNormiesArenaQueue constant OLD_QUEUE = LegacyNormiesArenaQueue(0xEAB672382b3d717F84352C0A63ae264C6A31b903);
    LegacyNormiesArenaSkins constant OLD_SKINS = LegacyNormiesArenaSkins(0xaF3060dBdb4E789163Babf4AFc3CE1ddAD82a0cB);

    NormiesCanvasStorageV2 ledger = NormiesCanvasStorageV2(LEDGER);
    NormiesArenaStorage store;
    NormiesArena arena;
    NormiesArenaQueue queue;
    NormiesArenaSkins skins;
    NormiesArenaMigrator migrator;
    address operator = address(0x0BE);
    uint256[] none;

    function _ids(string memory key, uint256[] memory fallback_) internal view returns (uint256[] memory) {
        return vm.envOr(key, ",", fallback_);
    }

    function testMainnetCutover() public {
        string memory url = vm.envOr("ARENA_FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("ARENA_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, forkBlock);
        assertEq(block.chainid, 1);

        uint256[] memory balanceIds = _ids(
            "ARENA_MIGRATION_BALANCE_IDS",
            _list13([uint256(559), 1160, 3705, 5407, 6414, 6515, 6988, 7024, 7764, 7902, 8374, 8572, 9579])
        );
        uint256[] memory purchaseIds = _ids(
            "ARENA_MIGRATION_PURCHASE_IDS",
            _list15([uint256(2), 306, 1807, 1969, 3325, 3392, 3908, 4354, 5085, 6760, 7597, 8043, 8528, 9197, 9579])
        );

        // Snapshot of v2 before.
        uint256 oldAllocated = OLD_STORE.totalAllocated();
        uint256 oldPooled = OLD_STORE.totalPooled();
        uint256 oldPurchases = OLD_STORE.purchaseCount();
        uint256 tail = OLD_STORE.tail();
        uint256[] memory oldBalances = new uint256[](balanceIds.length);
        for (uint256 i; i < balanceIds.length; ++i) {
            oldBalances[i] = OLD_STORE.balanceOf(balanceIds[i]);
        }
        emit log_named_uint("v2 tickets", tail);
        emit log_named_uint("v2 allocated", oldAllocated);
        emit log_named_uint("v2 pooled", oldPooled);

        // Deploy v3 (owned by the Safe) and the migrator.
        store = new NormiesArenaStorage(LEDGER, COLLECTION, ADAPTER, REGISTRY, REGISTRY_V1, SAFE);
        arena = new NormiesArena(address(store), SAFE);
        queue = new NormiesArenaQueue(address(store), SAFE);
        skins = new NormiesArenaSkins(address(store), SAFE, SAFE);
        migrator = new NormiesArenaMigrator(address(OLD_STORE), address(store), SAFE);

        // Safe multisend A.
        vm.startPrank(SAFE);
        OLD_ARENA.setPaused(true);
        OLD_QUEUE.setPaused(true);
        OLD_SKINS.setPaused(true);
        OLD_STORE.setAuthorizedWriter(address(OLD_ARENA), false);
        OLD_STORE.setAuthorizedWriter(address(OLD_QUEUE), false);
        OLD_STORE.setAuthorizedWriter(address(OLD_SKINS), false);
        OLD_STORE.setAuthorizedWriter(address(migrator), true);
        store.setAuthorizedWriter(address(migrator), true);
        ledger.setMoverRoles(address(store), 4);
        migrator.grantRoles(operator, migrator.OPERATOR_ROLE());
        vm.stopPrank();

        // The migration.
        vm.startPrank(operator);
        uint256 g = gasleft();
        migrator.moveFunds(balanceIds, 2);
        emit log_named_uint("moveFunds gas", g - gasleft());
        while (migrator.nextTicket() <= tail) {
            g = gasleft();
            migrator.registerTickets(250);
            emit log_named_uint("registerTickets(250) gas", g - gasleft());
        }
        migrator.copyPurchases(purchaseIds);
        migrator.finish();
        vm.stopPrank();

        // Safe multisend B.
        vm.startPrank(SAFE);
        OLD_STORE.setAuthorizedWriter(address(migrator), false);
        store.setAuthorizedWriter(address(migrator), false);
        store.setAuthorizedWriter(address(arena), true);
        store.setAuthorizedWriter(address(queue), true);
        store.setAuthorizedWriter(address(skins), true);
        ledger.setMoverRoles(address(queue), 4);
        ledger.setMoverRoles(address(skins), 4);
        ledger.setMoverRoles(address(OLD_QUEUE), 0);
        ledger.setMoverRoles(address(OLD_SKINS), 0);
        arena.grantRoles(operator, arena.OPERATOR_ROLE());
        arena.setPaused(false);
        queue.setPaused(false);
        skins.setPaused(false);
        vm.stopPrank();

        // Everything moved.
        assertEq(store.totalAllocated(), oldAllocated);
        assertEq(store.totalPooled(), oldPooled);
        assertEq(ledger.balanceOf(address(store)), oldAllocated + oldPooled);
        assertEq(OLD_STORE.totalAllocated(), 0);
        assertEq(OLD_STORE.totalPooled(), 0);
        for (uint256 i; i < balanceIds.length; ++i) {
            assertEq(store.balanceOf(balanceIds[i]), oldBalances[i]);
        }
        assertEq(store.purchaseCount(), oldPurchases);
        uint256 unique;
        for (uint64 t = 1; t <= tail; ++t) {
            uint256 id = OLD_STORE.tickets(t);
            bool burned = store.isBurned(id);
            assertEq(store.isRegistered(id), !burned);
            if (!burned) assertEq(store.agentOf(id), OLD_STORE.agentOf(id));
        }
        unique = store.registeredCount();
        emit log_named_uint("v3 registered", unique);

        // Play: two free rounds, then a paid one.
        vm.startPrank(operator);
        arena.startRound(1);
        assertEq(store.roundOf(1).players, unique);
        arena.endRound(1, none, none, none); // rolls the pool into round 2
        arena.startRound(2);
        arena.endRound(2, none, none, none);
        arena.startRound(3);
        vm.stopPrank();
        uint256 payers = store.roundOf(3).players;
        emit log_named_uint("round 3 paying players", payers);
        assertEq(store.roundOf(3).fees, payers);
        // A holder withdraws through the real ledger.
        for (uint256 i; i < balanceIds.length; ++i) {
            uint256 id = balanceIds[i];
            uint256 bal = store.balanceOf(id);
            if (bal == 0 || store.isBurned(id)) continue;
            address holder = store.holderFor(id, NormiesArenaStorage(address(store)).collection().ownerOf(id));
            uint256 before = ledger.balanceOf(holder);
            vm.prank(holder);
            store.withdraw(id, bal);
            assertEq(ledger.balanceOf(holder), before + bal);
            break;
        }
        assertEq(ledger.balanceOf(address(store)), uint256(store.totalAllocated()) + store.totalPooled());
    }

    function _list13(uint256[13] memory a) internal pure returns (uint256[] memory r) {
        r = new uint256[](13);
        for (uint256 i; i < 13; ++i) {
            r[i] = a[i];
        }
    }

    function _list15(uint256[15] memory a) internal pure returns (uint256[] memory r) {
        r = new uint256[](15);
        for (uint256 i; i < 15; ++i) {
            r[i] = a[i];
        }
    }
}
