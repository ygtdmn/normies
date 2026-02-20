// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesMinterV2 } from "../src/NormiesMinterV2.sol";
import { NormiesRenderer } from "../src/NormiesRenderer.sol";
import { NormiesStorage } from "../src/NormiesStorage.sol";
import { INormies } from "../src/interfaces/INormies.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";
import { IDelegateRegistry } from "../src/interfaces/IDelegateRegistry.sol";
import { IDelegateRegistryV1 } from "../src/interfaces/IDelegateRegistryV1.sol";

contract NormiesMinterV2Test is Test {
    Normies normies;
    NormiesRenderer renderer;
    NormiesStorage normiesStorage;
    NormiesMinterV2 minter;

    address owner = address(this);

    uint256 constant SIGNER_PK = 0xA11CE;
    address signerAddr;

    uint256 constant MINT_PRICE = 0.005 ether;

    bytes8 constant DEFAULT_TRAITS = bytes8(uint64(0x000000000A0D000E));
    bytes32 constant TEST_REVEAL_HASH = keccak256("test-secret");

    function setUp() public {
        signerAddr = vm.addr(SIGNER_PK);

        normiesStorage = new NormiesStorage();
        renderer = new NormiesRenderer(INormiesStorage(address(normiesStorage)));
        normies = new Normies(INormiesRenderer(address(renderer)), INormiesStorage(address(normiesStorage)), owner);

        minter = new NormiesMinterV2(
            INormies(address(normies)), INormiesStorage(address(normiesStorage)), signerAddr, MINT_PRICE, owner
        );

        address[] memory minterAddrs = new address[](1);
        bool[] memory allowed = new bool[](1);
        minterAddrs[0] = address(minter);
        allowed[0] = true;
        normies.setMinterAddresses(minterAddrs, allowed);
        normiesStorage.setAuthorizedWriter(address(minter), true);
    }

    // ============ Helpers ============

    function _createTestBitmap() internal pure returns (bytes memory) {
        bytes memory bitmap = new bytes(200);
        for (uint256 i = 0; i < 5; i++) {
            bitmap[i] = bytes1(0xFF);
        }
        return bitmap;
    }

    function _xorEncryptImageData(bytes memory data, bytes32 _revealHash) internal pure returns (bytes memory) {
        bytes memory encrypted = new bytes(data.length);
        bytes32 key;
        for (uint256 i = 0; i < data.length; i++) {
            if (i & 31 == 0) {
                key = keccak256(abi.encodePacked(_revealHash, i >> 5));
            }
            encrypted[i] = bytes1(uint8(data[i]) ^ uint8(key[i & 31]));
        }
        return encrypted;
    }

    function _signMint(
        bytes memory imageData,
        bytes8 traits,
        address minterAddr,
        uint8 maxMints,
        uint256 deadline
    ) internal pure returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encodePacked(imageData, traits, minterAddr, maxMints, deadline));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _signBatchMint(
        bytes[] memory imageDataArray,
        bytes8[] memory traitsArray,
        address minterAddr,
        uint8 maxMints,
        uint256 deadline
    ) internal pure returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(imageDataArray, traitsArray, minterAddr, maxMints, deadline));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _prepareBatch(uint256 count)
        internal
        pure
        returns (bytes[] memory imageDataArray, bytes8[] memory traitsArray)
    {
        imageDataArray = new bytes[](count);
        traitsArray = new bytes8[](count);
        for (uint256 i = 0; i < count; i++) {
            imageDataArray[i] = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
            traitsArray[i] = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        }
    }

    /// @dev Mocks delegate.xyz v2 registry
    function _mockDelegationV2(address hotWallet, address coldWallet, bool forAll, bool forContract) internal {
        vm.mockCall(
            address(minter.DELEGATE_REGISTRY_V2()),
            abi.encodeCall(IDelegateRegistry.checkDelegateForAll, (hotWallet, coldWallet, "")),
            abi.encode(forAll)
        );
        vm.mockCall(
            address(minter.DELEGATE_REGISTRY_V2()),
            abi.encodeCall(IDelegateRegistry.checkDelegateForContract, (hotWallet, coldWallet, address(normies), "")),
            abi.encode(forContract)
        );
    }

    /// @dev Mocks delegate.xyz v1 registry
    function _mockDelegationV1(address hotWallet, address coldWallet, bool forAll, bool forContract) internal {
        vm.mockCall(
            address(minter.DELEGATE_REGISTRY_V1()),
            abi.encodeCall(IDelegateRegistryV1.checkDelegateForAll, (hotWallet, coldWallet)),
            abi.encode(forAll)
        );
        vm.mockCall(
            address(minter.DELEGATE_REGISTRY_V1()),
            abi.encodeCall(IDelegateRegistryV1.checkDelegateForContract, (hotWallet, coldWallet, address(normies))),
            abi.encode(forContract)
        );
    }

    /// @dev Mocks both v1 and v2 registries
    function _mockBoth(
        address hotWallet,
        address coldWallet,
        bool v2ForAll,
        bool v2ForContract,
        bool v1ForAll,
        bool v1ForContract
    ) internal {
        _mockDelegationV2(hotWallet, coldWallet, v2ForAll, v2ForContract);
        _mockDelegationV1(hotWallet, coldWallet, v1ForAll, v1ForContract);
    }

    // ============ Constants ============

    function testConstants_DelegateRegistryAddresses() public view {
        assertEq(address(minter.DELEGATE_REGISTRY_V2()), 0x00000000000000447e69651d841bD8D104Bed493);
        assertEq(address(minter.DELEGATE_REGISTRY_V1()), 0x00000000000076A84feF008CDAbe6409d2FE638B);
    }

    // ============ mint() — Delegation ============

    function testMint_CallerIsMinter_NoDelegateCheck() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);

        assertEq(normies.ownerOf(0), user);
    }

    function testMint_V2DelegateForAll() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, coldWallet, 2, block.timestamp + 900);

        _mockBoth(hotWallet, coldWallet, true, false, false, false);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        minter.mint{ value: MINT_PRICE }(coldWallet, imageData, traits, 2, block.timestamp + 900, sig);

        assertEq(normies.ownerOf(0), coldWallet);
        assertEq(minter.mintCount(coldWallet), 1);
    }

    function testMint_V2DelegateForContract() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, coldWallet, 2, block.timestamp + 900);

        _mockBoth(hotWallet, coldWallet, false, true, false, false);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        minter.mint{ value: MINT_PRICE }(coldWallet, imageData, traits, 2, block.timestamp + 900, sig);

        assertEq(normies.ownerOf(0), coldWallet);
        assertEq(minter.mintCount(coldWallet), 1);
    }

    function testMint_V1DelegateForAll_V2Fails() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, coldWallet, 2, block.timestamp + 900);

        _mockBoth(hotWallet, coldWallet, false, false, true, false);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        minter.mint{ value: MINT_PRICE }(coldWallet, imageData, traits, 2, block.timestamp + 900, sig);

        assertEq(normies.ownerOf(0), coldWallet);
        assertEq(minter.mintCount(coldWallet), 1);
    }

    function testMint_V1DelegateForContract_V2Fails() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, coldWallet, 2, block.timestamp + 900);

        _mockBoth(hotWallet, coldWallet, false, false, false, true);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        minter.mint{ value: MINT_PRICE }(coldWallet, imageData, traits, 2, block.timestamp + 900, sig);

        assertEq(normies.ownerOf(0), coldWallet);
        assertEq(minter.mintCount(coldWallet), 1);
    }

    function testMint_BothV1V2Fail_Reverts() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, coldWallet, 2, block.timestamp + 900);

        _mockBoth(hotWallet, coldWallet, false, false, false, false);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        vm.expectRevert(NormiesMinterV2.NotMinterOrDelegate.selector);
        minter.mint{ value: MINT_PRICE }(coldWallet, imageData, traits, 2, block.timestamp + 900, sig);
    }

    // ============ batchMint() — Delegation ============

    function testBatchMint_V2DelegateForAll() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, coldWallet, 10, block.timestamp + 900);

        _mockBoth(hotWallet, coldWallet, true, false, false, false);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        minter.batchMint{ value: MINT_PRICE * 2 }(
            coldWallet, imageDataArray, traitsArray, 10, block.timestamp + 900, sig
        );

        assertEq(normies.ownerOf(0), coldWallet);
        assertEq(normies.ownerOf(1), coldWallet);
        assertEq(minter.mintCount(coldWallet), 2);
    }

    function testBatchMint_V2DelegateForContract() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, coldWallet, 10, block.timestamp + 900);

        _mockBoth(hotWallet, coldWallet, false, true, false, false);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        minter.batchMint{ value: MINT_PRICE * 2 }(
            coldWallet, imageDataArray, traitsArray, 10, block.timestamp + 900, sig
        );

        assertEq(normies.ownerOf(0), coldWallet);
        assertEq(normies.ownerOf(1), coldWallet);
    }

    function testBatchMint_V1DelegateForAll_V2Fails() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, coldWallet, 10, block.timestamp + 900);

        _mockBoth(hotWallet, coldWallet, false, false, true, false);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        minter.batchMint{ value: MINT_PRICE * 2 }(
            coldWallet, imageDataArray, traitsArray, 10, block.timestamp + 900, sig
        );

        assertEq(normies.ownerOf(0), coldWallet);
        assertEq(normies.ownerOf(1), coldWallet);
        assertEq(minter.mintCount(coldWallet), 2);
    }

    function testBatchMint_V1DelegateForContract_V2Fails() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, coldWallet, 10, block.timestamp + 900);

        _mockBoth(hotWallet, coldWallet, false, false, false, true);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        minter.batchMint{ value: MINT_PRICE * 2 }(
            coldWallet, imageDataArray, traitsArray, 10, block.timestamp + 900, sig
        );

        assertEq(normies.ownerOf(0), coldWallet);
        assertEq(normies.ownerOf(1), coldWallet);
    }

    function testBatchMint_BothV1V2Fail_Reverts() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, coldWallet, 10, block.timestamp + 900);

        _mockBoth(hotWallet, coldWallet, false, false, false, false);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        vm.expectRevert(NormiesMinterV2.NotMinterOrDelegate.selector);
        minter.batchMint{ value: MINT_PRICE * 2 }(
            coldWallet, imageDataArray, traitsArray, 10, block.timestamp + 900, sig
        );
    }
}
