// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesCanvas } from "./INormiesCanvas.sol";

interface INormiesCanvasV2 is INormiesCanvas {
    /// @notice Where pixels are taken from when paying for a canvas service.
    enum PaySource {
        Wallet,
        Attached
    }

    /// @notice Why an overlay was force-cleared.
    enum ClearReason {
        Withdraw,
        Spend
    }

    function gridSize(uint256 tokenId) external view returns (uint256);
    function baseCleared(uint256 tokenId) external view returns (bool);
}
