// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Minimal interface for delegate.xyz v1 registry
/// @dev Full registry at 0x00000000000076A84feF008CDAbe6409d2FE638B
interface IDelegateRegistryV1 {
    function checkDelegateForAll(address delegate, address vault) external view returns (bool);
    function checkDelegateForContract(
        address delegate,
        address vault,
        address contract_
    ) external view returns (bool);
}
