// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { IWETH } from "./IWETH.sol";

interface INormiesRevenuePool {
    enum Status {
        None,
        Posted,
        Swept,
        Cancelled
    }

    struct Epoch {
        bytes32 root;
        uint128 amount;
        uint128 claimed;
        /// @dev POST_DELAY after the epoch was posted; claims open here and the claim window counts from here.
        uint64 claimableAt;
        /// @dev Fixed at posting. Changes to the default claim window never change this deadline.
        uint64 sweepableAt;
        uint64 fromBlock;
        uint64 toBlock;
        Status status;
    }

    struct Claim {
        uint256 epochId;
        uint256 index;
        address account;
        uint256 amount;
        bytes32[] proof;
    }

    function postEpoch(
        bytes32 root,
        uint256 amount,
        uint64 fromBlock,
        uint64 toBlock,
        bytes32 configHash,
        string calldata dataURI
    ) external returns (uint256 epochId);
    function claim(uint256 epochId, uint256 index, address account, uint256 amount, bytes32[] calldata proof) external;
    function claimMany(Claim[] calldata claims) external;
    function sweep(uint256 epochId) external;
    function cancelEpoch(uint256 epochId) external;
    function unwrap() external;

    function getEpoch(uint256 epochId) external view returns (Epoch memory);
    function isClaimed(uint256 epochId, uint256 index) external view returns (bool);
    function unallocated() external view returns (uint256);
    function outstanding() external view returns (uint256);
    function nextEpochId() external view returns (uint256);
    function cursorToBlock() external view returns (uint64);
    function weth() external view returns (IWETH);

    // Timing: claims open POST_DELAY after a post; each epoch keeps the claim window it was posted with
    function POST_DELAY() external view returns (uint64);
    function MIN_CLAIM_WINDOW() external view returns (uint64);
    function claimWindow() external view returns (uint64);
    function paused() external view returns (bool);

    // Admin: config (claim window), guardian (pause posting), owner (unreserved ETH, stray tokens)
    function setClaimWindow(uint64 _claimWindow) external;
    function setPaused(bool _paused) external;
    function withdrawUnallocated(address to, uint256 amount) external;
    function rescueToken(address token, address to) external;
}
