// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { console2 } from "forge-std/src/console2.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesRendererV2 } from "../src/NormiesRendererV2.sol";
import { NormiesStorage } from "../src/NormiesStorage.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";

contract NormiesRendererV2Test is Test {
    Normies normies;
    NormiesRendererV2 renderer;
    NormiesStorage normiesStorage;

    address owner = address(this);

    bytes8 constant DEFAULT_TRAITS = bytes8(uint64(0x000000000A0D000E));
    bytes8 constant REAL_TRAITS = bytes8(uint64(0x000101020B00010A));
    bytes32 constant TEST_REVEAL_HASH = keccak256("test-secret");

    function setUp() public {
        normiesStorage = new NormiesStorage();
        renderer = new NormiesRendererV2(INormiesStorage(address(normiesStorage)));
        normies = new Normies(INormiesRenderer(address(renderer)), INormiesStorage(address(normiesStorage)), owner);
    }

    function _createRealBitmap() internal pure returns (bytes memory) {
        return
            hex"00000000000000000000000081800000013500000042d6f0000077fffc000017ffb400003bffd8000057fff60000bfc7ea0001af5af50000fcfebf80005b8db6000177995d0000dff7ba0000dcf13f000077e72b80006fe3270000e7e02b800017e46800001e7e7800001ffff800003ffff400000ffff000000ffff000000ffff000000ffff000000ffff0000007ffe000001ffff000003ffff000008f3ce200000f00c0000007a980800213c388000001e300000001ea000008207e000008103c042004081f0020";
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

    /// @notice Log the pre-reveal (static noise) data URI — run with `forge test --match-test testLogPreRevealURI -vv`
    function testLogPreRevealURI() public {
        bytes memory encrypted = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        bytes8 encryptedTraits = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        normies.mint(owner, 0);
        normiesStorage.setTokenRawImageData(0, encrypted);
        normiesStorage.setTokenTraits(0, encryptedTraits);

        string memory uri = normies.tokenURI(0);
        console2.log("=== Pre-Reveal (Static Noise) Token URI ===");
        console2.log(uri);
    }

    /// @notice Log the revealed data URI — run with `forge test --match-test testLogRevealedURI -vv`
    function testLogRevealedURI() public {
        bytes memory encrypted = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        bytes8 encryptedTraits = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        normies.mint(owner, 1378);
        normiesStorage.setTokenRawImageData(1378, encrypted);
        normiesStorage.setTokenTraits(1378, encryptedTraits);
        normiesStorage.setRevealHash(TEST_REVEAL_HASH);

        string memory uri = normies.tokenURI(1378);
        console2.log("=== Revealed Token URI (Normie #1378) ===");
        console2.log(uri);
    }

    /// @notice Log URIs for multiple seeds to compare noise patterns — run with `forge test --match-test testLogMultipleNoiseSeeds -vv`
    function testLogMultipleNoiseSeeds() public {
        bytes memory encrypted = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        bytes8 encryptedTraits = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        for (uint256 i = 0; i < 3; i++) {
            normies.mint(owner, i);
            normiesStorage.setTokenRawImageData(i, encrypted);
            normiesStorage.setTokenTraits(i, encryptedTraits);

            string memory uri = normies.tokenURI(i);
            console2.log("=== Pre-Reveal Token #%d ===", i);
            console2.log(uri);
        }
    }
}
