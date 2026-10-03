// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesRenderer } from "./INormiesRenderer.sol";
import { INormiesStorage } from "./INormiesStorage.sol";
import { INormiesCanvasStorageV2 } from "./INormiesCanvasStorageV2.sol";
import { INormiesZombie } from "./INormiesZombie.sol";
import { INormiesLegendaryCanvas } from "./INormiesLegendaryCanvas.sol";

/// @notice NormiesRendererV6 beyond tokenURI: where it reads art from. Setters are owner only.
interface INormiesRendererV6 is INormiesRenderer {
    function storageContract() external view returns (INormiesStorage);
    function transformStorageContract() external view returns (INormiesCanvasStorageV2);
    function zombieContract() external view returns (INormiesZombie);
    function legendaryCanvasContract() external view returns (INormiesLegendaryCanvas);

    function setStorageContract(INormiesStorage _storage) external;
    function setTransformStorageContract(INormiesCanvasStorageV2 _transformStorage) external;
    function setZombieContract(INormiesZombie _zombie) external;
    function setLegendaryCanvasContract(INormiesLegendaryCanvas _legendaryCanvas) external;
}
