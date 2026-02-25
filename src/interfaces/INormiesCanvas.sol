// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface INormiesCanvas {
    function getLevel(uint256 tokenId) external view returns (uint256);
    function actionPoints(uint256 tokenId) external view returns (uint256);
}
