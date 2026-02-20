// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { console2 } from "forge-std/src/console2.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesRendererV2 } from "../src/NormiesRendererV2.sol";
import { NormiesRendererV3 } from "../src/NormiesRendererV3.sol";
import { NormiesStorage } from "../src/NormiesStorage.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";

contract NormiesRendererV3Test is Test {
    Normies normies;
    NormiesRendererV3 rendererV3;
    NormiesStorage normiesStorage;

    address owner = address(this);

    bytes8 constant REAL_TRAITS = bytes8(uint64(0x000101020B00010A));
    bytes32 constant TEST_REVEAL_HASH = keccak256("test-secret");

    function setUp() public {
        normiesStorage = new NormiesStorage();
        rendererV3 = new NormiesRendererV3(INormiesStorage(address(normiesStorage)));
        normies = new Normies(INormiesRenderer(address(rendererV3)), INormiesStorage(address(normiesStorage)), owner);
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

    function _mintRevealed(uint256 tokenId) internal {
        bytes memory encrypted = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        bytes8 encryptedTraits = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        normies.mint(owner, tokenId);
        normiesStorage.setTokenRawImageData(tokenId, encrypted);
        normiesStorage.setTokenTraits(tokenId, encryptedTraits);
        normiesStorage.setRevealHash(TEST_REVEAL_HASH);
    }

    function testRevealedTokenURI() public {
        _mintRevealed(1378);
        string memory uri = normies.tokenURI(1378);
        assertTrue(bytes(uri).length > 0);
        console2.log("=== V3 Revealed Token URI (Normie #1378) ===");
        console2.log(uri);
    }

    function testTokenURIContainsPixelCount() public {
        _mintRevealed(1378);
        string memory uri = normies.tokenURI(1378);
        // "Pixel Count" base64-encodes to "UGl4ZWwgQ291bnQ" — check the encoded output
        assertTrue(_contains(uri, "UGl4ZWwgQ291bnQ"));
    }

    function testGasComparison() public {
        bytes memory encrypted = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        bytes8 encryptedTraits = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        // Set up a second normies instance with V2 for comparison
        NormiesStorage storageV2 = new NormiesStorage();
        NormiesRendererV2 rendererV2 = new NormiesRendererV2(INormiesStorage(address(storageV2)));
        Normies normiesV2 = new Normies(INormiesRenderer(address(rendererV2)), INormiesStorage(address(storageV2)), owner);

        normiesV2.mint(owner, 42);
        storageV2.setTokenRawImageData(42, encrypted);
        storageV2.setTokenTraits(42, encryptedTraits);
        storageV2.setRevealHash(TEST_REVEAL_HASH);

        normies.mint(owner, 42);
        normiesStorage.setTokenRawImageData(42, encrypted);
        normiesStorage.setTokenTraits(42, encryptedTraits);
        normiesStorage.setRevealHash(TEST_REVEAL_HASH);

        uint256 gasBefore = gasleft();
        normiesV2.tokenURI(42);
        uint256 gasV2 = gasBefore - gasleft();

        gasBefore = gasleft();
        normies.tokenURI(42);
        uint256 gasV3 = gasBefore - gasleft();

        console2.log("V2 gas:", gasV2);
        console2.log("V3 gas:", gasV3);
        console2.log("Savings:", gasV2 - gasV3);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; i++) {
            bool found = true;
            for (uint256 j; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
}
