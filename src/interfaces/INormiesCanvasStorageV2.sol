// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesCanvasStorage } from "./INormiesCanvasStorage.sol";

interface INormiesCanvasStorageV2 is INormiesCanvasStorage {
    /// @notice Why an attached balance changed. Emitted with every AttachedChanged event.
    enum Reason {
        Migration,
        BurnReward,
        BurnTransfer,
        Deposit,
        Withdraw,
        Spend
    }

    // Overlays
    function clearTransformedImageData(uint256 tokenId) external;

    // Per-token canvas state (grid size, blank base, delegate); written by the canvas, read by the renderer
    function gridSize(uint256 tokenId) external view returns (uint256);
    function baseCleared(uint256 tokenId) external view returns (bool);
    function delegates(uint256 tokenId) external view returns (address);
    function delegateSetBy(uint256 tokenId) external view returns (address);
    function delegation(uint256 tokenId) external view returns (address delegate, address setBy);
    function delegationsSeeded() external view returns (bool);
    function delegationSnapshotBlock() external view returns (uint256);
    function delegationSnapshotTimestamp() external view returns (uint256);
    function seedAndFinalizeDelegations(
        uint256[] calldata tokenIds,
        address[] calldata delegates_,
        address[] calldata setBy,
        uint256 snapshotBlock,
        uint256 snapshotTimestamp
    ) external;
    function setGridSize(uint256 tokenId, uint256 size) external;
    function setBaseCleared(uint256 tokenId, bool cleared) external;
    function setDelegate(uint256 tokenId, address delegate, address setBy) external;
    function resetTokenState(uint256 tokenId) external;

    // Pixel accounting
    function balanceOf(address account) external view returns (uint256);
    function availableBalance(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function allowancesPaused() external view returns (bool);
    function approve(address spender, uint256 amount) external;
    function useAllowance(address owner, address spender, uint256 amount) external;
    function setAllowancesPaused(bool paused) external;
    function attachedOf(uint256 tokenId) external view returns (uint256);
    function migrated(uint256 tokenId) external view returns (bool);
    function migrationFinalized() external view returns (bool);
    function totalWallet() external view returns (uint256);
    function totalAttached() external view returns (uint256);
    function moverRoles(address mover) external view returns (uint8);

    function migrateBatch(uint256[] calldata tokenIds) external;
    function finalizeMigration() external;
    function mintTo(address to, uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
    function moveBalance(address from, address to, uint256 amount) external;
    function releaseEscrow(address to, uint256 amount) external;
    function creditAttached(uint256 tokenId, uint256 amount, Reason reason) external;
    function debitAttached(uint256 tokenId, uint256 amount, Reason reason) external;
    function moveAttached(uint256 fromTokenId, uint256 toTokenId, uint256 amount, Reason reason) external;
    function attach(address from, uint256 tokenId, uint256 amount, Reason reason) external;
    function detach(uint256 tokenId, address to, uint256 amount, Reason reason) external;
}
