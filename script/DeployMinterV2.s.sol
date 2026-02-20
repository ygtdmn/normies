// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { NormiesMinter } from "../src/NormiesMinter.sol";
import { NormiesMinterV2 } from "../src/NormiesMinterV2.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesStorage } from "../src/NormiesStorage.sol";
import { INormies } from "../src/interfaces/INormies.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";

contract DeployMinterV2 is Script {
    function run() public returns (NormiesMinterV2 minterV2) {
        address signer = vm.envAddress("SIGNER_ADDRESS");
        address withdrawAddr = vm.envAddress("WITHDRAW_ADDRESS");

        NormiesMinter minterV1 = NormiesMinter(vm.envAddress("MINTER_ADDRESS"));
        Normies normies = Normies(vm.envAddress("NORMIES_ADDRESS"));
        NormiesStorage storage_ = NormiesStorage(vm.envAddress("STORAGE_ADDRESS"));

        vm.startBroadcast();

        // 1. Pause minter v1
        minterV1.setPaused(true);

        // 2. Deploy minter v2
        minterV2 = new NormiesMinterV2(
            INormies(address(normies)), INormiesStorage(address(storage_)), signer, 0.005 ether, withdrawAddr
        );

        // 3. Swap minter addresses on Normies (remove v1, add v2)
        address[] memory addrs = new address[](2);
        bool[] memory allowed = new bool[](2);
        addrs[0] = address(minterV1);
        allowed[0] = false;
        addrs[1] = address(minterV2);
        allowed[1] = true;
        normies.setMinterAddresses(addrs, allowed);

        // 4. Swap authorized writers on Storage (remove v1, add v2)
        storage_.setAuthorizedWriter(address(minterV1), false);
        storage_.setAuthorizedWriter(address(minterV2), true);

        vm.stopBroadcast();
    }
}
