// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { NormiesArenaStorage } from "../src/NormiesArenaStorage.sol";
import { NormiesArenaQueue } from "../src/NormiesArenaQueue.sol";
import { NormiesArena } from "../src/NormiesArena.sol";
import { NormiesArenaSkins } from "../src/NormiesArenaSkins.sol";

/**
 * @title DeployArena
 * @notice Deploys NormiesArenaStorage and its three logic contracts (NormiesArena, NormiesArenaQueue,
 *         NormiesArenaSkins), all owned by ARENA_ADMIN. The logic contracts start paused and every setting starts
 *         at its default; ARENA_ADMIN changes them afterwards with the owner setters. The broadcaster grants
 *         nothing, and locks its own Lifebuoy rescue access on all four (lockRescue(1)), so only ARENA_ADMIN can
 *         rescue tokens sent to them by mistake.
 *
 *         Then, from ARENA_ADMIN:
 *           1. storage.setAuthorizedWriter for the arena, the queue and the skins
 *           2. on the pixel ledger, from its owner: setMoverRoles(storage | queue | skins, 4). The arena needs no
 *              ledger role.
 *           3. queue.grantRoles(sponsor, 16), then queue.sponsor for rounds 1 and 2 from that funded wallet. Only
 *              the owner and SPONSOR_ROLE may sponsor. A free round cannot start without sponsorship.
 *           4. arena.grantRoles(operator, 8), and GUARDIAN_ROLE (1) where needed
 *           5. setPaused(false) on the arena, the queue and the skins
 *           6. arena.startRound(1) to open round 1 and arena.finishRound(1) to end it
 *
 *         Environment:
 *           ARENA_PIXELS      the pixel ledger (NormiesCanvasStorageV2)
 *           ARENA_COLLECTION  the Normies collection
 *           ARENA_ADAPTER     the ERC-8004 identity adapter (the owner can change it on the storage)
 *           ARENA_ADMIN       owner of all four contracts
 *           ARENA_DELEGATE_REGISTRY     optional, delegate.xyz v2 (default 0x00000000000000447e69651d841bD8D104Bed493)
 *           ARENA_DELEGATE_REGISTRY_V1  optional, delegate.xyz v1 (default 0x00000000000076A84feF008CDAbe6409d2FE638B)
 *           ARENA_TREASURY    first receiver of skin payments (changed with setTreasury)
 */
contract DeployArena is Script {
    address internal constant DELEGATE_REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;
    address internal constant DELEGATE_REGISTRY_V1 = 0x00000000000076A84feF008CDAbe6409d2FE638B;
    /// @dev Lifebuoy's flag that locks the deployer's rescue access.
    uint256 internal constant DEPLOYER_RESCUE_LOCK = 1;

    function run()
        external
        returns (NormiesArenaStorage store, NormiesArena arena, NormiesArenaQueue queue, NormiesArenaSkins skins)
    {
        address pixels = vm.envAddress("ARENA_PIXELS");
        address collection = vm.envAddress("ARENA_COLLECTION");
        address adapter = vm.envAddress("ARENA_ADAPTER");
        address admin = vm.envAddress("ARENA_ADMIN");
        address treasury = vm.envAddress("ARENA_TREASURY");
        address registry = vm.envOr("ARENA_DELEGATE_REGISTRY", DELEGATE_REGISTRY);
        address registryV1 = vm.envOr("ARENA_DELEGATE_REGISTRY_V1", DELEGATE_REGISTRY_V1);
        vm.startBroadcast();
        store = new NormiesArenaStorage(pixels, collection, adapter, registry, registryV1, admin);
        arena = new NormiesArena(address(store), admin);
        queue = new NormiesArenaQueue(address(store), admin);
        skins = new NormiesArenaSkins(address(store), admin, treasury);
        // Lifebuoy lets the deployer (tx.origin) rescue until it locks itself out; leave rescue to the owner only.
        store.lockRescue(DEPLOYER_RESCUE_LOCK);
        arena.lockRescue(DEPLOYER_RESCUE_LOCK);
        queue.lockRescue(DEPLOYER_RESCUE_LOCK);
        skins.lockRescue(DEPLOYER_RESCUE_LOCK);
        vm.stopBroadcast();
    }
}
