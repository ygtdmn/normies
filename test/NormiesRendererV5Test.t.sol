// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { Base64 } from "solady/utils/Base64.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesRendererV4 } from "../src/NormiesRendererV4.sol";
import { NormiesRendererV5 } from "../src/NormiesRendererV5.sol";
import { NormiesStorage } from "../src/NormiesStorage.sol";
import { NormiesCanvasStorage } from "../src/NormiesCanvasStorage.sol";
import { NormiesLegendaryCanvas } from "../src/NormiesLegendaryCanvas.sol";
import { NormiesZombie } from "../src/NormiesZombie.sol";
import { NormiesZombieStorage } from "../src/NormiesZombieStorage.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";
import { INormiesCanvasStorage } from "../src/interfaces/INormiesCanvasStorage.sol";
import { INormiesCanvas } from "../src/interfaces/INormiesCanvas.sol";
import { INormiesLegendaryCanvas } from "../src/interfaces/INormiesLegendaryCanvas.sol";
import { INormiesZombie } from "../src/interfaces/INormiesZombie.sol";
import { INormiesZombieStorage } from "../src/interfaces/INormiesZombieStorage.sol";

contract MockCanvasForRenderer is INormiesCanvas {
    mapping(uint256 => uint256) public actionPoints;

    function setActionPoints(uint256 tokenId, uint256 points) external {
        actionPoints[tokenId] = points;
    }

    function getLevel(uint256 tokenId) external view returns (uint256) {
        return actionPoints[tokenId] / 10 + 1;
    }
}

