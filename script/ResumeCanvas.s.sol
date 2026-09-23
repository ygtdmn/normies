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

/// @dev Once the Pixel Market stack is live the V1 canvas must stay paused: its balances were copied into
///      NormiesCanvasStorageV2 once and anything earned on V1 afterwards is lost. Set RESUME_V1_CANVAS=true to
///      confirm you really want to unpause it.
contract ResumeCanvas is Script {
    error V1CanvasMustStayPaused();

    function run() public {
        address canvasAddr = vm.envAddress("CANVAS_ADDRESS");
        require(vm.envOr("RESUME_V1_CANVAS", false), V1CanvasMustStayPaused());

        NormiesCanvas canvas = NormiesCanvas(canvasAddr);

        vm.startBroadcast();

        canvas.setPaused(false);

        vm.stopBroadcast();
    }
}
