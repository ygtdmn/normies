// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesRendererV3 } from "../src/NormiesRendererV3.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";

contract UpdateRendererV3 is Script {
    function run() public returns (NormiesRendererV3 renderer) {
        // address normiesAddr = vm.envAddress("NORMIES_ADDRESS");
        address storageAddr = vm.envAddress("STORAGE_ADDRESS");

        // Normies normies = Normies(normiesAddr);

        vm.startBroadcast();

        renderer = new NormiesRendererV3(INormiesStorage(storageAddr));
        // normies.setRendererContract(INormiesRenderer(address(renderer)));

        vm.stopBroadcast();
    }
}
