// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesCanvas } from "./INormiesCanvas.sol";
import { INormiesStorage } from "./INormiesStorage.sol";
import { INormiesCanvasStorageV2 } from "./INormiesCanvasStorageV2.sol";
import { INormiesZombie } from "./INormiesZombie.sol";
import { IDelegateRegistry } from "./IDelegateRegistry.sol";
import { IDelegateRegistryV1 } from "./IDelegateRegistryV1.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

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

    // Wiring
    function DELEGATE_REGISTRY_V2() external view returns (IDelegateRegistry);
    function DELEGATE_REGISTRY_V1() external view returns (IDelegateRegistryV1);
    function normies() external view returns (IERC721);
    function normiesStorage() external view returns (INormiesStorage);
    function canvasStorage() external view returns (INormiesCanvasStorageV2);
    function zombieContract() external view returns (INormiesZombie);
    function paused() external view returns (bool);

    // Canvas state
    function gridSize(uint256 tokenId) external view returns (uint256);
    function baseCleared(uint256 tokenId) external view returns (bool);
    function lockedPixels(uint256 tokenId) external view returns (uint256);

    // Burning: commit destroys the tokens, the reveal rolls their worth REVEAL_DELAY blocks later
    function REVEAL_DELAY() external view returns (uint256);
    function nextCommitId() external view returns (uint256);
    function burnCommitments(uint256 commitId)
        external
        view
        returns (
            address owner,
            uint256 receiverTokenId,
            uint64 commitBlock,
            uint16 tokenCount,
            bool revealed,
            bool toWallet,
            uint256 transferredActionPoints
        );
    function commitPixelCounts(uint256 commitId) external view returns (uint256[] memory);
    function revealBlock(uint256 commitId) external view returns (uint256);
    function pendingBurnCommitments(address owner)
        external
        view
        returns (uint256[] memory commitIds, uint256[] memory receiverTokenIds, bool[] memory toWallet);
    function commitBurn(uint256[] calldata tokenIds, uint256 receiverTokenId) external;
    function commitBurnToWallet(uint256[] calldata tokenIds) external;
    function revealBurn(uint256 commitId) external;

    // Burn tiers
    function maxBurnPercent() external view returns (uint256);
    function tierThresholds(uint256 index) external view returns (uint256);
    function tierMinPercents(uint256 index) external view returns (uint256);
    function burnTiers() external view returns (uint256[] memory thresholds, uint256[] memory minPercents);

    // Painting and moving pixels
    function setTransformBitmap(uint256 tokenId, bytes calldata bitmap) external;
    function withdrawPixels(uint256 tokenId, uint256 amount, bool clearOverlay) external;
    function depositPixels(uint256 tokenId, uint256 amount) external;

    // Canvas services, paid in pixels
    function enlargePrice(uint256 size) external view returns (uint256);
    function blankCanvasPrice() external view returns (uint256);
    function enlargeCanvas(uint256 tokenId, uint256 newSize, PaySource source, bool clearOverlay) external;
    function clearBase(uint256 tokenId, PaySource source, bool clearOverlay) external;

    // Canvas delegate (painting only)
    function delegates(uint256 tokenId) external view returns (address);
    function delegateSetBy(uint256 tokenId) external view returns (address);
    function effectiveDelegate(uint256 tokenId) external view returns (address delegate, address setBy);
    function setDelegate(uint256 tokenId, address delegate) external;
    function revokeDelegate(uint256 tokenId) external;

    // Admin: guardian (pause), config (prices and tiers), owner (pointers)
    function setPaused(bool _paused) external;
    function setCanvasStorage(INormiesCanvasStorageV2 _canvasStorage) external;
    function setZombieContract(INormiesZombie _zombie) external;
    function setEnlargePrice(uint256 size, uint256 cumulativeCost) external;
    function setBlankCanvasPrice(uint256 price) external;
    function setMaxBurnPercent(uint256 _maxBurnPercent) external;
    function setBurnTiers(uint256[] calldata _thresholds, uint256[] calldata _minPercents) external;
}
