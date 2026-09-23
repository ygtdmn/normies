// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { LibBit } from "solady/utils/LibBit.sol";

/**
 * @title NormiesBitmap
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @notice Pure helpers for square monochrome bitmaps: 1 bit per pixel, row-major, MSB first.
 *         An n x n grid occupies ceil(n*n/8) bytes. When n*n is not a multiple of 8 the low bits of the final
 *         byte are padding and must be zero (50x50 and 70x70 carry 4 padding bits).
 */
library NormiesBitmap {
    error BitmapLengthMismatch(uint256 expected, uint256 actual);
    error InvalidGridSize(uint256 size);

    uint256 internal constant BASE_GRID = 40;

    /// @notice Number of bytes needed to store an n x n bitmap.
    function bytesForGrid(uint256 n) internal pure returns (uint256) {
        return (n * n + 7) >> 3;
    }

    /// @notice Number of unused low bits in the final byte of an n x n bitmap.
    function paddingBits(uint256 n) internal pure returns (uint256) {
        return (8 - ((n * n) & 7)) & 7;
    }

    /// @notice An all-zero n x n bitmap.
    function empty(uint256 n) internal pure returns (bytes memory) {
        return new bytes(bytesForGrid(n));
    }

    /// @notice Counts every set bit regardless of grid semantics (padding bits included).
    function countBits(bytes memory data) internal pure returns (uint256 count) {
        uint256 len = data.length;
        uint256 full = len >> 5;
        uint256 ptr;
        assembly ("memory-safe") {
            ptr := add(data, 0x20)
        }
        for (uint256 i; i < full; i++) {
            uint256 w;
            assembly ("memory-safe") {
                w := mload(add(ptr, shl(5, i)))
            }
            count += LibBit.popCount(w);
        }
        uint256 rem = len & 31;
        if (rem != 0) {
            uint256 w;
            assembly ("memory-safe") {
                w := mload(add(ptr, shl(5, full)))
            }
            count += LibBit.popCount(w >> ((32 - rem) << 3));
        }
    }

    /// @notice Counts "on" pixels of an n x n bitmap, ignoring padding bits. Reverts on a length mismatch.
    function countPixels(bytes memory data, uint256 n) internal pure returns (uint256 count) {
        uint256 expected = bytesForGrid(n);
        if (data.length != expected) revert BitmapLengthMismatch(expected, data.length);
        count = countBits(data);
        uint256 pad = paddingBits(n);
        if (pad != 0) {
            count -= LibBit.popCount(uint8(data[expected - 1]) & ((1 << pad) - 1));
        }
    }

    /// @notice True when the padding bits of the final byte are all zero.
    function hasCleanPadding(bytes memory data, uint256 n) internal pure returns (bool) {
        uint256 pad = paddingBits(n);
        if (pad == 0 || data.length == 0) return true;
        return uint8(data[data.length - 1]) & ((1 << pad) - 1) == 0;
    }

    /// @notice XOR composite of two equally sized bitmaps.
    function composite(bytes memory base, bytes memory overlay) internal pure returns (bytes memory result) {
        uint256 len = base.length;
        if (overlay.length != len) revert BitmapLengthMismatch(len, overlay.length);
        result = new bytes(len);
        assembly ("memory-safe") {
            let b := add(base, 0x20)
            let o := add(overlay, 0x20)
            let r := add(result, 0x20)
            for { let i := 0 } lt(i, len) { i := add(i, 0x20) } {
                mstore(add(r, i), xor(mload(add(b, i)), mload(add(o, i))))
            }
        }
    }

    /// @notice Reads pixel (x, y) of an n x n bitmap.
    function isPixelOn(bytes memory data, uint256 x, uint256 y, uint256 n) internal pure returns (bool) {
        uint256 flat = y * n + x;
        return (uint8(data[flat >> 3]) >> (7 - (flat & 7))) & 1 == 1;
    }

    /// @notice Copies a fromN x fromN bitmap into the centre of a toN x toN bitmap (offset (toN - fromN) / 2).
    function embedCentered(bytes memory src, uint256 fromN, uint256 toN) internal pure returns (bytes memory out) {
        if (toN < fromN) revert InvalidGridSize(toN);
        uint256 expected = bytesForGrid(fromN);
        if (src.length != expected) revert BitmapLengthMismatch(expected, src.length);

        if (fromN == toN) {
            out = new bytes(expected);
            assembly ("memory-safe") {
                mcopy(add(out, 0x20), add(src, 0x20), expected)
            }
            return out;
        }

        out = new bytes(bytesForGrid(toN));
        uint256 off = (toN - fromN) >> 1;
        uint256 total = fromN * fromN;
        for (uint256 i; i < expected; i++) {
            uint8 b = uint8(src[i]);
            if (b == 0) continue;
            uint256 flatBase = i << 3;
            for (uint256 bit; bit < 8; bit++) {
                if ((b >> (7 - bit)) & 1 == 0) continue;
                uint256 flat = flatBase + bit;
                if (flat >= total) break;
                uint256 o = (flat / fromN + off) * toN + (flat % fromN) + off;
                out[o >> 3] = bytes1(uint8(out[o >> 3]) | uint8(0x80 >> (o & 7)));
            }
        }
    }
}
