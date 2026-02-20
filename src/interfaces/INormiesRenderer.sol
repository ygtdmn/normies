// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface INormiesRenderer {
    function tokenURI(uint256 tokenId) external view returns (string memory);
}
