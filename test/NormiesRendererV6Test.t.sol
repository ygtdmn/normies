// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { PixelMarketBase } from "./PixelMarketBase.t.sol";
import { MockZombie } from "./mocks/MockZombie.sol";
import { NormiesRendererV6 } from "../src/NormiesRendererV6.sol";
import { INormiesCanvasV2 } from "../src/interfaces/INormiesCanvasV2.sol";
import { INormiesZombie } from "../src/interfaces/INormiesZombie.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";
import { INormiesCanvasStorage } from "../src/interfaces/INormiesCanvasStorage.sol";
import { INormiesCanvasStorageV2 } from "../src/interfaces/INormiesCanvasStorageV2.sol";

contract NormiesRendererV6Test is PixelMarketBase {
    INormiesCanvasV2.PaySource constant WALLET = INormiesCanvasV2.PaySource.Wallet;

    function testAttributesMatchV5PlusNewTraits() public {
        _mintRealTo(user, 1);
        string memory v5 = _decodeTokenURI(rendererV5.tokenURI(1));
        string memory v6 = _decodeTokenURI(renderer.tokenURI(1));

        string[9] memory shared = [
            '"trait_type":"Type","value":"Human"',
            '"trait_type":"Gender"',
            '"trait_type":"Hair Style"',
            '"trait_type":"Level","value":1',
            '"trait_type":"Pixel Count","value":',
            '"trait_type":"Action Points","value":0',
            '"trait_type":"Customized","value":"No"',
            '"name":"Normie #1"',
            '"animation_url":"data:text/html;base64,'
        ];
        for (uint256 i; i < shared.length; i++) {
            assertTrue(_contains(v5, shared[i]));
            assertTrue(_contains(v6, shared[i]));
        }
        assertTrue(_contains(v6, '"trait_type":"Canvas Size","value":"40x40"'));
        assertTrue(_contains(v6, '"trait_type":"Blank Canvas","value":"No"'));
        assertFalse(_contains(v5, "Canvas Size"));

        string memory svg = _extractSvg(v6);
        assertTrue(_contains(svg, 'viewBox="0 0 40 40"'));
        assertTrue(_contains(svg, '<rect width="40" height="40" fill="#e3e5e4"/>'));
        assertTrue(_contains(svg, '<path fill="#48494b" d="M'));
    }

    function testPixelCountMatchesV5ForHumans() public {
        _mintRealTo(user, 1);
        string memory v5 = _decodeTokenURI(rendererV5.tokenURI(1));
        string memory v6 = _decodeTokenURI(renderer.tokenURI(1));
        // Both report the original art count (same number appears in both).
        bytes memory needle = bytes('"trait_type":"Pixel Count","value":');
        assertEq(_numberAfter(v5, needle), _numberAfter(v6, needle));
    }

    function testLevelAndPointsFromLedger() public {
        _mintRealTo(user, 1);
        uint256 got = _giveTokenPixels(user, 1, 48);
        string memory json = _decodeTokenURI(renderer.tokenURI(1));
        assertTrue(_contains(json, string(abi.encodePacked('"trait_type":"Level","value":', _u(got / 10 + 1)))));
        assertTrue(_contains(json, string(abi.encodePacked('"trait_type":"Action Points","value":', _u(got)))));
    }

    function testCenteredBaseOn80() public {
        bytes memory art = new bytes(200);
        _setPixel(art, 0, 0, 40);
        _setPixel(art, 39, 39, 40);
        _mintRevealedTo(user, 1, art);
        canvas.setEnlargePrice(80, 0);
        vm.prank(user);
        canvas.enlargeCanvas(1, 80, WALLET, false);

        string memory json = _decodeTokenURI(renderer.tokenURI(1));
        assertTrue(_contains(json, '"trait_type":"Canvas Size","value":"80x80"'));
        assertTrue(_contains(json, '"trait_type":"Pixel Count","value":2'));
        string memory svg = _extractSvg(json);
        assertTrue(_contains(svg, 'viewBox="0 0 80 80"'));
        assertTrue(_contains(svg, "M20 20h1v1h-1z"));
        assertTrue(_contains(svg, "M59 59h1v1h-1z"));
    }

    function testOverlayOnEnlargedCanvas() public {
        bytes memory art = new bytes(200);
        _setPixel(art, 0, 0, 40);
        _mintRevealedTo(user, 1, art);
        uint256 got = _giveTokenPixels(user, 1, 48);
        canvas.setEnlargePrice(60, 0);
        vm.startPrank(user);
        canvas.enlargeCanvas(1, 60, WALLET, false);
        bytes memory overlay = new bytes(450);
        _setPixel(overlay, 10, 10, 60); // erases the embedded base pixel
        _setPixel(overlay, 0, 0, 60); // paints in the new margin
        assertLe(2, got);
        canvas.setTransformBitmap(1, overlay);
        vm.stopPrank();

        string memory svg = _extractSvg(_decodeTokenURI(renderer.tokenURI(1)));
        assertTrue(_contains(svg, "M0 0h1v1h-1z"));
        assertFalse(_contains(svg, "M10 10h1v1h-1z"));
    }

    function testBlankCanvas() public {
        _mintRealTo(user, 1);
        canvas.setBlankCanvasPrice(0);
        vm.prank(user);
        canvas.clearBase(1, WALLET, false);
        string memory json = _decodeTokenURI(renderer.tokenURI(1));
        assertTrue(_contains(json, '"trait_type":"Blank Canvas","value":"Yes"'));
        // Pixel Count still describes the original art, the image is empty.
        assertFalse(_contains(json, '"trait_type":"Pixel Count","value":0'));
        string memory svg = _extractSvg(json);
        assertFalse(_contains(svg, "<path"));
        assertTrue(_contains(svg, "</svg>"));
    }

    function testZombieOn60() public {
        MockZombie zombie = new MockZombie();
        canvas.setZombieContract(INormiesZombie(address(zombie)));
        renderer.setZombieContract(INormiesZombie(address(zombie)));
        _mintRealTo(user, 1);
        bytes memory zart = new bytes(200);
        _setPixel(zart, 0, 0, 40);
        zombie.setZombie(1, zart);
        canvas.setEnlargePrice(60, 0);
        vm.prank(user);
        canvas.enlargeCanvas(1, 60, WALLET, false);

        string memory json = _decodeTokenURI(renderer.tokenURI(1));
        assertTrue(_contains(json, '"trait_type":"Type","value":"Zombie"'));
        assertTrue(_contains(json, '"trait_type":"Pixel Count","value":1'));
        assertTrue(_contains(json, '"trait_type":"Canvas Size","value":"60x60"'));
        string memory svg = _extractSvg(json);
        assertTrue(_contains(svg, "M10 10h1v1h-1z"));
    }

    function testLegacyOverlayRendersThroughV6() public {
        _mintRealTo(user, 1);
        uint256 got = _giveTokenPixelsV1(user, 1, 48);
        canvasV1.setPaused(false);
        vm.prank(user);
        canvasV1.setTransformBitmap(1, _createBitmapWithPixels(got));
        canvasV1.setPaused(true);
        string memory json = _decodeTokenURI(renderer.tokenURI(1));
        assertTrue(_contains(json, '"trait_type":"Customized","value":"Yes"'));
    }

    function testRendersWithFreshRenderer() public {
        NormiesRendererV6 bare = new NormiesRendererV6(
            INormiesStorage(address(normiesStorage)), INormiesCanvasStorageV2(address(storageV2))
        );
        _mintRealTo(user, 1);
        string memory json = _decodeTokenURI(bare.tokenURI(1));
        assertTrue(_contains(json, '"trait_type":"Level","value":1'));
        assertTrue(_contains(json, '"trait_type":"Canvas Size","value":"40x40"'));
    }

    function testGasCheckerboard80() public {
        _mintRealTo(user, 1);
        canvas.setEnlargePrice(80, 0);
        vm.prank(user);
        canvas.enlargeCanvas(1, 80, WALLET, false);
        // Owner writes straight to storage (bypassing the ceiling) to build the worst case.
        bytes memory board = new bytes(800);
        for (uint256 i; i < 800; i++) {
            board[i] = (i / 10) % 2 == 0 ? bytes1(0xAA) : bytes1(0x55);
        }
        storageV2.setTransformedImageData(1, board);

        uint256 gasBefore = gasleft();
        string memory uri = renderer.tokenURI(1);
        uint256 used = gasBefore - gasleft();
        assertGt(bytes(uri).length, 10_000);
        assertLt(used, 30_000_000);
    }

    // ──────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory b;
        while (v > 0) {
            b = abi.encodePacked(bytes1(uint8(48 + (v % 10))), b);
            v /= 10;
        }
        return string(b);
    }

    function _numberAfter(string memory json, bytes memory needle) internal pure returns (uint256 value) {
        bytes memory j = bytes(json);
        for (uint256 i; i <= j.length - needle.length; i++) {
            bool found = true;
            for (uint256 k; k < needle.length; k++) {
                if (j[i + k] != needle[k]) {
                    found = false;
                    break;
                }
            }
            if (!found) continue;
            uint256 p = i + needle.length;
            while (j[p] >= "0" && j[p] <= "9") {
                value = value * 10 + (uint8(j[p]) - 48);
                p++;
            }
            return value;
        }
        revert("needle not found");
    }
}
