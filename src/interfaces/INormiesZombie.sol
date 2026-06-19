// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface INormiesZombie {
    function isZombie(uint256 tokenId) external view returns (bool);
    function getZombieBitmap(uint256 tokenId) external view returns (bytes memory);
    function getZombieAttributes(uint256 tokenId) external view returns (bytes memory);
}
