// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesRenderer } from "./interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "./interfaces/INormiesStorage.sol";
import { NormiesTraits } from "./NormiesTraits.sol";
import { LibString } from "solady/utils/LibString.sol";
import { Base64 } from "solady/utils/Base64.sol";
import { DynamicBufferLib } from "solady/utils/DynamicBufferLib.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";

/**
 * @title NormiesRendererV3
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @dev Update: V3 Renderer - Removes pre-reveal logic, adds Pixel Count trait, uses DynamicBufferLib
 */
contract NormiesRendererV3 is INormiesRenderer, Ownable, Lifebuoy {
    using LibString for uint256;
    using DynamicBufferLib for DynamicBufferLib.DynamicBuffer;

    INormiesStorage public storageContract;

    error TokenDataNotSet(uint256 tokenId);

    constructor(INormiesStorage _storage) Ownable() Lifebuoy() {
        storageContract = _storage;
    }

    function tokenURI(uint256 tokenId) external view override returns (string memory) {
        require(storageContract.isTokenDataSet(tokenId), TokenDataNotSet(tokenId));

        bytes memory imageData = storageContract.getTokenRawImageData(tokenId);
        bytes8 traits = storageContract.getTokenTraits(tokenId);
        string memory svg = _renderSvg(imageData);
        string memory svgBase64 = Base64.encode(bytes(svg));

        bytes memory part1 = abi.encodePacked('{"name":"Normie #', tokenId.toString(), '","attributes":[');
        bytes memory part2 = abi.encodePacked(
            _buildAttributes(traits),
            ",",
            _numericTraitJson("Pixel Count", _countPixels(imageData)),
            '],"image":"data:image/svg+xml;base64,',
            svgBase64,
            '","animation_url":"'
        );
        bytes memory part3 = abi.encodePacked(_buildAnimationUrl(imageData), '"}');
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
     * @notice Counts the number of "on" pixels in the bitmap
     * @param imageData The raw 200-byte monochrome bitmap (40x40, 1 bit/pixel, MSB first)
     * @return count The number of set bits (on pixels)
     */
    function _countPixels(bytes memory imageData) internal pure returns (uint256 count) {
        for (uint256 i; i < 200; i++) {
            uint8 b = uint8(imageData[i]);
            while (b != 0) {
                b &= b - 1;
                count++;
            }
        }
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
     * @notice Renders a 40x40 monochrome bitmap as a 1000x1000 SVG
     * @param imageData The raw 200-byte bitmap (1 bit per pixel, MSB first)
     * @return The SVG string
     * @dev Uses DynamicBufferLib to avoid O(n²) abi.encodePacked copies.
     *      Row-scan RLE merges consecutive "on" pixels into wider rects.
     */
    function _renderSvg(bytes memory imageData) internal pure returns (string memory) {
        DynamicBufferLib.DynamicBuffer memory buf;
        buf.reserve(50_000);

        buf.p(
            '<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000" viewBox="0 0 40 40" '
            'shape-rendering="crispEdges"><rect width="40" height="40" fill="#e3e5e4"/>'
        );

        for (uint256 y; y < 40; y++) {
            uint256 x;
            while (x < 40) {
                if (_isPixelOn(imageData, x, y)) {
                    uint256 runStart = x;
                    x++;
                    while (x < 40 && _isPixelOn(imageData, x, y)) {
                        x++;
                    }
                    buf.p(
                        '<rect x="',
                        bytes(runStart.toString()),
                        '" y="',
                        bytes(y.toString()),
                        '" width="',
                        bytes((x - runStart).toString()),
                        '" height="1" fill="#48494b"/>'
                    );
                } else {
                    x++;
                }
            }
        }

        buf.p("</svg>");
        return buf.s();
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
