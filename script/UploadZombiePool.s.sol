// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { stdJson } from "forge-std/src/StdJson.sol";
import { NormiesZombieStorage } from "../src/NormiesZombieStorage.sol";

contract UploadZombiePool is Script {
    using stdJson for string;

    function run() public {
        NormiesZombieStorage zombieStorage = NormiesZombieStorage(vm.envAddress("ZOMBIE_STORAGE_ADDRESS"));
        string memory poolPath = vm.envOr("POOL_JSON", string("tooling/zombies/out/pool-flat.json"));
        uint256 start = vm.envOr("POOL_START", uint256(0));
        uint256 limit = vm.envOr("POOL_LIMIT", uint256(0));

        string memory json = vm.readFile(poolPath);
        bytes[] memory bitmaps = json.readBytesArray(".bitmaps");
        string[] memory attrs = json.readStringArray(".attrs");
        require(bitmaps.length == attrs.length, "pool length mismatch");

        uint256 end = limit == 0 ? bitmaps.length : start + limit;
        if (end > bitmaps.length) end = bitmaps.length;

        vm.startBroadcast();

        for (uint256 i = start; i < end; i++) {
            zombieStorage.addZombie(bitmaps[i], bytes(attrs[i]));
        }

        if (vm.envOr("SEAL_POOL", false)) {
            require(zombieStorage.poolSize() >= 21, "pool too small");
            zombieStorage.sealPool();
        }

        vm.stopBroadcast();
    }
}
