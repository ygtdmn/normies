// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice delegate.xyz V2's token check: true for a token, contract or wallet level delegation with full rights.
contract MockDelegateRegistryV2 {
    mapping(bytes32 => bool) internal _delegated;

    function delegateAll(address to, address from, bool enable) external {
        _delegated[keccak256(abi.encode(to, from))] = enable;
    }

    function delegateContract(address to, address from, address contract_, bool enable) external {
        _delegated[keccak256(abi.encode(to, from, contract_))] = enable;
    }

    function delegateERC721(address to, address from, address contract_, uint256 tokenId, bool enable) external {
        _delegated[keccak256(abi.encode(to, from, contract_, tokenId))] = enable;
    }

    function checkDelegateForERC721(
        address to,
        address from,
        address contract_,
        uint256 tokenId,
        bytes32 rights
    ) external view returns (bool) {
        if (rights != bytes32(0)) return false;
        return _delegated[keccak256(abi.encode(to, from))] || _delegated[keccak256(abi.encode(to, from, contract_))]
            || _delegated[keccak256(abi.encode(to, from, contract_, tokenId))];
    }
}

/// @notice delegate.xyz V1's token check, same three levels.
contract MockDelegateRegistryV1 {
    mapping(bytes32 => bool) internal _delegated;

    function delegateForToken(
        address delegate,
        address vault,
        address contract_,
        uint256 tokenId,
        bool enable
    ) external {
        _delegated[keccak256(abi.encode(delegate, vault, contract_, tokenId))] = enable;
    }

    function delegateForAll(address delegate, address vault, bool enable) external {
        _delegated[keccak256(abi.encode(delegate, vault))] = enable;
    }

    function checkDelegateForToken(
        address delegate,
        address vault,
        address contract_,
        uint256 tokenId
    ) external view returns (bool) {
        return _delegated[keccak256(abi.encode(delegate, vault))]
            || _delegated[keccak256(abi.encode(delegate, vault, contract_, tokenId))];
    }
}
