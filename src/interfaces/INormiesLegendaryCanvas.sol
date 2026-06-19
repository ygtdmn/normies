// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface INormiesLegendaryCanvas {
    function hasLegendaryCanvas(uint256 tokenId) external view returns (bool);
    function legendaryCanvasArtist(uint256 tokenId) external view returns (string memory);
}
