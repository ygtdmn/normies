// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesLegendaryCanvas } from "./interfaces/INormiesLegendaryCanvas.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";

/**
 * @title NormiesLegendaryCanvas
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @dev Owner-managed registry for selected "Legendary Canvas" artist traits.
 */
contract NormiesLegendaryCanvas is INormiesLegendaryCanvas, Ownable, Lifebuoy {
    mapping(uint256 => string) private _artistNames;

    error NoLegendaryCanvas();

    event LegendaryCanvasSet(uint256 indexed tokenId, string artistName, address indexed operator);
    event LegendaryCanvasCleared(uint256 indexed tokenId, address indexed operator);

    constructor() Ownable() Lifebuoy() { }

    function setLegendaryCanvas(uint256 tokenId, string calldata artistName) external onlyOwner {
        _artistNames[tokenId] = artistName;
        emit LegendaryCanvasSet(tokenId, artistName, msg.sender);
    }

    function clearLegendaryCanvas(uint256 tokenId) external onlyOwner {
        delete _artistNames[tokenId];
        emit LegendaryCanvasCleared(tokenId, msg.sender);
    }

    function hasLegendaryCanvas(uint256 tokenId) external view returns (bool) {
        return bytes(_artistNames[tokenId]).length != 0;
    }

    function legendaryCanvasArtist(uint256 tokenId) external view returns (string memory) {
        string memory artistName = _artistNames[tokenId];
        if (bytes(artistName).length == 0) revert NoLegendaryCanvas();
        return artistName;
    }
}
