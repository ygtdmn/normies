// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesMinter } from "../src/NormiesMinter.sol";
import { NormiesRenderer } from "../src/NormiesRenderer.sol";
import { NormiesStorage } from "../src/NormiesStorage.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";
import { INormies } from "../src/interfaces/INormies.sol";

contract Deploy is Script {
    function run()
        public
        returns (NormiesStorage storage_, NormiesRenderer renderer, Normies normies, NormiesMinter minter)
    {
        address signer = vm.envAddress("SIGNER_ADDRESS");
        address withdrawAddr = vm.envAddress("WITHDRAW_ADDRESS");
        address royaltyReceiver = vm.envAddress("ROYALTY_RECEIVER");

        vm.startBroadcast();

        // 1. Deploy storage (no dependencies)
        storage_ = new NormiesStorage();

        // 2. Deploy renderer (depends on storage)
        renderer = new NormiesRenderer(INormiesStorage(address(storage_)));

        // 3. Deploy NFT contract (depends on renderer + storage)
        normies = new Normies(INormiesRenderer(address(renderer)), INormiesStorage(address(storage_)), royaltyReceiver);

        // 4. Deploy minter (depends on normies + storage + signer)
        minter = new NormiesMinter(
            INormies(address(normies)), INormiesStorage(address(storage_)), signer, 0.005 ether, withdrawAddr
        );

        // 5. Allow minter to call normies.mint()
        address[] memory minterAddrs = new address[](1);
        bool[] memory allowed = new bool[](1);
        minterAddrs[0] = address(minter);
        allowed[0] = true;
        normies.setMinterAddresses(minterAddrs, allowed);

        // 6. Allow minter to write to storage
        storage_.setAuthorizedWriter(address(minter), true);

        vm.stopBroadcast();
    }
}
