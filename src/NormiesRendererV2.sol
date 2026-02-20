// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesRenderer } from "./interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "./interfaces/INormiesStorage.sol";
import { NormiesTraits } from "./NormiesTraits.sol";
import { LibString } from "solady/utils/LibString.sol";
import { Base64 } from "solady/utils/Base64.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";

/**
 * @title NormiesRendererV2
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @dev Update: V2 renderer with static noise SVG (no animation) for pre-reveal
 */
contract NormiesRendererV2 is INormiesRenderer, Ownable, Lifebuoy {
    using LibString for uint256;

    INormiesStorage public storageContract;

    error TokenDataNotSet(uint256 tokenId);

    constructor(INormiesStorage _storage) Ownable() Lifebuoy() {
        storageContract = _storage;
    }

    function tokenURI(uint256 tokenId) external view override returns (string memory) {
        require(storageContract.isTokenDataSet(tokenId), TokenDataNotSet(tokenId));

        if (!storageContract.isRevealed()) {
            return _buildPreRevealMetadata(tokenId);
        }

        bytes memory imageData = storageContract.getTokenRawImageData(tokenId);
        bytes8 traits = storageContract.getTokenTraits(tokenId);
        string memory svg = _renderSvg(imageData);
        string memory svgBase64 = Base64.encode(bytes(svg));

        bytes memory part1 = abi.encodePacked('{"name":"Normie #', tokenId.toString(), '","attributes":[');
        bytes memory part2 = abi.encodePacked(
            _buildAttributes(traits), '],"image":"data:image/svg+xml;base64,', svgBase64, '","animation_url":"'
        );
        bytes memory part3 = abi.encodePacked(_buildAnimationUrl(imageData), '"}');
        string memory json = string(abi.encodePacked(part1, part2, part3));

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    /**
     * @notice Builds pre-reveal metadata with static noise image
     * @param tokenId The token ID (used as seed for unique noise pattern)
     * @return Complete data URI with pre-reveal JSON metadata
     */
    function _buildPreRevealMetadata(uint256 tokenId) internal pure returns (string memory) {
        string memory svg = _renderNoiseSvg(tokenId);
        string memory svgBase64 = Base64.encode(bytes(svg));

        bytes memory part1 = abi.encodePacked('{"name":"Normie #', tokenId.toString(), '","attributes":[');
        bytes memory part2 = abi.encodePacked(
            '{"trait_type":"Revealed","value":"No"}',
            '],"image":"data:image/svg+xml;base64,',
            svgBase64,
            '","animation_url":"data:image/svg+xml;base64,'
        );
        bytes memory part3 = abi.encodePacked(svgBase64, '"}');
        string memory json = string(abi.encodePacked(part1, part2, part3));

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    /**
     * @notice Builds the JSON attributes array from packed trait indices
     * @param traits Packed bytes8 trait indices
     * @return The JSON attributes array contents (without surrounding brackets)
     */
    function _buildAttributes(bytes8 traits) internal pure returns (string memory) {
        bytes memory part1 = abi.encodePacked(
            _traitJson("Type", NormiesTraits.typeName(uint8(traits[0]))),
            ",",
            _traitJson("Gender", NormiesTraits.genderName(uint8(traits[1]))),
            ",",
            _traitJson("Age", NormiesTraits.ageName(uint8(traits[2]))),
            ",",
            _traitJson("Hair Style", NormiesTraits.hairStyleName(uint8(traits[3])))
        );
        bytes memory part2 = abi.encodePacked(
            ",",
            _traitJson("Facial Feature", NormiesTraits.facialFeatureName(uint8(traits[4]))),
            ",",
            _traitJson("Eyes", NormiesTraits.eyesName(uint8(traits[5]))),
            ",",
            _traitJson("Expression", NormiesTraits.expressionName(uint8(traits[6]))),
            ",",
            _traitJson("Accessory", NormiesTraits.accessoryName(uint8(traits[7]))),
            ",",
            _numericTraitJson("Level", 1) // ◕⩊◕
        );
        return string(abi.encodePacked(part1, part2));
    }

    /**
     * @notice Formats a single trait as a JSON object
     * @param traitType The trait category name
     * @param value The trait value
     * @return JSON string: {"trait_type":"...","value":"..."}
     */
    function _traitJson(string memory traitType, string memory value) internal pure returns (string memory) {
        return string(abi.encodePacked('{"trait_type":"', traitType, '","value":"', value, '"}'));
    }

    /**
     * @notice Formats a numeric trait as a JSON object with display_type "number"
     * @param traitType The trait category name
     * @param value The numeric trait value
     * @return JSON string: {"display_type":"number","trait_type":"...","value":N}
     */
    function _numericTraitJson(string memory traitType, uint256 value) internal pure returns (string memory) {
        return string(
            abi.encodePacked('{"display_type":"number","trait_type":"', traitType, '","value":', value.toString(), "}")
        );
    }

    /**
     * @notice Builds an HTML page that renders the bitmap on a canvas via fillRect for pixel-perfect output
     * @param imageData The raw 200-byte monochrome bitmap (40x40, 1 bit/pixel, MSB first)
     * @return A data:text/html;base64 URI
     * @dev Draws each "on" pixel as a 50x50 filled rect on a 2000x2000 canvas, avoiding SVG rasterisation artifacts
     */
    function _buildAnimationUrl(bytes memory imageData) internal pure returns (string memory) {
        bytes memory html = abi.encodePacked(
            "<html><body style='margin:0;overflow:hidden;width:100vw;height:100vh;"
            "display:flex;align-items:center;justify-content:center;background:#e3e5e4'>"
            "<canvas id='c' width='2000' height='2000' style='image-rendering:pixelated;width:min(100vw,100vh);height:min(100vw,100vh)'></canvas>"
            "<script>var h='",
            LibString.toHexStringNoPrefix(imageData)
        );
        html = abi.encodePacked(
            html,
            "';var c=document.getElementById('c').getContext('2d');"
            "c.fillStyle='#e3e5e4';c.fillRect(0,0,2000,2000);c.fillStyle='#48494b';"
            "for(var y=0;y<40;y++)for(var x=0;x<40;x++){var i=y*40+x,b=parseInt(h.substr((i>>3)*2,2),16);"
            "if((b>>(7-(i&7)))&1)c.fillRect(x*50,y*50,50,50)}" "</script></body></html>"
        );
        return string(abi.encodePacked("data:text/html;base64,", Base64.encode(html)));
    }

    /**
     * @notice Renders a static 40×40 grayscale noise SVG using path-grouped shades
     * @param seed Unique seed per token for deterministic noise pattern
     * @return The complete SVG string (~25 KB, 32 DOM elements)
     * @dev Quantises 1600 random pixels into 32 grayscale shades (62-217), then emits
     *      one <path> per shade. Each pixel is an `M{x},{y}h1v1h-1z` subpath command.
     */
    function _renderNoiseSvg(uint256 seed) internal pure returns (string memory) {
        bytes memory buf = new bytes(35_000);
        uint256 cursor;
        uint256 rand = seed;

        // Pass 1: compute shade index (0-31) for each pixel
        bytes memory shades = new bytes(1600);
        for (uint256 i; i < 1600; i++) {
            if (i & 31 == 0) rand = uint256(keccak256(abi.encodePacked(rand)));
            shades[i] = bytes1(uint8(bytes32(rand)[i & 31]) & 31);
        }

        // SVG header
        cursor = _noiseWriteStr(
            buf,
            cursor,
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40" '
            'width="800" height="800" shape-rendering="crispEdges">'
        );

        // Pass 2: one <path> per shade, collecting all matching pixels
        for (uint256 s; s < 32; s++) {
            bool hasPixels;
            for (uint256 i; i < 1600; i++) {
                if (uint8(shades[i]) != s) continue;
                if (!hasPixels) {
                    hasPixels = true;
                    uint256 g = 62 + s * 5;
                    cursor = _noiseWriteStr(buf, cursor, '<path fill="#');
                    cursor = _noiseWriteHexByte(buf, cursor, g);
                    cursor = _noiseWriteHexByte(buf, cursor, g);
                    cursor = _noiseWriteHexByte(buf, cursor, g);
                    cursor = _noiseWriteStr(buf, cursor, '" d="');
                }
                cursor = _noiseWriteByte(buf, cursor, 0x4D); // M
                cursor = _noiseWriteUint(buf, cursor, i % 40);
                cursor = _noiseWriteByte(buf, cursor, 0x2C); // ,
                cursor = _noiseWriteUint(buf, cursor, i / 40);
                cursor = _noiseWriteStr(buf, cursor, "h1v1h-1z");
            }
            if (hasPixels) {
                cursor = _noiseWriteStr(buf, cursor, '"/>');
            }
        }

        cursor = _noiseWriteStr(buf, cursor, "</svg>");
        assembly {
            mstore(buf, cursor)
        }
        return string(buf);
    }

    // ─── Buffer writers for noise SVG (no memory reallocation) ───────────

    function _noiseWriteStr(bytes memory buf, uint256 cursor, string memory s) internal pure returns (uint256) {
        bytes memory sb = bytes(s);
        uint256 len = sb.length;
        assembly {
            let dst := add(add(buf, 32), cursor)
            let src := add(sb, 32)
            for { let i := 0 } lt(i, len) { i := add(i, 32) } {
                mstore(add(dst, i), mload(add(src, i)))
            }
        }
        return cursor + len;
    }

    function _noiseWriteByte(bytes memory buf, uint256 cursor, uint8 b) internal pure returns (uint256) {
        assembly {
            mstore8(add(add(buf, 32), cursor), b)
        }
        return cursor + 1;
    }

    function _noiseWriteHexByte(bytes memory buf, uint256 cursor, uint256 b) internal pure returns (uint256) {
        assembly {
            let ptr := add(add(buf, 32), cursor)
            let hi := and(shr(4, b), 0x0F)
            let lo := and(b, 0x0F)
            mstore8(ptr, add(add(hi, 0x30), mul(gt(hi, 9), 0x27)))
            mstore8(add(ptr, 1), add(add(lo, 0x30), mul(gt(lo, 9), 0x27)))
        }
        return cursor + 2;
    }

    function _noiseWriteUint(bytes memory buf, uint256 cursor, uint256 val) internal pure returns (uint256) {
        if (val == 0) {
            return _noiseWriteByte(buf, cursor, 0x30);
        }
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

    /**
     * @notice Renders a 40x40 monochrome bitmap as a 1000x1000 SVG
     * @param imageData The raw 200-byte bitmap (1 bit per pixel, MSB first)
     * @return The SVG string
     * @dev Uses row-scanning with run-length encoding to merge consecutive
     *      "on" pixels into single <rect> elements for efficiency
     */
    function _renderSvg(bytes memory imageData) internal pure returns (string memory) {
        bytes memory svg = abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000" viewBox="0 0 40 40" '
            'shape-rendering="crispEdges"><rect width="40" height="40" fill="#e3e5e4"/>'
        );

        for (uint256 y = 0; y < 40; y++) {
            for (uint256 x = 0; x < 40; x++) {
                if (_isPixelOn(imageData, x, y)) {
                    svg = abi.encodePacked(
                        svg, '<rect x="', x.toString(), '" y="', y.toString(), '" width="1" height="1" fill="#48494b"/>'
                    );
                }
            }
        }

        svg = abi.encodePacked(svg, "</svg>");
        return string(svg);
    }

    /**
     * @notice Checks if a pixel is "on" in the bitmap
     * @param imageData The raw bitmap bytes
     * @param x The x coordinate (0-39)
     * @param y The y coordinate (0-39)
     * @return True if the pixel is set (#48494b)
     */
    function _isPixelOn(bytes memory imageData, uint256 x, uint256 y) internal pure returns (bool) {
        uint256 flatIndex = y * 40 + x;
        uint256 byteIndex = flatIndex >> 3;
        uint256 bitPos = 7 - (flatIndex & 7);
        return (uint8(imageData[byteIndex]) >> bitPos) & 1 == 1;
    }

    /**
     * @notice Sets the storage contract
     * @param _storage The new storage contract
     */
    function setStorageContract(INormiesStorage _storage) external onlyOwner {
        storageContract = _storage;
    }
}
