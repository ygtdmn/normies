// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesCanvasStorage } from "./interfaces/INormiesCanvasStorage.sol";
import { SSTORE2 } from "solady/utils/SSTORE2.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";

/**
 * @title NormiesCanvasStorage
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 */
contract NormiesCanvasStorage is INormiesCanvasStorage, Ownable, Lifebuoy {
    error NotAuthorized();
    error TokenNotTransformed(uint256 tokenId);

    event AuthorizedWriterSet(address indexed writer, bool allowed);

    /// @notice SSTORE2 pointer for the transformed 200-byte monochrome bitmap per token (plaintext, no encryption)
    mapping(uint256 => address) private _imagePointers;

    /// @notice Addresses authorized to write transformed data (e.g. Canvas contract)
    mapping(address => bool) public authorizedWriters;

    constructor() Ownable() Lifebuoy() { }

    modifier onlyAuthorized() {
        require(msg.sender == owner() || authorizedWriters[msg.sender], NotAuthorized());
        _;
    }

    function setAuthorizedWriter(address writer, bool allowed) external onlyOwner {
        authorizedWriters[writer] = allowed;
        emit AuthorizedWriterSet(writer, allowed);
    }

    function setTransformedImageData(uint256 tokenId, bytes calldata imageData) external onlyAuthorized {
        _imagePointers[tokenId] = SSTORE2.write(imageData);
    }

    function getTransformedImageData(uint256 tokenId) external view returns (bytes memory) {
        address pointer = _imagePointers[tokenId];
        if (pointer == address(0)) revert TokenNotTransformed(tokenId);
        return SSTORE2.read(pointer);
    }

    function isTransformed(uint256 tokenId) external view returns (bool) {
        return _imagePointers[tokenId] != address(0);
    }
}
