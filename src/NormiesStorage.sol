// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesStorage } from "./interfaces/INormiesStorage.sol";
import { SSTORE2 } from "solady/utils/SSTORE2.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";

/**
 * @title NormiesStorage
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 */
contract NormiesStorage is INormiesStorage, Ownable, Lifebuoy {
    error TokenDataNotSet(uint256 tokenId);
    error NotAuthorized();
    error AlreadyRevealed();
    error ZeroRevealHash();

    event AuthorizedWriterSet(address indexed writer, bool allowed);
    event RevealHashSet(bytes32 revealHash);

    /// @notice SSTORE2 pointer for the 200-byte monochrome bitmap per token (encrypted pre-reveal)
    mapping(uint256 => address) private _imagePointers;

    /// @notice Packed trait data per token (8 bytes, encrypted pre-reveal)
    mapping(uint256 => bytes8) private _traits;

    /// @notice Addresses authorized to write token data (e.g. minter contracts)
    mapping(address => bool) public authorizedWriters;

    /// @notice XOR key used to decrypt token data; zero means not yet revealed
    bytes32 public revealHash;

    constructor() Ownable() Lifebuoy() { }

    modifier onlyAuthorized() {
        require(msg.sender == owner() || authorizedWriters[msg.sender], NotAuthorized());
        _;
    }

    function setAuthorizedWriter(address writer, bool allowed) external onlyOwner {
        authorizedWriters[writer] = allowed;
        emit AuthorizedWriterSet(writer, allowed);
    }

    function setRevealHash(bytes32 _revealHash) external onlyOwner {
        require(revealHash == bytes32(0), AlreadyRevealed());
        require(_revealHash != bytes32(0), ZeroRevealHash());
        revealHash = _revealHash;
        emit RevealHashSet(_revealHash);
    }

    function isRevealed() external view returns (bool) {
        return revealHash != bytes32(0);
    }

    function setTokenRawImageData(uint256 tokenId, bytes calldata imageData) external onlyAuthorized {
        _imagePointers[tokenId] = SSTORE2.write(imageData);
    }

    function setTokenTraits(uint256 tokenId, bytes8 traits) external onlyAuthorized {
        _traits[tokenId] = traits;
    }

    function getTokenRawImageData(uint256 tokenId) external view returns (bytes memory) {
        address pointer = _imagePointers[tokenId];
        if (pointer == address(0)) revert TokenDataNotSet(tokenId);
        bytes memory data = SSTORE2.read(pointer);
        bytes32 _revealHash = revealHash;
        if (_revealHash != bytes32(0)) {
            _decryptImageData(data, _revealHash);
        }
        return data;
    }

    function getTokenTraits(uint256 tokenId) external view returns (bytes8) {
        bytes8 traits = _traits[tokenId];
        bytes32 _revealHash = revealHash;
        if (_revealHash != bytes32(0)) {
            traits = traits ^ bytes8(_revealHash);
        }
        return traits;
    }

    function isTokenDataSet(uint256 tokenId) external view returns (bool) {
        return _imagePointers[tokenId] != address(0);
    }

    /**
     * @notice XOR-decrypts image data in-place using keystream derived from revealHash
     * @param data The encrypted image data (modified in-place)
     * @param _revealHash The reveal hash to derive the keystream from
     * @dev Keystream: chunks of keccak256(abi.encodePacked(_revealHash, chunkIndex)), 32 bytes each
     */
    function _decryptImageData(bytes memory data, bytes32 _revealHash) internal pure {
        bytes32 key;
        for (uint256 i = 0; i < data.length; i++) {
            if (i & 31 == 0) {
                key = keccak256(abi.encodePacked(_revealHash, i >> 5));
            }
            data[i] = bytes1(uint8(data[i]) ^ uint8(key[i & 31]));
        }
    }
}
