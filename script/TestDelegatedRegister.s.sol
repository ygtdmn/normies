// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script} from "forge-std/src/Script.sol";
import {console2} from "forge-std/src/console2.sol";

interface IDelegateRegistryV2Write {
    function delegateAll(address to, bytes32 rights, bool enable) external payable returns (bytes32);
    function checkDelegateForAll(address to, address from, bytes32 rights) external view returns (bool);
}

interface IAdapter8004 {
    function register(uint8 standard, address tokenContract, uint256 tokenId, string calldata agentURI)
        external
        returns (uint256 agentId);
}

interface IERC721Min {
    function ownerOf(uint256 tokenId) external view returns (address);
}

contract TestDelegatedRegister is Script {
    address constant DELEGATE_REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;
    address constant ADAPTER = 0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92;

    address constant NORMIES = 0x3EDA0fF8A60e7f3883982f50715120D56Ac62496;
    uint256 constant TOKEN_ID = 0;
    string constant AGENT_URI = "https://api.normies.art/agents/metadata/1";

    uint8 constant ERC721_STANDARD = 0;

    function run() public {
        uint256 pkA = vm.envUint("PRIVATE_KEY_A");
        uint256 pkB = vm.envUint("PRIVATE_KEY_B");
        address walletA = vm.addr(pkA);
        address walletB = vm.addr(pkB);

        console2.log("Vault    (A):", walletA);
        console2.log("Delegate (B):", walletB);
        console2.log("Token ID    :", TOKEN_ID);

        address owner = IERC721Min(NORMIES).ownerOf(TOKEN_ID);
        require(owner == walletA, "wallet A does not own TOKEN_ID");

        vm.startBroadcast(pkA);
        IDelegateRegistryV2Write(DELEGATE_REGISTRY).delegateAll(walletB, bytes32(0), true);
        vm.stopBroadcast();

        require(
            IDelegateRegistryV2Write(DELEGATE_REGISTRY).checkDelegateForAll(walletB, walletA, bytes32(0)),
            "delegation not active"
        );
        console2.log("Delegated A -> B (all rights)");

        vm.startBroadcast(pkB);
        uint256 agentId = IAdapter8004(ADAPTER).register(ERC721_STANDARD, NORMIES, TOKEN_ID, AGENT_URI);
        vm.stopBroadcast();

        console2.log("Agent registered, agentId:", agentId);
    }
}
