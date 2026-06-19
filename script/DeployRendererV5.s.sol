// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { NormiesRendererV5 } from "../src/NormiesRendererV5.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";
import { INormiesCanvasStorage } from "../src/interfaces/INormiesCanvasStorage.sol";
import { INormiesCanvas } from "../src/interfaces/INormiesCanvas.sol";
import { INormiesZombie } from "../src/interfaces/INormiesZombie.sol";
import { INormiesLegendaryCanvas } from "../src/interfaces/INormiesLegendaryCanvas.sol";

contract DeployRendererV5 is Script {
    function run() public returns (NormiesRendererV5 rendererV5) {
        address storage_ = vm.envAddress("STORAGE_ADDRESS");
        address canvasStorage = vm.envAddress("CANVAS_STORAGE_ADDRESS");
        address canvas = vm.envAddress("CANVAS_ADDRESS");
        address zombie = vm.envOr("ZOMBIE_ADDRESS", address(0));
        address legendaryCanvas = vm.envOr("LEGENDARY_CANVAS_ADDRESS", address(0));

        vm.startBroadcast();

        rendererV5 = new NormiesRendererV5(INormiesStorage(storage_), INormiesCanvasStorage(canvasStorage));
        rendererV5.setCanvasContract(INormiesCanvas(canvas));
        if (zombie != address(0)) {
            rendererV5.setZombieContract(INormiesZombie(zombie));
        }
        if (legendaryCanvas != address(0)) {
            rendererV5.setLegendaryCanvasContract(INormiesLegendaryCanvas(legendaryCanvas));
        }

        vm.stopBroadcast();
    }
}
