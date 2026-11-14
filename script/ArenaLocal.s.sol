// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { NormiesArenaStorage } from "../src/NormiesArenaStorage.sol";
import { NormiesArenaQueue } from "../src/NormiesArenaQueue.sol";
import { NormiesArena } from "../src/NormiesArena.sol";
import { NormiesArenaSkins } from "../src/NormiesArenaSkins.sol";

/**
 * @title ArenaLocal
 * @notice Sets up the Arena on a local Anvil mainnet fork. Broadcasts from ARENA_ADMIN (Anvil account #0), which
 *         owns all four contracts, and does only what that owner can do without pixels: deploys them and authorizes
 *         the three logic contracts as storage writers.
 *         Mover roles, test pixels, agent registration, sponsorship and unpausing impersonate other
 *         owners, so script/arena-local.sh does them with `cast send --unlocked` afterwards. This script needs no
 *         private key but ARENA_ADMIN's.
 *
 *         Environment:
 *           ARENA_PIXELS      NormiesCanvasStorageV2 (mainnet 0x96F2DA32Bb9D429d59ac13dB469f4950cBe02084)
 *           ARENA_COLLECTION  the Normies collection (mainnet 0x9Eb6E2025B64f340691e424b7fe7022fFDE12438)
 *           ARENA_ADAPTER     the ERC-8004 identity adapter (mainnet 0xde152AfB7db5373F34876E1499fbD893A82dD336)
 *           ARENA_ADMIN       owner of all four contracts and the broadcaster; pass Anvil account #0
 *           ARENA_DELEGATE_REGISTRY     optional, delegate.xyz v2 (default 0x00000000000000447e69651d841bD8D104Bed493)
 *           ARENA_DELEGATE_REGISTRY_V1  optional, delegate.xyz v1 (default 0x00000000000076A84feF008CDAbe6409d2FE638B)
 *           ARENA_TREASURY    first receiver of skin payments
 */
contract ArenaLocal is Script {
    address internal constant DELEGATE_REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;
    address internal constant DELEGATE_REGISTRY_V1 = 0x00000000000076A84feF008CDAbe6409d2FE638B;

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
        store.setAuthorizedWriter(address(arena), true);
        store.setAuthorizedWriter(address(queue), true);
        store.setAuthorizedWriter(address(skins), true);
        vm.stopBroadcast();
    }
}