contract NormiesRendererV5Test is Test {
    Normies normiesV4;
    Normies normiesV5;
    NormiesRendererV4 rendererV4;
    NormiesRendererV5 rendererV5;
    NormiesStorage normiesStorage;
    NormiesCanvasStorage transformStorage;
    NormiesLegendaryCanvas legendaryCanvas;
    NormiesZombieStorage zombieStorage;
    NormiesZombie zombie;
    MockCanvasForRenderer canvas;

    bytes8 constant HUMAN_TRAITS = bytes8(uint64(0x000101020B00010A));
    bytes32 constant TEST_REVEAL_HASH = keccak256("test-secret");

    function setUp() public {
        normiesStorage = new NormiesStorage();
        transformStorage = new NormiesCanvasStorage();
        canvas = new MockCanvasForRenderer();
        rendererV4 = new NormiesRendererV4(
            INormiesStorage(address(normiesStorage)), INormiesCanvasStorage(address(transformStorage))
        );
        rendererV5 = new NormiesRendererV5(
            INormiesStorage(address(normiesStorage)), INormiesCanvasStorage(address(transformStorage))
        );
        rendererV4.setCanvasContract(INormiesCanvas(address(canvas)));
        rendererV5.setCanvasContract(INormiesCanvas(address(canvas)));
        legendaryCanvas = new NormiesLegendaryCanvas();
        rendererV5.setLegendaryCanvasContract(INormiesLegendaryCanvas(address(legendaryCanvas)));
        normiesV4 =
            new Normies(INormiesRenderer(address(rendererV4)), INormiesStorage(address(normiesStorage)), address(this));
        normiesV5 =
            new Normies(INormiesRenderer(address(rendererV5)), INormiesStorage(address(normiesStorage)), address(this));
        zombieStorage = new NormiesZombieStorage();
        zombie = new NormiesZombie(
            address(normiesV5),
            INormiesStorage(address(normiesStorage)),
            INormiesCanvas(address(canvas)),
            INormiesZombieStorage(address(zombieStorage))
        );
        rendererV5.setZombieContract(INormiesZombie(address(zombie)));
        normiesStorage.setRevealHash(TEST_REVEAL_HASH);
    }

    function testNonZombieMatchesV4Plain() public {
        _mintRevealed(1, _bitmapWithPixels(40));

        assertEq(keccak256(bytes(normiesV5.tokenURI(1))), keccak256(bytes(normiesV4.tokenURI(1))));
    }

    function testNonZombieMatchesV4Transformed() public {
        _mintRevealed(1, _bitmapWithPixels(40));
        bytes memory overlay = new bytes(200);
        overlay[0] = 0x80;
        transformStorage.setTransformedImageData(1, overlay);

        assertEq(keccak256(bytes(normiesV5.tokenURI(1))), keccak256(bytes(normiesV4.tokenURI(1))));
    }

    function testNoZombieContractMatchesV4() public {
        _mintRevealed(1, _bitmapWithPixels(40));
        rendererV5.setZombieContract(INormiesZombie(address(0)));

        assertEq(keccak256(bytes(normiesV5.tokenURI(1))), keccak256(bytes(normiesV4.tokenURI(1))));
    }

    function testZombieUsesCustomAttributesAndArt() public {
        _mintRevealed(1, _bitmapWithPixels(40));
        _setZombie(1, _bitmapWithPixels(13));
        canvas.setActionPoints(1, 20);

        string memory json = _decodeTokenURI(normiesV5.tokenURI(1));

        assertTrue(_contains(json, '"trait_type":"Type","value":"Zombie"'));
        assertTrue(_contains(json, '"trait_type":"Mutation","value":"Green Room"'));
        assertTrue(_contains(json, '"trait_type":"Level","value":3'));
        assertTrue(_contains(json, '"trait_type":"Pixel Count","value":13'));
        assertFalse(_contains(json, '"value":"Human"'));
    }

    function testLegendaryCanvasTraitAppendedForHuman() public {
        _mintRevealed(1, _bitmapWithPixels(40));
        legendaryCanvas.setLegendaryCanvas(1, "Serc");

        string memory json = _decodeTokenURI(normiesV5.tokenURI(1));

        assertTrue(_contains(json, '"trait_type":"Legendary Canvas","value":"Serc"'));
        assertTrue(_contains(json, '"trait_type":"Pixel Count","value":40'));
    }

    function testLegendaryCanvasTraitAppendedForZombie() public {
        _mintRevealed(1, _bitmapWithPixels(40));
        _setZombie(1, _bitmapWithPixels(13));
        legendaryCanvas.setLegendaryCanvas(1, "Yigit Duman");

        string memory json = _decodeTokenURI(normiesV5.tokenURI(1));

        assertTrue(_contains(json, '"trait_type":"Type","value":"Zombie"'));
        assertTrue(_contains(json, '"trait_type":"Legendary Canvas","value":"Yigit Duman"'));
        assertTrue(_contains(json, '"trait_type":"Pixel Count","value":13'));
    }

    function testZombieOverlayCountsCompositePixels() public {
        _mintRevealed(1, _bitmapWithPixels(40));
        _setZombie(1, _bitmapWithPixels(8));
        bytes memory overlay = new bytes(200);
        overlay[0] = 0x80;
        transformStorage.setTransformedImageData(1, overlay);

        string memory json = _decodeTokenURI(normiesV5.tokenURI(1));

        assertTrue(_contains(json, '"trait_type":"Pixel Count","value":7'));
        assertTrue(_contains(json, '"trait_type":"Customized","value":"Yes"'));
    }

    function _setZombie(uint256 tokenId, bytes memory bitmap) internal {
        zombieStorage.addZombie(
            bitmap, bytes('{"trait_type":"Type","value":"Zombie"},{"trait_type":"Mutation","value":"Green Room"}')
        );
        zombieStorage.sealPool();
        zombieStorage.setZombie(tokenId, 0);
    }

    function _mintRevealed(uint256 tokenId, bytes memory bitmap) internal {
        normiesV4.mint(address(this), tokenId);
        normiesV5.mint(address(this), tokenId);
        normiesStorage.setTokenRawImageData(tokenId, _xorEncryptImageData(bitmap, TEST_REVEAL_HASH));
        normiesStorage.setTokenTraits(tokenId, HUMAN_TRAITS ^ bytes8(TEST_REVEAL_HASH));
    }

    function _bitmapWithPixels(uint256 pixelCount) internal pure returns (bytes memory) {
        bytes memory bitmap = new bytes(200);
        uint256 set;
        for (uint256 i; i < 200 && set < pixelCount; i++) {
            uint256 bitsToSet = pixelCount - set;
            if (bitsToSet >= 8) {
                bitmap[i] = bytes1(0xFF);
                set += 8;
            } else {
                bitmap[i] = bytes1(uint8(0xFF << (8 - bitsToSet)));
                set += bitsToSet;
            }
        }
        return bitmap;
    }

    function _xorEncryptImageData(bytes memory data, bytes32 revealHash) internal pure returns (bytes memory) {
        bytes memory encrypted = new bytes(data.length);
        bytes32 key;
        for (uint256 i; i < data.length; i++) {
            if (i & 31 == 0) {
                key = keccak256(abi.encodePacked(revealHash, i >> 5));
            }
            encrypted[i] = bytes1(uint8(data[i]) ^ uint8(key[i & 31]));
        }
        return encrypted;
    }

    function _decodeTokenURI(string memory uri) internal pure returns (string memory) {
        bytes memory uriBytes = bytes(uri);
        uint256 prefixLen = 29;
        bytes memory b64 = new bytes(uriBytes.length - prefixLen);
        for (uint256 i; i < b64.length; i++) {
            b64[i] = uriBytes[i + prefixLen];
        }
        return string(Base64.decode(string(b64)));
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
