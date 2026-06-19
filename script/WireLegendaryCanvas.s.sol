// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesRendererV5 } from "../src/NormiesRendererV5.sol";
import { INormiesLegendaryCanvas } from "../src/interfaces/INormiesLegendaryCanvas.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";

contract WireLegendaryCanvas is Script {
    function run() public {
        NormiesRendererV5 renderer = NormiesRendererV5(vm.envAddress("RENDERER_V5_ADDRESS"));
        INormiesLegendaryCanvas legendaryCanvas =
            INormiesLegendaryCanvas(vm.envAddress("LEGENDARY_CANVAS_ADDRESS"));

        vm.startBroadcast();

        renderer.setLegendaryCanvasContract(legendaryCanvas);

        if (vm.envOr("FLIP_RENDERER", false)) {
            Normies normies = Normies(vm.envAddress("NORMIES_ADDRESS"));
            normies.setRendererContract(INormiesRenderer(address(renderer)));
        }

        vm.stopBroadcast();
    }
}
