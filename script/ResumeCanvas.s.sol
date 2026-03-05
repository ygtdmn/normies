// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesCanvasStorage } from "../src/NormiesCanvasStorage.sol";
import { NormiesCanvas } from "../src/NormiesCanvas.sol";
import { NormiesRendererV4 } from "../src/NormiesRendererV4.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";
import { INormiesCanvasStorage } from "../src/interfaces/INormiesCanvasStorage.sol";
import { INormiesCanvas } from "../src/NormiesRendererV4.sol";

contract ResumeCanvas is Script {
    function run() public {
        address canvasAddr = vm.envAddress("CANVAS_ADDRESS");

        NormiesCanvas canvas = NormiesCanvas(canvasAddr);

        vm.startBroadcast();

        canvas.setPaused(false);

        vm.stopBroadcast();
    }
}
