// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesRenderer } from "../src/NormiesRenderer.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";

contract UpdateRenderer is Script {
    function run() public {
        address normiesAddr = vm.envAddress("NORMIES_ADDRESS");
        address storageAddr = vm.envAddress("STORAGE_ADDRESS");

        Normies normies = Normies(normiesAddr);

        vm.startBroadcast();

        NormiesRenderer renderer = new NormiesRenderer(INormiesStorage(storageAddr));
        normies.setRendererContract(INormiesRenderer(address(renderer)));

        vm.stopBroadcast();
    }
}
