// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { NormiesArenaStorage } from "../src/NormiesArenaStorage.sol";
import { NormiesArenaQueue } from "../src/NormiesArenaQueue.sol";
import { NormiesArena } from "../src/NormiesArena.sol";
import { NormiesArenaSkins } from "../src/NormiesArenaSkins.sol";
import { NormiesArenaMigrator } from "../src/arena/NormiesArenaMigrator.sol";

/**
 * @title DeployArena
 * @notice Deploys the Arena v3 (lazy charging): NormiesArenaStorage, NormiesArena, NormiesArenaQueue,
 *         NormiesArenaSkins, and, when ARENA_LEGACY_STORAGE is set, the one-off NormiesArenaMigrator from the v2
 *         storage. All owned by ARENA_ADMIN. The logic contracts start paused and every setting at its default. The
 *         broadcaster grants nothing, and locks its own Lifebuoy rescue access (lockRescue(1)), so only ARENA_ADMIN
 *         can rescue tokens sent to them by mistake.
 *
 *         Fresh deployment, from ARENA_ADMIN:
 *           1. storage.setAuthorizedWriter for the arena, the queue and the skins
 *           2. on the pixel ledger, from its owner: setMoverRoles(storage | queue | skins, 4)
 *           3. queue.grantRoles(sponsor, 16), and sponsor rounds 1 and 2 (free rounds need a pool to start)
 *           4. arena.grantRoles(operator, 8), and GUARDIAN_ROLE (1) where needed
 *           5. setPaused(false) on the arena, the queue and the skins
 *
 *         Cutover from v2 (stop the v2 worker and indexer first):
 *           Safe multisend A
 *             - v2 arena, queue, skins: setPaused(true)
 *             - v2 storage: setAuthorizedWriter(v2 arena | v2 queue | v2 skins, false), setAuthorizedWriter(migrator,
 *               true)
 *             - v3 storage: setAuthorizedWriter(migrator, true)
 *             - ledger: setMoverRoles(v3 storage, 4), before any pixels arrive
 *             - migrator.grantRoles(migration operator, 8) if an EOA runs MigrateArena
 *           MigrateArena (script/MigrateArena.s.sol): moveFunds, registerTickets in chunks, copyPurchases, finish
 *           Safe multisend B
 *             - v2 storage and v3 storage: setAuthorizedWriter(migrator, false)
 *             - v3 storage: setAuthorizedWriter(arena | queue | skins, true)
 *             - ledger: setMoverRoles(v3 queue | v3 skins, 4), setMoverRoles(v2 queue | v2 skins, 0)
 *             - arena.grantRoles(operator, 8), GUARDIAN_ROLE (1) where needed; queue.grantRoles(sponsor, 16)
 *             - setPaused(false) on the v3 arena, queue and skins
 *
 *         Environment:
 *           ARENA_PIXELS      the pixel ledger (NormiesCanvasStorageV2)
 *           ARENA_COLLECTION  the Normies collection
 *           ARENA_ADAPTER     the ERC-8004 identity adapter (the owner can change it on the storage)
 *           ARENA_ADMIN       owner of every contract deployed
 *           ARENA_TREASURY    first receiver of skin payments (changed with setTreasury)
 *           ARENA_LEGACY_STORAGE        optional, the v2 storage to migrate from
 *           ARENA_DELEGATE_REGISTRY     optional, delegate.xyz v2 (default 0x00000000000000447e69651d841bD8D104Bed493)
 *           ARENA_DELEGATE_REGISTRY_V1  optional, delegate.xyz v1 (default 0x00000000000076A84feF008CDAbe6409d2FE638B)
 */
contract DeployArena is Script {
    address internal constant DELEGATE_REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;
    address internal constant DELEGATE_REGISTRY_V1 = 0x00000000000076A84feF008CDAbe6409d2FE638B;
    /// @dev Lifebuoy's flag that locks the deployer's rescue access.
    uint256 internal constant DEPLOYER_RESCUE_LOCK = 1;

    function run()
        external
        returns (
            NormiesArenaStorage store,
            NormiesArena arena,
            NormiesArenaQueue queue,
            NormiesArenaSkins skins,
            NormiesArenaMigrator migrator
        )
    {
        address pixels = vm.envAddress("ARENA_PIXELS");
        address collection = vm.envAddress("ARENA_COLLECTION");
        address adapter = vm.envAddress("ARENA_ADAPTER");
        address admin = vm.envAddress("ARENA_ADMIN");
        address treasury = vm.envAddress("ARENA_TREASURY");
        address legacy = vm.envOr("ARENA_LEGACY_STORAGE", address(0));
        address registry = vm.envOr("ARENA_DELEGATE_REGISTRY", DELEGATE_REGISTRY);
        address registryV1 = vm.envOr("ARENA_DELEGATE_REGISTRY_V1", DELEGATE_REGISTRY_V1);
        vm.startBroadcast();
        store = new NormiesArenaStorage(pixels, collection, adapter, registry, registryV1, admin);
        arena = new NormiesArena(address(store), admin);
        queue = new NormiesArenaQueue(address(store), admin);
        skins = new NormiesArenaSkins(address(store), admin, treasury);
        if (legacy != address(0)) migrator = new NormiesArenaMigrator(legacy, address(store), admin);
        // Lifebuoy lets the deployer (tx.origin) rescue until it locks itself out; leave rescue to the owner only.
        store.lockRescue(DEPLOYER_RESCUE_LOCK);
        arena.lockRescue(DEPLOYER_RESCUE_LOCK);
        queue.lockRescue(DEPLOYER_RESCUE_LOCK);
        skins.lockRescue(DEPLOYER_RESCUE_LOCK);
        vm.stopBroadcast();
    }
}
