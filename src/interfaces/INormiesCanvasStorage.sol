// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface INormiesCanvasStorage {
    function getTransformedImageData(uint256 tokenId) external view returns (bytes memory);
    function setTransformedImageData(uint256 tokenId, bytes calldata imageData) external;
    function isTransformed(uint256 tokenId) external view returns (bool);
}
