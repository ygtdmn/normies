// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import { Test } from "forge-std/src/Test.sol";
import { console2 } from "forge-std/src/console2.sol";
import { Base64 } from "solady/utils/Base64.sol";

/// @title NoiseRenderer
/// @notice Generates an animated 40×40 grayscale block noise SVG on-chain
/// @dev Uses pre-allocated buffer with cursor to avoid O(n²) abi.encodePacked copies
contract NoiseRenderer is Test {
    /// @notice Render animated noise SVG using CSS keyframe animations
    /// @param seed Unique seed (tokenId, blockhash, etc.)
    /// @return svg The complete SVG markup
    function test_renderImage(uint256 seed) external pure returns (string memory svg) {
        // ── CSS keyframe approach ──
        // 32 unique @keyframes × 8 delay offsets = 256 visual patterns
        // 40×40 grid = 1600 cells, viewBox 40×40 → 800×800
        // ~58 keccak256 calls vs 12,800 in per-cell approach

        bytes memory buf = new bytes(100_000);
        uint256 cursor;
        uint256 rand = seed;

        // ── SVG header + default rect animation styles ──
        cursor = _writeStr(
            buf,
            cursor,
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40" '
            'width="800" height="800" shape-rendering="crispEdges"><style>'
            "rect{animation-duration:.8s;animation-timing-function:step-end;"
            "animation-iteration-count:infinite}"
        );

        // ── Animation name classes: .n0{animation-name:n0} … .n31{…} ──
        for (uint256 i; i < 32; i++) {
            cursor = _writeStr(buf, cursor, ".n");
            cursor = _writeUint(buf, cursor, i);
            cursor = _writeStr(buf, cursor, "{animation-name:n");
            cursor = _writeUint(buf, cursor, i);
            cursor = _writeByte(buf, cursor, 0x7D); // }
        }

        // ── Delay classes: .d1{animation-delay:-.1s} … .d7{…} ──
        for (uint256 d = 1; d < 8; d++) {
            cursor = _writeStr(buf, cursor, ".d");
            cursor = _writeByte(buf, cursor, uint8(0x30 + d));
            cursor = _writeStr(buf, cursor, "{animation-delay:-.");
            cursor = _writeByte(buf, cursor, uint8(0x30 + d));
            cursor = _writeStr(buf, cursor, "s}");
        }

        // ── 32 @keyframes definitions (8 hashes, 4 animations per hash) ──
        for (uint256 i; i < 32; i++) {
            if (i & 3 == 0) rand = uint256(keccak256(abi.encodePacked(rand)));

            cursor = _writeStr(buf, cursor, "@keyframes n");
            cursor = _writeUint(buf, cursor, i);
            cursor = _writeByte(buf, cursor, 0x7B); // {

            for (uint256 f; f < 8; f++) {
                cursor = _writeUint(buf, cursor, f * 125 / 10); // 0,12,25,37,50,62,75,87
                cursor = _writeStr(buf, cursor, "%{fill:#");
                uint256 g = 62 + (uint8(bytes32(rand)[(i & 3) * 8 + f]) % 162);
                cursor = _writeHexByte(buf, cursor, g);
                cursor = _writeHexByte(buf, cursor, g);
                cursor = _writeHexByte(buf, cursor, g);
                cursor = _writeByte(buf, cursor, 0x7D); // }
            }
            cursor = _writeByte(buf, cursor, 0x7D); // }
        }

        cursor = _writeStr(buf, cursor, "</style>");

        // ── 1600 rects (50 hashes, 32 rects per hash) ──
        for (uint256 y; y < 40; y++) {
            for (uint256 x; x < 40; x++) {
                uint256 idx = y * 40 + x;
                if (idx & 31 == 0) rand = uint256(keccak256(abi.encodePacked(rand)));

                uint256 pack = uint8(bytes32(rand)[idx & 31]);
                uint256 animIdx = pack >> 3; // 0–31
                uint256 delayIdx = pack & 7; // 0–7

                cursor = _writeStr(buf, cursor, '<rect x="');
                cursor = _writeUint(buf, cursor, x);
                cursor = _writeStr(buf, cursor, '" y="');
                cursor = _writeUint(buf, cursor, y);
                cursor = _writeStr(buf, cursor, '" width="1" height="1" class="n');
                cursor = _writeUint(buf, cursor, animIdx);
                if (delayIdx > 0) {
                    cursor = _writeStr(buf, cursor, " d");
                    cursor = _writeByte(buf, cursor, uint8(0x30 + delayIdx)); // ASCII digit
                }
                cursor = _writeStr(buf, cursor, '"/>');
            }
        }

        cursor = _writeStr(buf, cursor, "</svg>");
        assembly {
            mstore(buf, cursor)
        }

        svg = string(buf);
        console2.log(Base64.encode(bytes(svg)));
    }

    /// @notice Render a single static noise frame (cheaper)
    function renderStatic(uint256 seed) external pure returns (string memory svg) {
        bytes memory buf = new bytes(120_000);
        uint256 cursor;

        cursor = _writeStr(
            buf, cursor, '<svg xmlns="http://www.w3.org/2000/svg" width="800" height="800" viewBox="0 0 800 800">'
        );

        uint256 rand = seed;

        for (uint256 y; y < 40; y++) {
            for (uint256 x; x < 40; x++) {
                rand = uint256(keccak256(abi.encodePacked(rand)));
                uint256 g = 62 + (rand % 162);

                cursor = _writeStr(buf, cursor, '<rect x="');
                cursor = _writeUint(buf, cursor, x * 20);
                cursor = _writeStr(buf, cursor, '" y="');
                cursor = _writeUint(buf, cursor, y * 20);
                cursor = _writeStr(buf, cursor, '" width="20" height="20" fill="rgb(');
                cursor = _writeUint(buf, cursor, g);
                cursor = _writeByte(buf, cursor, 0x2C);
                cursor = _writeUint(buf, cursor, g);
                cursor = _writeByte(buf, cursor, 0x2C);
                cursor = _writeUint(buf, cursor, g);
                cursor = _writeStr(buf, cursor, ')"/>');
            }
        }

        cursor = _writeStr(buf, cursor, "</svg>");

        assembly {
            mstore(buf, cursor)
        }

        svg = string(buf);
    }

    // ─── Low-level buffer writers (no memory reallocation) ──────────────

    /// @dev Write a string literal into buf at cursor, return new cursor
    function _writeStr(bytes memory buf, uint256 cursor, string memory s) internal pure returns (uint256) {
        bytes memory sb = bytes(s);
        uint256 len = sb.length;
        assembly {
            let dst := add(add(buf, 32), cursor)
            let src := add(sb, 32)
            // Copy 32 bytes at a time
            for { let i := 0 } lt(i, len) { i := add(i, 32) } {
                mstore(add(dst, i), mload(add(src, i)))
            }
        }
        return cursor + len;
    }

    /// @dev Write a single byte
    function _writeByte(bytes memory buf, uint256 cursor, uint8 b) internal pure returns (uint256) {
        assembly {
            mstore8(add(add(buf, 32), cursor), b)
        }
        return cursor + 1;
    }

    /// @dev Write 2 lowercase hex ASCII chars for a byte value (e.g., 171 → "ab")
    function _writeHexByte(bytes memory buf, uint256 cursor, uint256 b) internal pure returns (uint256) {
        assembly {
            let ptr := add(add(buf, 32), cursor)
            let hi := and(shr(4, b), 0x0F)
            let lo := and(b, 0x0F)
            // 0-9 → 0x30-0x39 ('0'-'9'), 10-15 → 0x61-0x66 ('a'-'f')
            mstore8(ptr, add(add(hi, 0x30), mul(gt(hi, 9), 0x27)))
            mstore8(add(ptr, 1), add(add(lo, 0x30), mul(gt(lo, 9), 0x27)))
        }
        return cursor + 2;
    }

    /// @dev Write uint as decimal ASCII (values 0–999)
    function _writeUint(bytes memory buf, uint256 cursor, uint256 val) internal pure returns (uint256) {
        if (val == 0) {
            return _writeByte(buf, cursor, 0x30);
        }
        // Max 3 digits for our use case (0–800)
        uint256 temp = val;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        uint256 end = cursor + digits;
        uint256 pos = end;
        assembly {
            let ptr := add(buf, 32)
            for { } gt(val, 0) { } {
                pos := sub(pos, 1)
                mstore8(add(ptr, pos), add(48, mod(val, 10)))
                val := div(val, 10)
            }
        }
        return end;
    }
}
