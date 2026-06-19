// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface INormiesZombieStorage {
    function poolSize() external view returns (uint256);
    function isPoolSealed() external view returns (bool);
    function addZombie(bytes calldata bitmap, bytes calldata attributesJson) external returns (uint256 poolIndex);
    function sealPool() external;
    function setZombie(uint256 tokenId, uint256 poolIndex) external;
    function isZombie(uint256 tokenId) external view returns (bool);
    function poolIndexOf(uint256 tokenId) external view returns (uint256);
    function getZombieBitmap(uint256 tokenId) external view returns (bytes memory);
    function getZombieAttributes(uint256 tokenId) external view returns (bytes memory);
    function getPoolBitmap(uint256 poolIndex) external view returns (bytes memory);
    function getPoolAttributes(uint256 poolIndex) external view returns (bytes memory);
}
