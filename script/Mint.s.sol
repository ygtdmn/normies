// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesStorage } from "../src/NormiesStorage.sol";

contract Mint is Script {
    // Test reveal hash for Sepolia — must match the value used in setRevealHash()
    bytes32 constant REVEAL_HASH = keccak256("test-secret");

    function run() public {
        address normiesAddr = vm.envAddress("NORMIES_ADDRESS");
        address storageAddr = vm.envAddress("STORAGE_ADDRESS");

        Normies normies = Normies(normiesAddr);
        NormiesStorage normiesStorage = NormiesStorage(storageAddr);

        uint256 tokenId = normies.totalSupply();

        // Real bitmap from 1378.svg
        bytes memory imageData =
            hex"00000000000000000000000081800000013500000042d6f0000077fffc000017ffb400003bffd8000057fff60000bfc7ea0001af5af50000fcfebf80005b8db6000177995d0000dff7ba0000dcf13f000077e72b80006fe3270000e7e02b800017e46800001e7e7800001ffff800003ffff400000ffff000000ffff000000ffff000000ffff000000ffff0000007ffe000001ffff000003ffff000008f3ce200000f00c0000007a980800213c388000001e300000001ea000008207e000008103c042004081f0020";

        // Traits: Human, Female, Middle-Aged, Curly Hair, Freckles, Classic Shades, Slight Smile, Earring
        bytes8 traits = bytes8(uint64(0x000101020B00010A));

        // XOR-encrypt before storing
        bytes memory encryptedImageData = _xorEncryptImageData(imageData, REVEAL_HASH);
        bytes8 encryptedTraits = traits ^ bytes8(REVEAL_HASH);

        vm.startBroadcast();

        normies.mint(msg.sender, tokenId);
        normiesStorage.setTokenRawImageData(tokenId, encryptedImageData);
        normiesStorage.setTokenTraits(tokenId, encryptedTraits);

        vm.stopBroadcast();
    }

    function _xorEncryptImageData(bytes memory data, bytes32 _revealHash) internal pure returns (bytes memory) {
        bytes memory encrypted = new bytes(data.length);
        bytes32 key;
        for (uint256 i = 0; i < data.length; i++) {
            if (i & 31 == 0) {
                key = keccak256(abi.encodePacked(_revealHash, i >> 5));
            }
            encrypted[i] = bytes1(uint8(data[i]) ^ uint8(key[i & 31]));
        }
        return encrypted;
    }
}
