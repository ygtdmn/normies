// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { NormiesBitmap } from "../src/NormiesBitmap.sol";

contract BitmapHarness {
    function bytesForGrid(uint256 n) external pure returns (uint256) {
        return NormiesBitmap.bytesForGrid(n);
    }

    function paddingBits(uint256 n) external pure returns (uint256) {
        return NormiesBitmap.paddingBits(n);
    }

    function countBits(bytes memory d) external pure returns (uint256) {
        return NormiesBitmap.countBits(d);
    }

    function countPixels(bytes memory d, uint256 n) external pure returns (uint256) {
        return NormiesBitmap.countPixels(d, n);
    }

    function hasCleanPadding(bytes memory d, uint256 n) external pure returns (bool) {
        return NormiesBitmap.hasCleanPadding(d, n);
    }

    function composite(bytes memory a, bytes memory b) external pure returns (bytes memory) {
        return NormiesBitmap.composite(a, b);
    }

    function isPixelOn(bytes memory d, uint256 x, uint256 y, uint256 n) external pure returns (bool) {
        return NormiesBitmap.isPixelOn(d, x, y, n);
    }

    function embedCentered(bytes memory s, uint256 f, uint256 t) external pure returns (bytes memory) {
        return NormiesBitmap.embedCentered(s, f, t);
    }
}

contract NormiesBitmapTest is Test {
    BitmapHarness h;

    function setUp() public {
        h = new BitmapHarness();
    }

    function testBytesForGridTable() public view {
        assertEq(h.bytesForGrid(40), 200);
        assertEq(h.bytesForGrid(50), 313);
        assertEq(h.bytesForGrid(60), 450);
        assertEq(h.bytesForGrid(70), 613);
        assertEq(h.bytesForGrid(80), 800);
    }

    function testPaddingBitsTable() public view {
        assertEq(h.paddingBits(40), 0);
        assertEq(h.paddingBits(50), 4);
        assertEq(h.paddingBits(60), 0);
        assertEq(h.paddingBits(70), 4);
        assertEq(h.paddingBits(80), 0);
    }

    function testCountBitsWordAndTail() public view {
        bytes memory d = new bytes(45); // one full word + 13 tail bytes
        d[0] = 0xFF;
        d[31] = 0x01;
        d[32] = 0x80;
        d[44] = 0x0F;
        assertEq(h.countBits(d), 8 + 1 + 1 + 4);
    }

    function testCountPixelsMasksPadding() public view {
        bytes memory d = new bytes(313);
        d[0] = 0xFF;
        d[312] = 0xFF; // top 4 bits are real pixels, low 4 bits are padding
        assertEq(h.countBits(d), 16);
        assertEq(h.countPixels(d, 50), 12);
        assertFalse(h.hasCleanPadding(d, 50));
        d[312] = 0xF0;
        assertTrue(h.hasCleanPadding(d, 50));
        assertTrue(h.hasCleanPadding(new bytes(200), 40));
    }

    function testCountPixelsLengthMismatchReverts() public {
        vm.expectRevert(abi.encodeWithSelector(NormiesBitmap.BitmapLengthMismatch.selector, 200, 199));
        h.countPixels(new bytes(199), 40);
    }

    function testCompositeXor() public view {
        bytes memory a = new bytes(200);
        bytes memory b = new bytes(200);
        a[0] = 0xF0;
        b[0] = 0xFF;
        a[199] = 0x01;
        bytes memory r = h.composite(a, b);
        assertEq(r.length, 200);
        assertEq(uint8(r[0]), 0x0F);
        assertEq(uint8(r[199]), 0x01);
        assertEq(h.countBits(r), 5);
    }

    function testCompositeLengthMismatchReverts() public {
        vm.expectRevert(abi.encodeWithSelector(NormiesBitmap.BitmapLengthMismatch.selector, 200, 313));
        h.composite(new bytes(200), new bytes(313));
    }

    function testEmbedCenteredMovesPixels() public view {
        bytes memory src = new bytes(200);
        _set(src, 0, 0, 40);
        _set(src, 39, 39, 40);
        _set(src, 3, 4, 40);
        bytes memory out = h.embedCentered(src, 40, 60);
        assertEq(out.length, 450);
        assertEq(h.countBits(out), 3);
        assertTrue(h.isPixelOn(out, 10, 10, 60));
        assertTrue(h.isPixelOn(out, 49, 49, 60));
        assertTrue(h.isPixelOn(out, 13, 14, 60));
        assertFalse(h.isPixelOn(out, 0, 0, 60));
    }

    function testEmbedCenteredAllSizesPreserveCount() public view {
        bytes memory src = new bytes(200);
        for (uint256 i; i < 200; i += 7) {
            src[i] = 0xA5;
        }
        uint256 count = h.countBits(src);
        uint256[4] memory sizes = [uint256(50), 60, 70, 80];
        for (uint256 i; i < 4; i++) {
            bytes memory out = h.embedCentered(src, 40, sizes[i]);
            assertEq(out.length, h.bytesForGrid(sizes[i]));
            assertEq(h.countPixels(out, sizes[i]), count);
            assertTrue(h.hasCleanPadding(out, sizes[i]));
        }
    }

    function testEmbedCenteredIdentityCopies() public view {
        bytes memory src = new bytes(200);
        src[5] = 0x3C;
        bytes memory out = h.embedCentered(src, 40, 40);
        assertEq(keccak256(out), keccak256(src));
    }

    function testEmbedCenteredRejectsShrink() public {
        vm.expectRevert(abi.encodeWithSelector(NormiesBitmap.InvalidGridSize.selector, 40));
        h.embedCentered(new bytes(313), 50, 40);
    }

    function _set(bytes memory bitmap, uint256 x, uint256 y, uint256 n) internal pure {
        uint256 flat = y * n + x;
        bitmap[flat >> 3] = bytes1(uint8(bitmap[flat >> 3]) | uint8(0x80 >> (flat & 7)));
    }
}
