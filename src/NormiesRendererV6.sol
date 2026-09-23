// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesRenderer } from "./interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "./interfaces/INormiesStorage.sol";
import { INormiesCanvasStorageV2 } from "./interfaces/INormiesCanvasStorageV2.sol";
import { INormiesZombie } from "./interfaces/INormiesZombie.sol";
import { INormiesLegendaryCanvas } from "./interfaces/INormiesLegendaryCanvas.sol";
import { NormiesTraits } from "./NormiesTraits.sol";
import { NormiesBitmap } from "./NormiesBitmap.sol";
import { LibString } from "solady/utils/LibString.sol";
import { Base64 } from "solady/utils/Base64.sol";
import { DynamicBufferLib } from "solady/utils/DynamicBufferLib.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";

/**
 * @title NormiesRendererV6
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @dev V5 renderer made grid-size aware: the base art (original or zombie) is embedded centred into the token's
 *      canvas, a blank canvas drops the base art, and the SVG is a single path of row runs.
 */
contract NormiesRendererV6 is INormiesRenderer, Ownable, Lifebuoy {
    using LibString for uint256;
    using DynamicBufferLib for DynamicBufferLib.DynamicBuffer;

    INormiesStorage public storageContract;
    /// @notice Storage V2: overlays, grid sizes, blank flags and pixel balances all come from here.
    INormiesCanvasStorageV2 public transformStorageContract;
    INormiesZombie public zombieContract;
    INormiesLegendaryCanvas public legendaryCanvasContract;

    error TokenDataNotSet(uint256 tokenId);

    uint256 internal constant CELL_PX = 50;

    constructor(INormiesStorage _storage, INormiesCanvasStorageV2 _transformStorage) Ownable() Lifebuoy() {
        storageContract = _storage;
        transformStorageContract = _transformStorage;
    }

    function tokenURI(uint256 tokenId) external view override returns (string memory) {
        bool zombie = address(zombieContract) != address(0) && zombieContract.isZombie(tokenId);
        uint256 size = _gridSize(tokenId);
        bool cleared = transformStorageContract.baseCleared(tokenId);
        bool transformed = transformStorageContract.isTransformed(tokenId);

        bytes memory raw;
        string memory attributesCore;
        if (zombie) {
            raw = zombieContract.getZombieBitmap(tokenId);
            attributesCore = string(
                abi.encodePacked(
                    zombieContract.getZombieAttributes(tokenId), ",", _numericTraitJson("Level", _getLevel(tokenId))
                )
            );
        } else {
            require(storageContract.isTokenDataSet(tokenId), TokenDataNotSet(tokenId));
            raw = storageContract.getTokenRawImageData(tokenId);
            attributesCore = _buildAttributes(storageContract.getTokenTraits(tokenId), tokenId);
        }

        bytes memory imageData =
            cleared ? NormiesBitmap.empty(size) : NormiesBitmap.embedCentered(raw, NormiesBitmap.BASE_GRID, size);
        if (transformed) {
            imageData = _applyOverlay(imageData, transformStorageContract.getTransformedImageData(tokenId), size);
        }

        // "Pixel Count" keeps the V5 meaning: original art for humans, the composited image for zombies.
        attributesCore = string(
            abi.encodePacked(
                _appendLegendaryCanvasTrait(tokenId, attributesCore),
                ",",
                _numericTraitJson(
                    "Pixel Count",
                    zombie
                        ? NormiesBitmap.countPixels(imageData, size)
                        : NormiesBitmap.countPixels(raw, NormiesBitmap.BASE_GRID)
                ),
                ",",
                _extraTraits(tokenId, size, transformed, cleared)
            )
        );
        return _buildTokenUri(tokenId, imageData, size, attributesCore);
    }

    function _extraTraits(
        uint256 tokenId,
        uint256 size,
        bool transformed,
        bool cleared
    ) internal view returns (bytes memory) {
        return abi.encodePacked(
            _numericTraitJson("Action Points", _getActionPoints(tokenId)),
            ',{"trait_type":"Customized","value":"',
            transformed ? "Yes" : "No",
            '"},',
            _traitJson("Canvas Size", string(abi.encodePacked(size.toString(), "x", size.toString()))),
            ',{"trait_type":"Blank Canvas","value":"',
            cleared ? "Yes" : "No",
            '"}'
        );
    }

    function _buildTokenUri(
        uint256 tokenId,
        bytes memory imageData,
        uint256 size,
        string memory attributes
    ) internal pure returns (string memory) {
        bytes memory head = abi.encodePacked(
            '{"name":"Normie #',
            tokenId.toString(),
            '","attributes":[',
            attributes,
            '],"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(_renderSvg(imageData, size)))
        );
        bytes memory json = abi.encodePacked(head, '","animation_url":"', _buildAnimationUrl(imageData, size), '"}');
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
    }

    // ──────────────────────────────────────────────
    //  Attributes
    // ──────────────────────────────────────────────

    function _buildAttributes(bytes8 traits, uint256 tokenId) internal view returns (string memory) {
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
            _numericTraitJson("Level", _getLevel(tokenId))
        );
        return string(abi.encodePacked(part1, part2));
    }

    function _traitJson(string memory traitType, string memory value) internal pure returns (string memory) {
        return string(abi.encodePacked('{"trait_type":"', traitType, '","value":"', value, '"}'));
    }

    function _numericTraitJson(string memory traitType, uint256 value) internal pure returns (string memory) {
        return string(
            abi.encodePacked('{"display_type":"number","trait_type":"', traitType, '","value":', value.toString(), "}")
        );
    }

    function _appendLegendaryCanvasTrait(
        uint256 tokenId,
        string memory attributesCore
    ) internal view returns (string memory) {
        if (address(legendaryCanvasContract) == address(0)) return attributesCore;
        if (!legendaryCanvasContract.hasLegendaryCanvas(tokenId)) return attributesCore;
        string memory artistName = legendaryCanvasContract.legendaryCanvasArtist(tokenId);
        return string(abi.encodePacked(attributesCore, ",", _traitJson("Legendary Canvas", artistName)));
    }

    function _getLevel(uint256 tokenId) internal view returns (uint256) {
        return transformStorageContract.attachedOf(tokenId) / 10 + 1;
    }

    function _getActionPoints(uint256 tokenId) internal view returns (uint256) {
        return transformStorageContract.attachedOf(tokenId);
    }

    function _gridSize(uint256 tokenId) internal view returns (uint256) {
        return transformStorageContract.gridSize(tokenId);
    }

    // ──────────────────────────────────────────────
    //  Compositing
    // ──────────────────────────────────────────────

    /// @dev Tolerates a 40x40 overlay left over from before an enlargement by embedding it; ignores other mismatches.
    function _applyOverlay(bytes memory base, bytes memory overlay, uint256 size) internal pure returns (bytes memory) {
        if (overlay.length == base.length) return NormiesBitmap.composite(base, overlay);
        if (overlay.length == NormiesBitmap.bytesForGrid(NormiesBitmap.BASE_GRID)) {
            return NormiesBitmap.composite(base, NormiesBitmap.embedCentered(overlay, NormiesBitmap.BASE_GRID, size));
        }
        return base;
    }

    // ──────────────────────────────────────────────
    //  Animation URL (HTML canvas)
    // ──────────────────────────────────────────────

    function _buildAnimationUrl(bytes memory imageData, uint256 size) internal pure returns (string memory) {
        bytes memory n = bytes(size.toString());
        bytes memory px = bytes((size * CELL_PX).toString());
        bytes memory html = abi.encodePacked(
            "<html><body style='margin:0;overflow:hidden;width:100vw;height:100vh;"
            "display:flex;align-items:center;justify-content:center;background:#e3e5e4'>" "<canvas id='c' width='",
            px,
            "' height='",
            px,
            "' style='image-rendering:pixelated;width:min(100vw,100vh);height:min(100vw,100vh)'></canvas>"
            "<script>var h='",
            LibString.toHexStringNoPrefix(imageData)
        );
        html = abi.encodePacked(
            html,
            "',n=",
            n,
            ",s=",
            bytes(CELL_PX.toString()),
            ";var c=document.getElementById('c').getContext('2d');"
            "c.fillStyle='#e3e5e4';c.fillRect(0,0,n*s,n*s);c.fillStyle='#48494b';"
            "for(var y=0;y<n;y++)for(var x=0;x<n;x++){var i=y*n+x,b=parseInt(h.substr((i>>3)*2,2),16);"
            "if((b>>(7-(i&7)))&1)c.fillRect(x*s,y*s,s,s)}" "</script></body></html>"
        );
        return string(abi.encodePacked("data:text/html;base64,", Base64.encode(html)));
    }

    // ──────────────────────────────────────────────
    //  SVG rendering
    // ──────────────────────────────────────────────

    function _renderSvg(bytes memory imageData, uint256 size) internal pure returns (string memory) {
        DynamicBufferLib.DynamicBuffer memory buf;
        buf.reserve(256 + size * size * 8);
        _svgHead(buf, size);

        bytes[] memory nums = _numberTable(size);
        bool any;
        for (uint256 y; y < size; y++) {
            for (uint256 x; x < size;) {
                if (!NormiesBitmap.isPixelOn(imageData, x, y, size)) {
                    x++;
                    continue;
                }
                uint256 runStart = x;
                while (x < size && NormiesBitmap.isPixelOn(imageData, x, y, size)) {
                    x++;
                }
                if (!any) {
                    buf.p('<path fill="#48494b" d="');
                    any = true;
                }
                _appendRun(buf, nums, runStart, y, x - runStart);
            }
        }
        if (any) buf.p('"/>');

        buf.p("</svg>");
        return buf.s();
    }

    function _svgHead(DynamicBufferLib.DynamicBuffer memory buf, uint256 size) internal pure {
        bytes memory n = bytes(size.toString());
        bytes memory px = bytes((size * 25).toString());
        buf.p('<svg xmlns="http://www.w3.org/2000/svg" width="', px, '" height="', px, '" viewBox="0 0 ', n, " ");
        buf.p(n, '" shape-rendering="crispEdges"><rect width="', n, '" height="', n, '" fill="#e3e5e4"/>');
    }

    /// @dev Coordinates are looked up from a precomputed table rather than converted per run.
    function _numberTable(uint256 size) internal pure returns (bytes[] memory nums) {
        nums = new bytes[](size + 1);
        for (uint256 i; i <= size; i++) {
            nums[i] = bytes(i.toString());
        }
    }

    /// @dev One horizontal run of `w` pixels starting at (x, y), as a closed path segment.
    function _appendRun(
        DynamicBufferLib.DynamicBuffer memory buf,
        bytes[] memory nums,
        uint256 x,
        uint256 y,
        uint256 w
    ) internal pure {
        buf.p("M", nums[x], " ", nums[y], "h", nums[w], "v1h-").p(nums[w], "z");
    }

    // ──────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────

    function setStorageContract(INormiesStorage _storage) external onlyOwner {
        storageContract = _storage;
    }

    function setTransformStorageContract(INormiesCanvasStorageV2 _transformStorage) external onlyOwner {
        transformStorageContract = _transformStorage;
    }

    function setZombieContract(INormiesZombie _zombie) external onlyOwner {
        zombieContract = _zombie;
    }

    function setLegendaryCanvasContract(INormiesLegendaryCanvas _legendaryCanvas) external onlyOwner {
        legendaryCanvasContract = _legendaryCanvas;
    }
}
