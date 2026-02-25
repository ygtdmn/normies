// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { NormiesCanvas } from "../src/NormiesCanvas.sol";

contract UpdateCanvas is Script {
    function run() public {
        NormiesCanvas lab = NormiesCanvas(0xd1997813D0E9A181847eF9C8843CB75Bf31574ee);

        uint256 maxBurnPercent = 4;
        uint256 t0 = 490;
        uint256 t1 = 890;
        uint256 p0 = 1;
        uint256 p1 = 2;
        uint256 p2 = 3;

        vm.startBroadcast();

        lab.setMaxBurnPercent(maxBurnPercent);
        lab.setBurnTiers([t0, t1], [p0, p1, p2]);

        vm.stopBroadcast();
    }
}
