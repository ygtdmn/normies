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

contract DeployCanvas is Script {
    function run()
        public
        returns (NormiesCanvasStorage transformStorage, NormiesCanvas canvas, NormiesRendererV4 rendererV4)
    {
        address normiesAddr = vm.envAddress("NORMIES_ADDRESS");
        address storageAddr = vm.envAddress("STORAGE_ADDRESS");

        Normies normies = Normies(normiesAddr);

        vm.startBroadcast();

        // 1. Deploy transform storage (no dependencies)
        transformStorage = new NormiesCanvasStorage();

        // 2. Deploy lab (depends on normies + original storage + transform storage)
        canvas = new NormiesCanvas(
            normiesAddr, INormiesStorage(storageAddr), INormiesCanvasStorage(address(transformStorage))
        );

        // 3. Deploy renderer V4 (depends on original storage + transform storage)
        rendererV4 =
            new NormiesRendererV4(INormiesStorage(storageAddr), INormiesCanvasStorage(address(transformStorage)));

        // 4. Allow lab to write to transform storage
        transformStorage.setAuthorizedWriter(address(canvas), true);

        // 5. Set canvas on renderer (for level reads)
        rendererV4.setCanvasContract(INormiesCanvas(address(canvas)));

        // 6. Set renderer V4 on Normies contract
        // normies.setRendererContract(INormiesRenderer(address(rendererV4)));

        // 7. Pause Canvas
        canvas.setPaused(true);

        vm.stopBroadcast();
    }
}
