// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesZombie } from "../src/NormiesZombie.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";

contract WireZombies is Script {
    function run() public {
        NormiesZombie zombie = NormiesZombie(vm.envAddress("ZOMBIE_ADDRESS"));
        bytes32 merkleRoot = vm.envBytes32("MERKLE_ROOT");
        uint256 seedBlock = vm.envUint("SEED_BLOCK");

        vm.startBroadcast();

        zombie.setMerkleRoot(merkleRoot);
        zombie.setSeedBlock(seedBlock);

        if (vm.envOr("FLIP_RENDERER", false)) {
            Normies normies = Normies(vm.envAddress("NORMIES_ADDRESS"));
            normies.setRendererContract(INormiesRenderer(vm.envAddress("ZOMBIE_RENDERER_ADDRESS")));
        }

        if (vm.envOr("UNPAUSE_ZOMBIES", false)) {
            zombie.setPaused(false);
        }

        vm.stopBroadcast();
    }
}
