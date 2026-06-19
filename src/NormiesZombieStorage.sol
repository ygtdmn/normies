// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesZombieStorage } from "./interfaces/INormiesZombieStorage.sol";
import { SSTORE2 } from "solady/utils/SSTORE2.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";

/**
 * @title NormiesZombieStorage
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @dev Plaintext SSTORE2 storage for zombie pool assets and token conversion records.
 */
contract NormiesZombieStorage is INormiesZombieStorage, Ownable, Lifebuoy {
    error NotAuthorized();
    error InvalidBitmapLength();
    error InvalidAttributes();
    error PoolAlreadySealed();
    error PoolNotSealed();
    error InvalidPoolIndex(uint256 poolIndex);
    error TokenNotZombie(uint256 tokenId);
    error AlreadyZombie(uint256 tokenId);

    event AuthorizedWriterSet(address indexed writer, bool allowed);
    event ZombieAdded(uint256 indexed poolIndex, address bitmapPointer, address attributesPointer);
    event PoolSealed(uint256 poolSize);
    event ZombieSet(uint256 indexed tokenId, uint256 indexed poolIndex);

    /// @notice Addresses authorized to write conversion records.
    mapping(address => bool) public authorizedWriters;

    address[] private _bitmapPointers;
    address[] private _attributesPointers;
    // Stores poolIndex + 1 so that the default 0 unambiguously means "token is not a zombie",
    // even for the valid pool index 0.
    mapping(uint256 => uint256) private _tokenPoolIndexPlusOne;

    bool private _poolSealed;

    constructor() Ownable() Lifebuoy() { }

    modifier onlyAuthorized() {
        require(msg.sender == owner() || authorizedWriters[msg.sender], NotAuthorized());
        _;
    }

    function setAuthorizedWriter(address writer, bool allowed) external onlyOwner {
        authorizedWriters[writer] = allowed;
        emit AuthorizedWriterSet(writer, allowed);
    }

    function addZombie(
        bytes calldata bitmap,
        bytes calldata attributesJson
    ) external onlyOwner returns (uint256 poolIndex) {
        require(!_poolSealed, PoolAlreadySealed());
        require(bitmap.length == 200, InvalidBitmapLength());
        _validateAttributes(attributesJson);

        poolIndex = _bitmapPointers.length;
        address bitmapPointer = SSTORE2.write(bitmap);
        address attributesPointer = SSTORE2.write(attributesJson);
        _bitmapPointers.push(bitmapPointer);
        _attributesPointers.push(attributesPointer);

        emit ZombieAdded(poolIndex, bitmapPointer, attributesPointer);
    }

    function sealPool() external onlyOwner {
        require(!_poolSealed, PoolAlreadySealed());
        _poolSealed = true;
        emit PoolSealed(_bitmapPointers.length);
    }

    function setZombie(uint256 tokenId, uint256 poolIndex) external onlyAuthorized {
        require(_poolSealed, PoolNotSealed());
        require(poolIndex < _bitmapPointers.length, InvalidPoolIndex(poolIndex));
        require(_tokenPoolIndexPlusOne[tokenId] == 0, AlreadyZombie(tokenId));

        _tokenPoolIndexPlusOne[tokenId] = poolIndex + 1;
        emit ZombieSet(tokenId, poolIndex);
    }

    function isPoolSealed() external view returns (bool) {
        return _poolSealed;
    }

    function poolSize() external view returns (uint256) {
        return _bitmapPointers.length;
    }

    function isZombie(uint256 tokenId) external view returns (bool) {
        return _tokenPoolIndexPlusOne[tokenId] != 0;
    }

    function poolIndexOf(uint256 tokenId) public view returns (uint256) {
        uint256 poolIndexPlusOne = _tokenPoolIndexPlusOne[tokenId];
        if (poolIndexPlusOne == 0) revert TokenNotZombie(tokenId);
        return poolIndexPlusOne - 1;
    }

    function getZombieBitmap(uint256 tokenId) external view returns (bytes memory) {
        return getPoolBitmap(poolIndexOf(tokenId));
    }

    function getZombieAttributes(uint256 tokenId) external view returns (bytes memory) {
        return getPoolAttributes(poolIndexOf(tokenId));
    }

    function getPoolBitmap(uint256 poolIndex) public view returns (bytes memory) {
        require(poolIndex < _bitmapPointers.length, InvalidPoolIndex(poolIndex));
        return SSTORE2.read(_bitmapPointers[poolIndex]);
    }

    function getPoolAttributes(uint256 poolIndex) public view returns (bytes memory) {
        require(poolIndex < _attributesPointers.length, InvalidPoolIndex(poolIndex));
        return SSTORE2.read(_attributesPointers[poolIndex]);
    }

    /// @dev Sanity-checks that the stored attributes are a JSON object the renderer can splice in:
    ///      must open with '{' (0x7b) and close with '}' (0x7d). The trailing comma check on the
    ///      same two bytes is redundant given the brace check but kept as a cheap guard.
    function _validateAttributes(bytes calldata attributesJson) internal pure {
        uint256 length = attributesJson.length;
        require(length > 1, InvalidAttributes());
        require(attributesJson[0] == 0x7b && attributesJson[length - 1] == 0x7d, InvalidAttributes());
        require(attributesJson[0] != 0x2c && attributesJson[length - 1] != 0x2c, InvalidAttributes());
    }
}
