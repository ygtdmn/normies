// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { NormiesZombieStorage } from "../src/NormiesZombieStorage.sol";
import { NormiesZombie } from "../src/NormiesZombie.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";
import { INormiesCanvas } from "../src/interfaces/INormiesCanvas.sol";
import { INormiesZombieStorage } from "../src/interfaces/INormiesZombieStorage.sol";

contract DeployZombies is Script {
    function run() public returns (NormiesZombieStorage zombieStorage, NormiesZombie zombie) {
        address normies = vm.envAddress("NORMIES_ADDRESS");
        address storage_ = vm.envAddress("STORAGE_ADDRESS");
        address canvas = vm.envAddress("CANVAS_ADDRESS");

        vm.startBroadcast();

        zombieStorage = new NormiesZombieStorage();
        zombie = new NormiesZombie(
            normies, INormiesStorage(storage_), INormiesCanvas(canvas), INormiesZombieStorage(address(zombieStorage))
        );

        zombieStorage.setAuthorizedWriter(address(zombie), true);
        zombie.setPaused(true);

        vm.stopBroadcast();
    }
}
