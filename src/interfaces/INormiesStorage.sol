// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface INormiesStorage {
    function getTokenRawImageData(uint256 tokenId) external view returns (bytes memory);
    function getTokenTraits(uint256 tokenId) external view returns (bytes8);
    function setTokenRawImageData(uint256 tokenId, bytes calldata imageData) external;
    function setTokenTraits(uint256 tokenId, bytes8 traits) external;
    function isTokenDataSet(uint256 tokenId) external view returns (bool);
    function isRevealed() external view returns (bool);
}
