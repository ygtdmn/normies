// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { Normies } from "../src/Normies.sol";

contract Transfer is Script {
    function run() public {
        address normiesAddress = vm.envAddress("NORMIES_ADDRESS");
        address toAddress = 0x8a8035F056af830B7205c58c1dC037f826fc2B92;

        Normies normies = Normies(normiesAddress);

        vm.startBroadcast();

        for (uint256 i = 0; i <= 100; i++) {
            try normies.ownerOf(i) returns (address owner) {
                if (owner == msg.sender) {
                    normies.transferFrom(msg.sender, toAddress, i);
                }
            } catch {
                // Token does not exist, skip
            }
        }

        vm.stopBroadcast();
    }
}
