// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface INormiesRevenuePool {
    enum Status {
        None,
        Posted,
        Swept
    }

    struct Epoch {
        bytes32 root;
        uint128 amount;
        uint128 claimed;
        /// @dev When the epoch was posted; claims open at once and the claim window counts from here.
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
    function unwrap() external;

    function getEpoch(uint256 epochId) external view returns (Epoch memory);
    function isClaimed(uint256 epochId, uint256 index) external view returns (bool);
    function unallocated() external view returns (uint256);
    function outstanding() external view returns (uint256);
    function nextEpochId() external view returns (uint256);
}
