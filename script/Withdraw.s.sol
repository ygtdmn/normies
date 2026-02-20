// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { NormiesMinterV2 } from "../src/NormiesMinterV2.sol";

contract Withdraw is Script {
    function run() public {
        address normiesMinterAddress = vm.envAddress("MINTER_V2_ADDRESS");

        NormiesMinterV2 normiesMinter = NormiesMinterV2(normiesMinterAddress);

        vm.startBroadcast();

        normiesMinter.withdraw();

        vm.stopBroadcast();
    }
}
