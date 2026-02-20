// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesMinter } from "../src/NormiesMinter.sol";
import { NormiesRenderer } from "../src/NormiesRenderer.sol";
import { NormiesStorage } from "../src/NormiesStorage.sol";
import { INormies } from "../src/interfaces/INormies.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";
import { IDelegateRegistry } from "../src/interfaces/IDelegateRegistry.sol";

/// @notice Receiver contract that accepts ETH (for withdraw tests)
contract Receiver {
    receive() external payable { }
}

/// @notice Contract that cannot receive ETH (for WithdrawFailed tests)
contract NonReceiver { }

contract NormiesMinterTest is Test {
    Normies normies;
    NormiesRenderer renderer;
    NormiesStorage normiesStorage;
    NormiesMinter minter;

    address owner = address(this);
    address unauthorized = address(0xBEEF);

    uint256 constant SIGNER_PK = 0xA11CE;
    address signerAddr;

    uint256 constant NEW_SIGNER_PK = 0xB0B;
    address newSignerAddr;

    uint256 constant MINT_PRICE = 0.005 ether;

    bytes8 constant DEFAULT_TRAITS = bytes8(uint64(0x000000000A0D000E));
    bytes8 constant REAL_TRAITS = bytes8(uint64(0x000101020B00010A));
    bytes32 constant TEST_REVEAL_HASH = keccak256("test-secret");

    function setUp() public {
        signerAddr = vm.addr(SIGNER_PK);
        newSignerAddr = vm.addr(NEW_SIGNER_PK);

        normiesStorage = new NormiesStorage();
        renderer = new NormiesRenderer(INormiesStorage(address(normiesStorage)));
        normies = new Normies(INormiesRenderer(address(renderer)), INormiesStorage(address(normiesStorage)), owner);

        minter = new NormiesMinter(
            INormies(address(normies)), INormiesStorage(address(normiesStorage)), signerAddr, MINT_PRICE, owner
        );

        // Authorize minter on normies and storage
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

    function _createRealBitmap() internal pure returns (bytes memory) {
        return hex"00000000000000000000000081800000013500000042d6f0000077fffc000017ffb400003bffd8000057fff60000bfc7ea0001af5af50000fcfebf80005b8db6000177995d0000dff7ba0000dcf13f000077e72b80006fe3270000e7e02b800017e46800001e7e7800001ffff800003ffff400000ffff000000ffff000000ffff000000ffff000000ffff0000007ffe000001ffff000003ffff000008f3ce200000f00c0000007a980800213c388000001e300000001ea000008207e000008103c042004081f0020";
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
        return _signMintWithKey(SIGNER_PK, imageData, traits, minterAddr, maxMints, deadline);
    }

    function _signMintWithKey(
        uint256 pk,
        bytes memory imageData,
        bytes8 traits,
        address minterAddr,
        uint8 maxMints,
        uint256 deadline
    ) internal pure returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encodePacked(imageData, traits, minterAddr, maxMints, deadline));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _signBatchMint(
        bytes[] memory imageDataArray,
        bytes8[] memory traitsArray,
        address minterAddr,
        uint8 maxMints,
        uint256 deadline
    ) internal pure returns (bytes memory) {
        return _signBatchMintWithKey(SIGNER_PK, imageDataArray, traitsArray, minterAddr, maxMints, deadline);
    }

    function _signBatchMintWithKey(
        uint256 pk,
        bytes[] memory imageDataArray,
        bytes8[] memory traitsArray,
        address minterAddr,
        uint8 maxMints,
        uint256 deadline
    ) internal pure returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(imageDataArray, traitsArray, minterAddr, maxMints, deadline));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Mocks delegate.xyz to return specified values
    function _mockDelegation(address hotWallet, address coldWallet, bool forAll, bool forContract) internal {
        vm.mockCall(
            address(minter.DELEGATE_REGISTRY()),
            abi.encodeCall(IDelegateRegistry.checkDelegateForAll, (hotWallet, coldWallet, "")),
            abi.encode(forAll)
        );
        vm.mockCall(
            address(minter.DELEGATE_REGISTRY()),
            abi.encodeCall(IDelegateRegistry.checkDelegateForContract, (hotWallet, coldWallet, address(normies), "")),
            abi.encode(forContract)
        );
    }

    /// @dev Helper to prepare batch data with identical bitmaps
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

    // ============ Section 1: Error Selectors ============

    function testRevert_Mint_MintingPaused() public {
        minter.setPaused(true);

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.MintingPaused.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);
    }

    function testRevert_Mint_SignatureExpired() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _signMint(imageData, traits, user, 2, deadline);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.SignatureExpired.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, deadline, sig);
    }

    function testRevert_Mint_InsufficientPayment() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.InsufficientPayment.selector);
        minter.mint{ value: MINT_PRICE - 1 }(user, imageData, traits, 2, block.timestamp + 900, sig);
    }

    function testRevert_Mint_MintLimitReached() public {
        address user = address(0x1234);
        uint8 maxMints = 1;
        vm.deal(user, 1 ether);

        bytes memory imageData1 = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits1 = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig1 = _signMint(imageData1, traits1, user, maxMints, block.timestamp + 900);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData1, traits1, maxMints, block.timestamp + 900, sig1);

        bytes memory imageData2 = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        bytes8 traits2 = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig2 = _signMint(imageData2, traits2, user, maxMints, block.timestamp + 900);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.MintLimitReached.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData2, traits2, maxMints, block.timestamp + 900, sig2);
    }

    function testRevert_Mint_NotMinterOrDelegate() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, coldWallet, 2, block.timestamp + 900);

        _mockDelegation(hotWallet, coldWallet, false, false);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        vm.expectRevert(NormiesMinter.NotMinterOrDelegate.selector);
        minter.mint{ value: MINT_PRICE }(coldWallet, imageData, traits, 2, block.timestamp + 900, sig);
    }

    function testRevert_Mint_InvalidSignature() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMintWithKey(0xDEAD, imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.InvalidSignature.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);
    }

    function testRevert_BatchMint_MintingPaused() public {
        minter.setPaused(true);

        address user = address(0x1234);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, user, 10, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.MintingPaused.selector);
        minter.batchMint{ value: MINT_PRICE * 2 }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig);
    }

    function testRevert_BatchMint_SignatureExpired() public {
        address user = address(0x1234);
        uint256 deadline = block.timestamp - 1;
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, user, 10, deadline);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.SignatureExpired.selector);
        minter.batchMint{ value: MINT_PRICE * 2 }(user, imageDataArray, traitsArray, 10, deadline, sig);
    }

    function testRevert_BatchMint_ArrayLengthMismatch() public {
        address user = address(0x1234);
        bytes[] memory imageDataArray = new bytes[](2);
        bytes8[] memory traitsArray = new bytes8[](3);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.ArrayLengthMismatch.selector);
        minter.batchMint{ value: MINT_PRICE * 2 }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, hex"");
    }

    function testRevert_BatchMint_InsufficientPayment() public {
        address user = address(0x1234);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(3);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, user, 10, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.InsufficientPayment.selector);
        minter.batchMint{ value: MINT_PRICE * 2 }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig);
    }

    function testRevert_BatchMint_MintLimitReached() public {
        address user = address(0x1234);
        uint8 maxMints = 2;
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(3);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, user, maxMints, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.MintLimitReached.selector);
        minter.batchMint{ value: MINT_PRICE * 3 }(
            user, imageDataArray, traitsArray, maxMints, block.timestamp + 900, sig
        );
    }

    function testRevert_BatchMint_NotMinterOrDelegate() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, coldWallet, 10, block.timestamp + 900);

        _mockDelegation(hotWallet, coldWallet, false, false);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        vm.expectRevert(NormiesMinter.NotMinterOrDelegate.selector);
        minter.batchMint{ value: MINT_PRICE * 2 }(
            coldWallet, imageDataArray, traitsArray, 10, block.timestamp + 900, sig
        );
    }

    function testRevert_BatchMint_InvalidSignature() public {
        address user = address(0x1234);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig = _signBatchMintWithKey(0xDEAD, imageDataArray, traitsArray, user, 10, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.InvalidSignature.selector);
        minter.batchMint{ value: MINT_PRICE * 2 }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig);
    }

    function testRevert_Withdraw_WithdrawFailed() public {
        // Fund the minter via a mint
        address user = address(0x1234);
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);
        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);

        // Set withdraw to NonReceiver
        NonReceiver nonReceiver = new NonReceiver();
        minter.setWithdrawAddress(address(nonReceiver));

        vm.expectRevert(NormiesMinter.WithdrawFailed.selector);
        minter.withdraw();
    }

    // ============ Section 2: Event Emission ============

    function testEmit_Mint_SingleMint() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);

        vm.expectEmit(true, true, false, true, address(minter));
        emit NormiesMinter.Mint(user, 0, imageData, traits);

        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);
    }

    function testEmit_BatchMint_EmitsPerToken() public {
        address user = address(0x1234);
        uint256 count = 3;
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(count);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, user, 10, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);

        for (uint256 i = 0; i < count; i++) {
            vm.expectEmit(true, true, false, true, address(minter));
            emit NormiesMinter.Mint(user, i, imageDataArray[i], traitsArray[i]);
        }

        minter.batchMint{ value: MINT_PRICE * count }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig);
    }

    // ============ Section 3: Pause Guard ============

    function testMint_RevertsWhenPaused() public {
        minter.setPaused(true);

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.MintingPaused.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);
    }

    function testMint_SucceedsAfterUnpause() public {
        minter.setPaused(true);
        minter.setPaused(false);

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);

        assertEq(normies.ownerOf(0), user);
    }

    function testBatchMint_RevertsWhenPaused() public {
        minter.setPaused(true);

        address user = address(0x1234);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, user, 10, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.MintingPaused.selector);
        minter.batchMint{ value: MINT_PRICE * 2 }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig);
    }

    // ============ Section 4: Signature Deadline ============

    function testMint_DeadlineExactBoundary() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        uint256 deadline = block.timestamp;
        bytes memory sig = _signMint(imageData, traits, user, 2, deadline);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, deadline, sig);

        assertEq(normies.ownerOf(0), user);
    }

    function testMint_DeadlineExpiredByOne() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _signMint(imageData, traits, user, 2, deadline);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.SignatureExpired.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, deadline, sig);
    }

    function testMint_DeadlineFuture() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        uint256 deadline = block.timestamp + 3600;
        bytes memory sig = _signMint(imageData, traits, user, 2, deadline);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, deadline, sig);

        assertEq(normies.ownerOf(0), user);
    }

    function testBatchMint_DeadlineExpired() public {
        address user = address(0x1234);
        uint256 deadline = block.timestamp - 1;
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, user, 10, deadline);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.SignatureExpired.selector);
        minter.batchMint{ value: MINT_PRICE * 2 }(user, imageDataArray, traitsArray, 10, deadline, sig);
    }

    function testMint_DeadlineAfterWarp() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        uint256 deadline = 100;
        bytes memory sig = _signMint(imageData, traits, user, 2, deadline);

        vm.deal(user, 1 ether);

        // Warp past deadline — should revert
        vm.warp(101);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.SignatureExpired.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, deadline, sig);

        // Warp back to exact boundary — should succeed
        vm.warp(100);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, deadline, sig);

        assertEq(normies.ownerOf(0), user);
    }

    // ============ Section 5: Mint Price Validation and Scaling ============

    function testMint_ExactPrice() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);

        assertEq(normies.ownerOf(0), user);
    }

    function testMint_OverpaySucceeds() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 2 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE + 1 ether }(user, imageData, traits, 2, block.timestamp + 900, sig);

        assertEq(normies.ownerOf(0), user);
        assertEq(address(minter).balance, MINT_PRICE + 1 ether);
    }

    function testMint_UnderpayReverts() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.InsufficientPayment.selector);
        minter.mint{ value: MINT_PRICE - 1 }(user, imageData, traits, 2, block.timestamp + 900, sig);
    }

    function testMint_ZeroPriceAllowsFreeMint() public {
        minter.setMintPrice(0);

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.prank(user);
        minter.mint{ value: 0 }(user, imageData, traits, 2, block.timestamp + 900, sig);

        assertEq(normies.ownerOf(0), user);
    }

    function testBatchMint_PriceScalesWithCount() public {
        address user = address(0x1234);
        uint256 count = 3;
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(count);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, user, 10, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.batchMint{ value: MINT_PRICE * count }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig);

        assertEq(normies.totalSupply(), 3);
        assertEq(address(minter).balance, MINT_PRICE * count);
    }

    function testBatchMint_PriceScalesAfterPriceChange() public {
        minter.setMintPrice(0.01 ether);

        address user = address(0x1234);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, user, 10, block.timestamp + 900);

        vm.deal(user, 1 ether);

        // Underpay at new price
        vm.prank(user);
        vm.expectRevert(NormiesMinter.InsufficientPayment.selector);
        minter.batchMint{ value: 0.019 ether }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig);

        // Exact pay at new price
        vm.prank(user);
        minter.batchMint{ value: 0.02 ether }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig);

        assertEq(normies.totalSupply(), 2);
    }

    // ============ Section 6: Max Mint Limit ============

    function testMint_MaxMintsEnforced() public {
        address user = address(0x1234);
        uint8 maxMints = 1;
        vm.deal(user, 1 ether);

        bytes memory imageData1 = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits1 = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig1 = _signMint(imageData1, traits1, user, maxMints, block.timestamp + 900);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData1, traits1, maxMints, block.timestamp + 900, sig1);

        bytes memory imageData2 = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        bytes8 traits2 = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig2 = _signMint(imageData2, traits2, user, maxMints, block.timestamp + 900);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.MintLimitReached.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData2, traits2, maxMints, block.timestamp + 900, sig2);
    }

    function testMint_MaxMintsMultipleMints() public {
        address user = address(0x1234);
        uint8 maxMints = 3;
        vm.deal(user, 1 ether);

        for (uint256 i = 0; i < 3; i++) {
            bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
            bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
            bytes memory sig = _signMint(imageData, traits, user, maxMints, block.timestamp + 900);
            vm.prank(user);
            minter.mint{ value: MINT_PRICE }(user, imageData, traits, maxMints, block.timestamp + 900, sig);
        }
        assertEq(minter.mintCount(user), 3);

        // 4th mint fails
        bytes memory imageData4 = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits4 = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig4 = _signMint(imageData4, traits4, user, maxMints, block.timestamp + 900);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.MintLimitReached.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData4, traits4, maxMints, block.timestamp + 900, sig4);
    }

    function testBatchMint_ExceedsMaxMintsInSingleBatch() public {
        address user = address(0x1234);
        uint8 maxMints = 2;
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(3);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, user, maxMints, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.MintLimitReached.selector);
        minter.batchMint{ value: MINT_PRICE * 3 }(
            user, imageDataArray, traitsArray, maxMints, block.timestamp + 900, sig
        );
    }

    function testBatchMint_ExceedsMaxMintsAcrossCalls() public {
        address user = address(0x1234);
        uint8 maxMints = 3;
        vm.deal(user, 1 ether);

        // Single mint first
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig1 = _signMint(imageData, traits, user, maxMints, block.timestamp + 900);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, maxMints, block.timestamp + 900, sig1);
        assertEq(minter.mintCount(user), 1);

        // Batch of 3 exceeds limit (1 + 3 > 3)
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(3);
        bytes memory sig2 = _signBatchMint(imageDataArray, traitsArray, user, maxMints, block.timestamp + 900);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.MintLimitReached.selector);
        minter.batchMint{ value: MINT_PRICE * 3 }(
            user, imageDataArray, traitsArray, maxMints, block.timestamp + 900, sig2
        );
    }

    function testMintCount_IndependentPerWallet() public {
        address userA = address(0x1111);
        address userB = address(0x2222);
        uint8 maxMints = 1;
        vm.deal(userA, 1 ether);
        vm.deal(userB, 1 ether);

        bytes memory imageDataA = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traitsA = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sigA = _signMint(imageDataA, traitsA, userA, maxMints, block.timestamp + 900);
        vm.prank(userA);
        minter.mint{ value: MINT_PRICE }(userA, imageDataA, traitsA, maxMints, block.timestamp + 900, sigA);

        bytes memory imageDataB = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        bytes8 traitsB = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sigB = _signMint(imageDataB, traitsB, userB, maxMints, block.timestamp + 900);
        vm.prank(userB);
        minter.mint{ value: MINT_PRICE }(userB, imageDataB, traitsB, maxMints, block.timestamp + 900, sigB);

        assertEq(minter.mintCount(userA), 1);
        assertEq(minter.mintCount(userB), 1);
    }

    // ============ Section 7: Delegate.xyz v2 (Mock-based) ============

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

    function testMint_DelegateForAll() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, coldWallet, 2, block.timestamp + 900);

        _mockDelegation(hotWallet, coldWallet, true, false);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        minter.mint{ value: MINT_PRICE }(coldWallet, imageData, traits, 2, block.timestamp + 900, sig);

        assertEq(normies.ownerOf(0), coldWallet);
        assertEq(minter.mintCount(coldWallet), 1);
    }

    function testMint_DelegateForContract() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, coldWallet, 2, block.timestamp + 900);

        _mockDelegation(hotWallet, coldWallet, false, true);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        minter.mint{ value: MINT_PRICE }(coldWallet, imageData, traits, 2, block.timestamp + 900, sig);

        assertEq(normies.ownerOf(0), coldWallet);
    }

    function testMint_NeitherDelegateReverts() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, coldWallet, 2, block.timestamp + 900);

        _mockDelegation(hotWallet, coldWallet, false, false);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        vm.expectRevert(NormiesMinter.NotMinterOrDelegate.selector);
        minter.mint{ value: MINT_PRICE }(coldWallet, imageData, traits, 2, block.timestamp + 900, sig);
    }

    function testBatchMint_DelegateForAll() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, coldWallet, 10, block.timestamp + 900);

        _mockDelegation(hotWallet, coldWallet, true, false);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        minter.batchMint{ value: MINT_PRICE * 2 }(
            coldWallet, imageDataArray, traitsArray, 10, block.timestamp + 900, sig
        );

        assertEq(normies.ownerOf(0), coldWallet);
        assertEq(normies.ownerOf(1), coldWallet);
        assertEq(minter.mintCount(coldWallet), 2);
    }

    function testBatchMint_DelegateForContract() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, coldWallet, 10, block.timestamp + 900);

        _mockDelegation(hotWallet, coldWallet, false, true);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        minter.batchMint{ value: MINT_PRICE * 2 }(
            coldWallet, imageDataArray, traitsArray, 10, block.timestamp + 900, sig
        );

        assertEq(normies.ownerOf(0), coldWallet);
        assertEq(normies.ownerOf(1), coldWallet);
    }

    function testBatchMint_NeitherDelegateReverts() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, coldWallet, 10, block.timestamp + 900);

        _mockDelegation(hotWallet, coldWallet, false, false);

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        vm.expectRevert(NormiesMinter.NotMinterOrDelegate.selector);
        minter.batchMint{ value: MINT_PRICE * 2 }(
            coldWallet, imageDataArray, traitsArray, 10, block.timestamp + 900, sig
        );
    }

    // ============ Section 8: Signature Structure ============

    function testMint_CorrectSignatureAccepted() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);

        assertEq(normies.ownerOf(0), user);
    }

    function testMint_WrongImageDataRejected() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes memory differentImageData = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);

        // Sign with imageData but call with differentImageData
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.InvalidSignature.selector);
        minter.mint{ value: MINT_PRICE }(user, differentImageData, traits, 2, block.timestamp + 900, sig);
    }

    function testMint_WrongTraitsRejected() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes8 wrongTraits = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);

        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.InvalidSignature.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData, wrongTraits, 2, block.timestamp + 900, sig);
    }

    function testMint_WrongMinterAddrRejected() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address userA = address(0x1234);
        address userB = address(0x5678);

        // Sign for userA but pass userB as minter
        bytes memory sig = _signMint(imageData, traits, userA, 2, block.timestamp + 900);

        vm.deal(userB, 1 ether);
        vm.prank(userB);
        vm.expectRevert(NormiesMinter.InvalidSignature.selector);
        minter.mint{ value: MINT_PRICE }(userB, imageData, traits, 2, block.timestamp + 900, sig);
    }

    function testMint_WrongMaxMintsRejected() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);

        // Sign with maxMints=5 but pass maxMints=10
        bytes memory sig = _signMint(imageData, traits, user, 5, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.InvalidSignature.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 10, block.timestamp + 900, sig);
    }

    function testMint_WrongDeadlineRejected() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);

        // Sign with deadline=100 but pass deadline=200
        bytes memory sig = _signMint(imageData, traits, user, 2, 100);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.InvalidSignature.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, 200, sig);
    }

    function testBatchMint_WrongSignatureRejected() public {
        address user = address(0x1234);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);

        // Sign with different data
        (bytes[] memory otherImageData, bytes8[] memory otherTraits) = _prepareBatch(3);
        bytes memory sig = _signBatchMint(otherImageData, otherTraits, user, 10, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.InvalidSignature.selector);
        minter.batchMint{ value: MINT_PRICE * 2 }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig);
    }

    function testMint_SignatureUsesEncodePacked() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        uint256 deadline = block.timestamp + 900;

        // Manually construct the hash using abi.encodePacked (matching contract)
        bytes32 messageHash = keccak256(abi.encodePacked(imageData, traits, user, uint8(2), deadline));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, ethSignedHash);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, deadline, abi.encodePacked(r, s, v));
        assertEq(normies.ownerOf(0), user);
    }

    function testMint_SignatureWithEncodeInsteadOfEncodePacked_Reverts() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        uint256 deadline = block.timestamp + 900;

        // Sign with abi.encode instead of abi.encodePacked — should fail
        bytes32 wrongHash = keccak256(abi.encode(imageData, traits, user, uint8(2), deadline));
        bytes32 wrongEthHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", wrongHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, wrongEthHash);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.InvalidSignature.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, deadline, abi.encodePacked(r, s, v));
    }

    function testBatchMint_SignatureUsesEncode() public {
        address user = address(0x1234);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        uint8 maxMints = 10;
        uint256 deadline = block.timestamp + 900;

        // Manually construct the hash using abi.encode (matching contract)
        bytes32 messageHash = keccak256(abi.encode(imageDataArray, traitsArray, user, maxMints, deadline));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.batchMint{ value: MINT_PRICE * 2 }(user, imageDataArray, traitsArray, maxMints, deadline, sig);

        assertEq(normies.totalSupply(), 2);
    }

    // ============ Section 9: Mint Count Tracking ============

    function testMintCount_StartsAtZero() public view {
        assertEq(minter.mintCount(address(0x1234)), 0);
    }

    function testMintCount_IncrementsOnSingleMint() public {
        address user = address(0x1234);
        vm.deal(user, 1 ether);
        assertEq(minter.mintCount(user), 0);

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, user, 10, block.timestamp + 900);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 10, block.timestamp + 900, sig);
        assertEq(minter.mintCount(user), 1);

        bytes memory imageData2 = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        bytes8 traits2 = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig2 = _signMint(imageData2, traits2, user, 10, block.timestamp + 900);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData2, traits2, 10, block.timestamp + 900, sig2);
        assertEq(minter.mintCount(user), 2);
    }

    function testMintCount_IncrementsByCountOnBatchMint() public {
        address user = address(0x1234);
        vm.deal(user, 1 ether);

        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(3);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, user, 10, block.timestamp + 900);

        vm.prank(user);
        minter.batchMint{ value: MINT_PRICE * 3 }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig);

        assertEq(minter.mintCount(user), 3);
    }

    function testMintCount_IndependentBetweenWallets() public {
        address userA = address(0x1111);
        address userB = address(0x2222);
        vm.deal(userA, 1 ether);
        vm.deal(userB, 1 ether);

        // UserA mints 2
        for (uint256 i = 0; i < 2; i++) {
            bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
            bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
            bytes memory sig = _signMint(imageData, traits, userA, 10, block.timestamp + 900);
            vm.prank(userA);
            minter.mint{ value: MINT_PRICE }(userA, imageData, traits, 10, block.timestamp + 900, sig);
        }

        // UserB mints 1
        bytes memory imageDataB = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        bytes8 traitsB = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sigB = _signMint(imageDataB, traitsB, userB, 10, block.timestamp + 900);
        vm.prank(userB);
        minter.mint{ value: MINT_PRICE }(userB, imageDataB, traitsB, 10, block.timestamp + 900, sigB);

        assertEq(minter.mintCount(userA), 2);
        assertEq(minter.mintCount(userB), 1);
    }

    // ============ Section 10: Mint Sets Storage ============

    function testMint_SetsImageDataInStorage() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);

        // No revealHash set, so stored bytes returned as-is
        bytes memory stored = normiesStorage.getTokenRawImageData(0);
        assertEq(keccak256(stored), keccak256(imageData));
    }

    function testMint_SetsTraitsInStorage() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);

        assertEq(normiesStorage.getTokenTraits(0), traits);
    }

    function testMint_IsTokenDataSetTrue() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        assertFalse(normiesStorage.isTokenDataSet(0));

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);

        assertTrue(normiesStorage.isTokenDataSet(0));
    }

    function testBatchMint_SetsAllStorageData() public {
        address user = address(0x1234);
        bytes[] memory imageDataArray = new bytes[](3);
        bytes8[] memory traitsArray = new bytes8[](3);

        imageDataArray[0] = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        traitsArray[0] = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        imageDataArray[1] = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        traitsArray[1] = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        imageDataArray[2] = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        traitsArray[2] = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, user, 10, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.batchMint{ value: MINT_PRICE * 3 }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig);

        for (uint256 i = 0; i < 3; i++) {
            assertTrue(normiesStorage.isTokenDataSet(i));
            assertEq(keccak256(normiesStorage.getTokenRawImageData(i)), keccak256(imageDataArray[i]));
            assertEq(normiesStorage.getTokenTraits(i), traitsArray[i]);
        }
    }

    function testMint_TokenOwnedByMinter() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);

        assertEq(normies.ownerOf(0), user);
    }

    // ============ Section 11: Batch Mint Parity ============

    function testBatchMint_SingleItemBatch() public {
        address user = address(0x1234);
        bytes[] memory imageDataArray = new bytes[](1);
        bytes8[] memory traitsArray = new bytes8[](1);
        imageDataArray[0] = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        traitsArray[0] = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, user, 10, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.batchMint{ value: MINT_PRICE }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig);

        assertEq(normies.totalSupply(), 1);
        assertEq(normies.ownerOf(0), user);
        assertEq(minter.mintCount(user), 1);
        assertEq(minter.nextTokenId(), 1);
    }

    function testBatchMint_NextTokenIdIncrementsCorrectly() public {
        address user = address(0x1234);
        vm.deal(user, 1 ether);

        assertEq(minter.nextTokenId(), 0);

        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(3);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, user, 10, block.timestamp + 900);

        vm.prank(user);
        minter.batchMint{ value: MINT_PRICE * 3 }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig);

        assertEq(minter.nextTokenId(), 3);
        assertEq(normies.ownerOf(0), user);
        assertEq(normies.ownerOf(1), user);
        assertEq(normies.ownerOf(2), user);
    }

    function testMintCount_AccumulatesAcrossMintAndBatch() public {
        address user = address(0x1234);
        vm.deal(user, 1 ether);

        // Single mint
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig1 = _signMint(imageData, traits, user, 10, block.timestamp + 900);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 10, block.timestamp + 900, sig1);
        assertEq(minter.mintCount(user), 1);
        assertEq(minter.nextTokenId(), 1);

        // Batch mint 2 more
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig2 = _signBatchMint(imageDataArray, traitsArray, user, 10, block.timestamp + 900);
        vm.prank(user);
        minter.batchMint{ value: MINT_PRICE * 2 }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig2);

        assertEq(minter.mintCount(user), 3);
        assertEq(minter.nextTokenId(), 3);
    }

    // ============ Section 12: Withdraw ============

    function testWithdraw_ToEOA() public {
        address user = address(0x1234);
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);
        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);

        address payable withdrawEOA = payable(address(0x9999));
        minter.setWithdrawAddress(withdrawEOA);

        uint256 balanceBefore = withdrawEOA.balance;
        minter.withdraw();
        assertEq(withdrawEOA.balance, balanceBefore + MINT_PRICE);
        assertEq(address(minter).balance, 0);
    }

    function testWithdraw_ToContractWithReceive() public {
        Receiver receiver = new Receiver();

        address user = address(0x1234);
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);
        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);

        minter.setWithdrawAddress(address(receiver));
        minter.withdraw();

        assertEq(address(receiver).balance, MINT_PRICE);
        assertEq(address(minter).balance, 0);
    }

    function testWithdraw_ToContractWithoutReceive_Reverts() public {
        NonReceiver nonReceiver = new NonReceiver();

        address user = address(0x1234);
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);
        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);

        minter.setWithdrawAddress(address(nonReceiver));

        vm.expectRevert(NormiesMinter.WithdrawFailed.selector);
        minter.withdraw();
    }

    function testWithdraw_OnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        minter.withdraw();
    }

    function testWithdraw_ZeroBalance() public {
        address payable withdrawEOA = payable(address(0x9999));
        minter.setWithdrawAddress(withdrawEOA);
        minter.withdraw();
        assertEq(address(minter).balance, 0);
    }

    function testWithdraw_AfterMultipleMints() public {
        address user = address(0x1234);
        vm.deal(user, 1 ether);

        for (uint256 i = 0; i < 3; i++) {
            bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
            bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
            bytes memory sig = _signMint(imageData, traits, user, 10, block.timestamp + 900);
            vm.prank(user);
            minter.mint{ value: MINT_PRICE }(user, imageData, traits, 10, block.timestamp + 900, sig);
        }

        assertEq(address(minter).balance, MINT_PRICE * 3);

        address payable withdrawEOA = payable(address(0x9999));
        minter.setWithdrawAddress(withdrawEOA);
        minter.withdraw();

        assertEq(withdrawEOA.balance, MINT_PRICE * 3);
        assertEq(address(minter).balance, 0);
    }

    // ============ Section 13: Withdraw After setWithdrawAddress Change ============

    function testWithdraw_AfterAddressChange() public {
        address payable addrA = payable(address(0xAAAA));
        address payable addrB = payable(address(0xBBBB));

        minter.setWithdrawAddress(addrA);

        // Fund via mint
        address user = address(0x1234);
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);
        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);

        // Change to addrB before withdraw
        minter.setWithdrawAddress(addrB);
        minter.withdraw();

        assertEq(addrA.balance, 0);
        assertEq(addrB.balance, MINT_PRICE);
    }

    function testWithdraw_MultipleAddressChanges() public {
        address payable addr1 = payable(address(0x1111));
        address payable addr2 = payable(address(0x2222));
        address payable addr3 = payable(address(0x3333));

        minter.setWithdrawAddress(addr1);
        minter.setWithdrawAddress(addr2);
        minter.setWithdrawAddress(addr3);

        // Fund via mint
        address user = address(0x1234);
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);
        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);

        minter.withdraw();

        assertEq(addr1.balance, 0);
        assertEq(addr2.balance, 0);
        assertEq(addr3.balance, MINT_PRICE);
    }

    // ============ Section 14: setPaused ============

    function testSetPaused_PausesMintAndUnpauseResumes() public {
        minter.setPaused(true);
        assertTrue(minter.paused());

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        vm.deal(user, 1 ether);

        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.MintingPaused.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);

        minter.setPaused(false);
        assertFalse(minter.paused());

        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);
        assertEq(normies.ownerOf(0), user);
    }

    function testSetPaused_PausesBatchMint() public {
        minter.setPaused(true);

        address user = address(0x1234);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, user, 10, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.MintingPaused.selector);
        minter.batchMint{ value: MINT_PRICE * 2 }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig);
    }

    function testSetPaused_OnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        minter.setPaused(true);
    }

    function testSetPaused_StateToggle() public {
        assertFalse(minter.paused());
        minter.setPaused(true);
        assertTrue(minter.paused());
        minter.setPaused(false);
        assertFalse(minter.paused());
        minter.setPaused(true);
        assertTrue(minter.paused());
    }

    // ============ Section 15: setMintPrice ============

    function testSetMintPrice_UpdatesState() public {
        uint256 newPrice = 0.01 ether;
        minter.setMintPrice(newPrice);
        assertEq(minter.mintPrice(), newPrice);
    }

    function testSetMintPrice_AffectsMintValidation() public {
        minter.setMintPrice(0.01 ether);

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);

        // Old price insufficient
        vm.prank(user);
        vm.expectRevert(NormiesMinter.InsufficientPayment.selector);
        minter.mint{ value: 0.005 ether }(user, imageData, traits, 2, block.timestamp + 900, sig);

        // New price succeeds
        vm.prank(user);
        minter.mint{ value: 0.01 ether }(user, imageData, traits, 2, block.timestamp + 900, sig);
        assertEq(normies.ownerOf(0), user);
    }

    function testSetMintPrice_AffectsBatchMintValidation() public {
        minter.setMintPrice(0.01 ether);

        address user = address(0x1234);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, user, 10, block.timestamp + 900);

        vm.deal(user, 1 ether);

        vm.prank(user);
        vm.expectRevert(NormiesMinter.InsufficientPayment.selector);
        minter.batchMint{ value: 0.019 ether }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig);

        vm.prank(user);
        minter.batchMint{ value: 0.02 ether }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig);
        assertEq(normies.totalSupply(), 2);
    }

    function testSetMintPrice_OnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        minter.setMintPrice(0);
    }

    function testSetMintPrice_ZeroAllowsFreeMint() public {
        minter.setMintPrice(0);

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMint(imageData, traits, user, 2, block.timestamp + 900);

        vm.prank(user);
        minter.mint{ value: 0 }(user, imageData, traits, 2, block.timestamp + 900, sig);
        assertEq(normies.ownerOf(0), user);
    }

    // ============ Section 16: setSigner ============

    function testSetSigner_UpdatesState() public {
        minter.setSigner(newSignerAddr);
        assertEq(minter.signer(), newSignerAddr);
    }

    function testSetSigner_NewSignerAccepted() public {
        minter.setSigner(newSignerAddr);

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMintWithKey(NEW_SIGNER_PK, imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);
        assertEq(normies.ownerOf(0), user);
    }

    function testSetSigner_OldSignerRejected() public {
        minter.setSigner(newSignerAddr);

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        bytes memory sig = _signMintWithKey(SIGNER_PK, imageData, traits, user, 2, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.InvalidSignature.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, 2, block.timestamp + 900, sig);
    }

    function testSetSigner_OnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        minter.setSigner(address(0x1));
    }

    function testSetSigner_BatchMintWithNewSigner() public {
        minter.setSigner(newSignerAddr);

        address user = address(0x1234);
        (bytes[] memory imageDataArray, bytes8[] memory traitsArray) = _prepareBatch(2);
        bytes memory sig =
            _signBatchMintWithKey(NEW_SIGNER_PK, imageDataArray, traitsArray, user, 10, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.batchMint{ value: MINT_PRICE * 2 }(user, imageDataArray, traitsArray, 10, block.timestamp + 900, sig);
        assertEq(normies.totalSupply(), 2);
    }

    // ============ Section 17: setNormies ============

    function testSetNormies_UpdatesState() public {
        address newNormies = address(0x1234);
        minter.setNormies(newNormies);
        assertEq(address(minter.normies()), newNormies);
    }

    function testSetNormies_OnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        minter.setNormies(address(0x1));
    }

    // ============ Section 18: setNormiesStorage ============

    function testSetNormiesStorage_UpdatesState() public {
        address newStorage = address(0x5678);
        minter.setNormiesStorage(newStorage);
        assertEq(address(minter.normiesStorage()), newStorage);
    }

    function testSetNormiesStorage_OnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        minter.setNormiesStorage(address(0x1));
    }

    // ============ Section 19: onlyOwner Comprehensive ============

    function testOnlyOwner_withdraw() public {
        vm.prank(unauthorized);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        minter.withdraw();
    }

    function testOnlyOwner_setWithdrawAddress() public {
        vm.prank(unauthorized);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        minter.setWithdrawAddress(address(0x1));
    }

    function testOnlyOwner_setPaused() public {
        vm.prank(unauthorized);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        minter.setPaused(true);
    }

    function testOnlyOwner_setMintPrice() public {
        vm.prank(unauthorized);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        minter.setMintPrice(0);
    }

    function testOnlyOwner_setSigner() public {
        vm.prank(unauthorized);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        minter.setSigner(address(0x1));
    }

    function testOnlyOwner_setNormies() public {
        vm.prank(unauthorized);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        minter.setNormies(address(0x1));
    }

    function testOnlyOwner_setNormiesStorage() public {
        vm.prank(unauthorized);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        minter.setNormiesStorage(address(0x1));
    }
}

