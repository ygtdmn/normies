// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice The part of the original NormiesCanvas (V1) that NormiesCanvasStorageV2 reads: action points, copied in
///         once at cutover by migrateBatch.
interface INormiesCanvasV1 {
    function actionPoints(uint256 tokenId) external view returns (uint256);
    function paused() external view returns (bool);
}
