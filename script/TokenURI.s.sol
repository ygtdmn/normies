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
import { console2 } from "forge-std/src/console2.sol";

contract TokenURI is Script {
    function run() public {
        address normiesAddr = vm.envAddress("NORMIES_ADDRESS");

        Normies normies = Normies(normiesAddr);

        string memory tokenURI = normies.tokenURI(464);

        console2.log(tokenURI);
    }
}