// ============ Section 20: Fork Test — Delegate.xyz v2 on Sepolia ============

contract NormiesMinterForkTest is Test {
    Normies normies;
    NormiesRenderer renderer;
    NormiesStorage normiesStorage;
    NormiesMinter minter;

    address owner = address(this);

    uint256 constant SIGNER_PK = 0xA11CE;
    address signerAddr;

    uint256 constant MINT_PRICE = 0.005 ether;
    bytes8 constant DEFAULT_TRAITS = bytes8(uint64(0x000000000A0D000E));
    bytes32 constant TEST_REVEAL_HASH = keccak256("test-secret");

    /// @dev Real Sepolia delegation: VAULT delegated to DELEGATE
    address constant VAULT = 0x7d761D8828baf244eAC723F82b2ECE15ef8AdC4f;
    address constant DELEGATE = 0x28996f7DECe7E058EBfC56dFa9371825fBfa515A;

    function setUp() public {
        vm.createSelectFork("sepolia");

        signerAddr = vm.addr(SIGNER_PK);

        normiesStorage = new NormiesStorage();
        renderer = new NormiesRenderer(INormiesStorage(address(normiesStorage)));
        normies = new Normies(INormiesRenderer(address(renderer)), INormiesStorage(address(normiesStorage)), owner);

        minter = new NormiesMinter(
            INormies(address(normies)), INormiesStorage(address(normiesStorage)), signerAddr, MINT_PRICE, owner
        );

        address[] memory minterAddrs = new address[](1);
        bool[] memory allowed = new bool[](1);
        minterAddrs[0] = address(minter);
        allowed[0] = true;
        normies.setMinterAddresses(minterAddrs, allowed);
        normiesStorage.setAuthorizedWriter(address(minter), true);
    }

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

    function testFork_DelegateRegistryExists() public view {
        assertTrue(address(minter.DELEGATE_REGISTRY()).code.length > 0);
    }

    function testFork_Mint_WithRealDelegation() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, VAULT, 2, block.timestamp + 900);

        vm.deal(DELEGATE, 1 ether);
        vm.prank(DELEGATE);
        minter.mint{ value: MINT_PRICE }(VAULT, imageData, traits, 2, block.timestamp + 900, sig);

        assertEq(normies.ownerOf(0), VAULT);
        assertEq(minter.mintCount(VAULT), 1);
    }

    function testFork_BatchMint_WithRealDelegation() public {
        uint256 count = 2;
        bytes[] memory imageDataArray = new bytes[](count);
        bytes8[] memory traitsArray = new bytes8[](count);
        for (uint256 i = 0; i < count; i++) {
            imageDataArray[i] = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
            traitsArray[i] = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        }
        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, VAULT, 10, block.timestamp + 900);

        vm.deal(DELEGATE, 1 ether);
        vm.prank(DELEGATE);
        minter.batchMint{ value: MINT_PRICE * count }(
            VAULT, imageDataArray, traitsArray, 10, block.timestamp + 900, sig
        );

        assertEq(normies.ownerOf(0), VAULT);
        assertEq(normies.ownerOf(1), VAULT);
        assertEq(minter.mintCount(VAULT), 2);
    }

    function testFork_Mint_NonDelegateReverts() public {
        address randomWallet = address(0xDEADBEEF);

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, VAULT, 2, block.timestamp + 900);

        vm.deal(randomWallet, 1 ether);
        vm.prank(randomWallet);
        vm.expectRevert(NormiesMinter.NotMinterOrDelegate.selector);
        minter.mint{ value: MINT_PRICE }(VAULT, imageData, traits, 2, block.timestamp + 900, sig);
    }
}
