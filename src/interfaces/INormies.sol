// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface INormies {
    function mint(address to, uint256 tokenId) external;
    function totalSupply() external view returns (uint256);
    function burn(uint256 tokenId) external;
}
