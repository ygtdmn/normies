// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesRenderer } from "../src/NormiesRenderer.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { NormiesStorage } from "../src/NormiesStorage.sol";
import { console2 } from "forge-std/src/console2.sol";

contract Reveal is Script {
    function run() public {
        address normiesAddr = vm.envAddress("NORMIES_ADDRESS");
        address storageAddr = vm.envAddress("STORAGE_ADDRESS");

        Normies normies = Normies(normiesAddr);
        NormiesStorage normiesStorage = NormiesStorage(storageAddr);

        string memory revealSecret = vm.envString("REVEAL_SECRET");
        bytes32 revealHash = keccak256(abi.encodePacked(revealSecret));

        vm.startBroadcast();

        normiesStorage.setRevealHash(revealHash);
        // normies.signalMetadataUpdate();

        // console2.log(normies.tokenURI(0));

        vm.stopBroadcast();
    }
}
