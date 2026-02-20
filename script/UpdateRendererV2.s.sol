// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesRendererV2 } from "../src/NormiesRendererV2.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";

contract UpdateRendererV2 is Script {
    function run() public returns (NormiesRendererV2 renderer) {
        // address normiesAddr = vm.envAddress("NORMIES_ADDRESS");
        address storageAddr = vm.envAddress("STORAGE_ADDRESS");

        // Normies normies = Normies(normiesAddr);

        vm.startBroadcast();

        renderer = new NormiesRendererV2(INormiesStorage(storageAddr));
        // normies.setRendererContract(INormiesRenderer(address(renderer)));

        vm.stopBroadcast();
    }
}
