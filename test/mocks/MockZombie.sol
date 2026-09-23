// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesZombie } from "../../src/interfaces/INormiesZombie.sol";

/// @notice Minimal zombie source for canvas and renderer tests: any token can be flagged with a custom base bitmap.
contract MockZombie is INormiesZombie {
    mapping(uint256 => bool) internal _zombies;
    mapping(uint256 => bytes) internal _bitmaps;

    function setZombie(uint256 tokenId, bytes memory bitmap) external {
        _zombies[tokenId] = true;
        _bitmaps[tokenId] = bitmap;
    }

    function isZombie(uint256 tokenId) external view returns (bool) {
        return _zombies[tokenId];
    }

    function getZombieBitmap(uint256 tokenId) external view returns (bytes memory) {
        return _bitmaps[tokenId];
    }

    function getZombieAttributes(uint256) external pure returns (bytes memory) {
        return bytes('{"trait_type":"Type","value":"Zombie"},{"trait_type":"Mutation","value":"Green Room"}');
    }
}
