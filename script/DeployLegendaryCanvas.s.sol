// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { NormiesLegendaryCanvas } from "../src/NormiesLegendaryCanvas.sol";

contract DeployLegendaryCanvas is Script {
    function run() public returns (NormiesLegendaryCanvas legendaryCanvas) {
        vm.startBroadcast();
        legendaryCanvas = new NormiesLegendaryCanvas();
        vm.stopBroadcast();
    }
}
