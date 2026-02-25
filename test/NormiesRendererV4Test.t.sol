// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { console2 } from "forge-std/src/console2.sol";
import { Base64 } from "solady/utils/Base64.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesRendererV3 } from "../src/NormiesRendererV3.sol";
import { NormiesRendererV4 } from "../src/NormiesRendererV4.sol";
import { NormiesStorage } from "../src/NormiesStorage.sol";
import { NormiesCanvasStorage } from "../src/NormiesCanvasStorage.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";
import { INormiesCanvasStorage } from "../src/interfaces/INormiesCanvasStorage.sol";

contract NormiesRendererV4Test is Test {
    Normies normiesV4;
    Normies normiesV3;
    NormiesRendererV4 rendererV4;
    NormiesRendererV3 rendererV3;
    NormiesStorage normiesStorage;
    NormiesCanvasStorage transformStorage;

    address owner = address(this);

    bytes8 constant REAL_TRAITS = bytes8(uint64(0x000101020B00010A));
    bytes32 constant TEST_REVEAL_HASH = keccak256("test-secret");

    function setUp() public {
        normiesStorage = new NormiesStorage();
        transformStorage = new NormiesCanvasStorage();

        rendererV3 = new NormiesRendererV3(INormiesStorage(address(normiesStorage)));
        rendererV4 = new NormiesRendererV4(
            INormiesStorage(address(normiesStorage)), INormiesCanvasStorage(address(transformStorage))
        );

        // V4 normies (primary)
        normiesV4 =
            new Normies(INormiesRenderer(address(rendererV4)), INormiesStorage(address(normiesStorage)), owner);

        // V3 normies (for comparison)
        normiesV3 =
            new Normies(INormiesRenderer(address(rendererV3)), INormiesStorage(address(normiesStorage)), owner);
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

        normiesV4.mint(owner, tokenId);
        normiesV3.mint(owner, tokenId);
        normiesStorage.setTokenRawImageData(tokenId, encrypted);
        normiesStorage.setTokenTraits(tokenId, encryptedTraits);
        normiesStorage.setRevealHash(TEST_REVEAL_HASH);
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

    /// @notice Strips "data:application/json;base64," prefix and decodes the JSON
    function _decodeTokenURI(string memory uri) internal pure returns (string memory) {
        bytes memory uriBytes = bytes(uri);
        // "data:application/json;base64," = 29 bytes
        uint256 prefixLen = 29;
        bytes memory b64 = new bytes(uriBytes.length - prefixLen);
        for (uint256 i; i < b64.length; i++) {
            b64[i] = uriBytes[i + prefixLen];
        }
        return string(Base64.decode(string(b64)));
    }

    // ──────────────────────────────────────────────
    //  Untransformed token tests
    // ──────────────────────────────────────────────

    function testUntransformedTokenURI() public {
        _mintRevealed(1378);
        string memory uri = normiesV4.tokenURI(1378);
        assertTrue(bytes(uri).length > 0);
        console2.log("=== V4 Untransformed Token URI (Normie #1378) ===");
        console2.log(uri);
    }

    function testUntransformedTokenContainsCustomizedNo() public {
        _mintRevealed(1378);
        string memory uri = normiesV4.tokenURI(1378);
        string memory json = _decodeTokenURI(uri);
        assertTrue(_contains(json, '"Customized"'));
        assertTrue(_contains(json, '"No"'));
    }

    function testUntransformedTokenContainsPixelCount() public {
        _mintRevealed(1378);
        string memory uri = normiesV4.tokenURI(1378);
        string memory json = _decodeTokenURI(uri);
        assertTrue(_contains(json, '"Pixel Count"'));
        assertTrue(_contains(json, '"Action Points"'));
    }

    // ──────────────────────────────────────────────
    //  Transformed token tests
    // ──────────────────────────────────────────────

    function testTransformedTokenURI() public {
        _mintRevealed(1378);

        // Custom layer: only pixel (0,0) added
        bytes memory customLayer = new bytes(200);
        customLayer[0] = bytes1(0x80); // Turn on pixel (0,0)

        transformStorage.setTransformedImageData(1378, customLayer);

        string memory uri = normiesV4.tokenURI(1378);
        assertTrue(bytes(uri).length > 0);
        console2.log("=== V4 Transformed Token URI (Normie #1378) ===");
        console2.log(uri);
    }

    function testTransformedTokenContainsTransformTraits() public {
        _mintRevealed(1378);

        // Custom layer with 1 pixel
        bytes memory customLayer = new bytes(200);
        customLayer[0] = bytes1(0x80);

        transformStorage.setTransformedImageData(1378, customLayer);

        string memory uri = normiesV4.tokenURI(1378);
        string memory json = _decodeTokenURI(uri);

        assertTrue(_contains(json, '"Pixel Count"'));
        assertTrue(_contains(json, '"Action Points"'));
        assertTrue(_contains(json, '"Customized"'));
        assertTrue(_contains(json, '"Yes"'));
        assertFalse(_contains(json, '"Custom Pixel Count"'));
        assertFalse(_contains(json, '"Original Pixel Count"'));
        assertFalse(_contains(json, '"Times Edited"'));
    }

    function testTransformedTokenCompositesLayers() public {
        _mintRevealed(1378);

        // Custom layer: only first 8 pixels on (byte 0 = 0xFF)
        bytes memory customLayer = new bytes(200);
        customLayer[0] = bytes1(0xFF);

        transformStorage.setTransformedImageData(1378, customLayer);

        // The URI should reflect the composite (original | custom), different from V3
        string memory uri = normiesV4.tokenURI(1378);
        assertTrue(bytes(uri).length > 0);

        string memory v3Uri = normiesV3.tokenURI(1378);
        assertTrue(keccak256(bytes(uri)) != keccak256(bytes(v3Uri)));
    }

    // ──────────────────────────────────────────────
    //  Gas comparison
    // ──────────────────────────────────────────────

    function testGasV4vsV3Untransformed() public {
        _mintRevealed(42);

        uint256 gasBefore = gasleft();
        normiesV3.tokenURI(42);
        uint256 gasV3 = gasBefore - gasleft();

        gasBefore = gasleft();
        normiesV4.tokenURI(42);
        uint256 gasV4 = gasBefore - gasleft();

        console2.log("V3 gas (untransformed):", gasV3);
        console2.log("V4 gas (untransformed):", gasV4);
        console2.log("V4 overhead:", gasV4 > gasV3 ? gasV4 - gasV3 : 0);
    }

    function testGasV4Transformed() public {
        _mintRevealed(42);

        // Custom layer with a few pixels
        bytes memory customLayer = new bytes(200);
        customLayer[0] = bytes1(0xFF);
        customLayer[1] = bytes1(0xFF);
        transformStorage.setTransformedImageData(42, customLayer);

        uint256 gasBefore = gasleft();
        normiesV4.tokenURI(42);
        uint256 gasV4Transformed = gasBefore - gasleft();

        console2.log("V4 gas (transformed, composite):", gasV4Transformed);
    }
}
