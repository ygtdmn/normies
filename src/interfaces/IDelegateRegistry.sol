// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Minimal interface for delegate.xyz v2 registry
/// @dev Full registry at 0x00000000000000447e69651d841bD8D104Bed493
interface IDelegateRegistry {
    function checkDelegateForAll(address to, address from, bytes32 rights) external view returns (bool);
    function checkDelegateForContract(
        address to,
        address from,
        address contract_,
        bytes32 rights
    ) external view returns (bool);

    /// @notice True for a token, contract or wallet level delegation from `from` to `to`.
    function checkDelegateForERC721(
        address to,
        address from,
        address contract_,
        uint256 tokenId,
        bytes32 rights
    ) external view returns (bool);
}
