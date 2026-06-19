// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesRendererV4 } from "../src/NormiesRendererV4.sol";
import { NormiesStorage } from "../src/NormiesStorage.sol";
import { NormiesCanvasStorage } from "../src/NormiesCanvasStorage.sol";
import { NormiesCanvas } from "../src/NormiesCanvas.sol";
import { NormiesZombie } from "../src/NormiesZombie.sol";
import { NormiesZombieStorage } from "../src/NormiesZombieStorage.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";
import { INormiesCanvasStorage } from "../src/interfaces/INormiesCanvasStorage.sol";
import { INormiesCanvas } from "../src/interfaces/INormiesCanvas.sol";
import { INormiesZombieStorage } from "../src/interfaces/INormiesZombieStorage.sol";

contract NormiesZombieTest is Test {
    Normies normies;
    NormiesRendererV4 rendererV4;
    NormiesStorage normiesStorage;
    NormiesCanvasStorage transformStorage;
    NormiesCanvas canvas;
    NormiesZombieStorage zombieStorage;
    NormiesZombie zombie;

    address user = address(0x1234);
    address user2 = address(0x5678);
    address hot = address(0xD31E);
    address buyer = address(0xB0B);
    address unauthorized = address(0xBEEF);

    bytes8 constant HUMAN_TRAITS = bytes8(uint64(0x000101020B00010A));
    bytes8 constant CAT_TRAITS = bytes8(uint64(0x010101020B00010A));
    bytes32 constant TEST_REVEAL_HASH = keccak256("test-secret");

    function setUp() public {
        normiesStorage = new NormiesStorage();
        transformStorage = new NormiesCanvasStorage();
        rendererV4 = new NormiesRendererV4(
            INormiesStorage(address(normiesStorage)), INormiesCanvasStorage(address(transformStorage))
        );
        normies =
            new Normies(INormiesRenderer(address(rendererV4)), INormiesStorage(address(normiesStorage)), address(this));
        canvas = new NormiesCanvas(
            address(normies), INormiesStorage(address(normiesStorage)), INormiesCanvasStorage(address(transformStorage))
        );
        zombieStorage = new NormiesZombieStorage();
        zombie = new NormiesZombie(
            address(normies),
            INormiesStorage(address(normiesStorage)),
            INormiesCanvas(address(canvas)),
            INormiesZombieStorage(address(zombieStorage))
        );

        rendererV4.setCanvasContract(INormiesCanvas(address(canvas)));
        transformStorage.setAuthorizedWriter(address(canvas), true);
        zombieStorage.setAuthorizedWriter(address(zombie), true);
        normiesStorage.setRevealHash(TEST_REVEAL_HASH);
        _addZombiePool(21);
        zombieStorage.sealPool();
        zombie.setPaused(false);
        vm.etch(address(0x721C008fdff27BF06E7E123956E2Fe03B63342e3), hex"00");
    }

    function testCommitRevealConvertsToken() public {
        _mintRevealedTo(user, 1, HUMAN_TRAITS, _bitmapWithPixels(40));
        bytes32 leaf = zombie.leafHash(0, user);
        zombie.setMerkleRoot(leaf);
        _lockSeed();

        vm.prank(user);
        uint256 commitId = zombie.commitConvert(1, 0, user, _emptyProof(), address(0));
        vm.roll(block.number + 6);

        vm.prank(unauthorized);
        zombie.revealConvert(commitId);

        assertTrue(zombieStorage.isZombie(1));
        assertEq(zombieStorage.poolIndexOf(1), zombie.assignedPoolIndex(0));
        assertTrue(zombie.hasClaimed(user));
        assertFalse(zombie.tokenLocked(1));
    }

    function testDelegateCanConvertVaultToken() public {
        _mintRevealedTo(user, 1, HUMAN_TRAITS, _bitmapWithPixels(40));
        bytes32 leaf = zombie.leafHash(0, user);
        zombie.setMerkleRoot(leaf);
        _lockSeed();
        _mockDelegateV2(hot, user, true);

        vm.prank(hot);
        uint256 commitId = zombie.commitConvert(1, 0, user, _emptyProof(), user);
        vm.roll(block.number + 6);
        zombie.revealConvert(commitId);

        assertTrue(zombieStorage.isZombie(1));
    }

    function testDelegateCanConvertTokenInHotWallet() public {
        _mintRevealedTo(hot, 1, HUMAN_TRAITS, _bitmapWithPixels(40));
        bytes32 leaf = zombie.leafHash(0, user);
        zombie.setMerkleRoot(leaf);
        _lockSeed();
        _mockDelegateV2(hot, user, true);

        vm.prank(hot);
        uint256 commitId = zombie.commitConvert(1, 0, user, _emptyProof(), user);
        vm.roll(block.number + 6);
        zombie.revealConvert(commitId);

        assertTrue(zombieStorage.isZombie(1));
    }

    function testOneClaimPerQualifyingWallet() public {
        _mintRevealedTo(user, 1, HUMAN_TRAITS, _bitmapWithPixels(40));
        _mintRevealedTo(user, 2, HUMAN_TRAITS, _bitmapWithPixels(41));
        zombie.setMerkleRoot(zombie.leafHash(0, user));
        _lockSeed();

        vm.startPrank(user);
        zombie.commitConvert(1, 0, user, _emptyProof(), address(0));
        vm.expectRevert(abi.encodeWithSelector(NormiesZombie.AlreadyClaimed.selector, user));
        zombie.commitConvert(2, 0, user, _emptyProof(), address(0));
        vm.stopPrank();
    }

    function testCancelCommitFreesWalletAndToken() public {
        _mintRevealedTo(user, 1, HUMAN_TRAITS, _bitmapWithPixels(40));
        zombie.setMerkleRoot(zombie.leafHash(0, user));
        _lockSeed();

        vm.prank(user);
        uint256 commitId = zombie.commitConvert(1, 0, user, _emptyProof(), address(0));

        vm.prank(user);
        zombie.cancelCommit(commitId);

        assertFalse(zombie.hasClaimed(user));
        assertFalse(zombie.tokenLocked(1));
        assertEq(zombie.pendingCommit(user), 0);
    }

    function testOwnershipChangedRevealReverts() public {
        _mintRevealedTo(user, 1, HUMAN_TRAITS, _bitmapWithPixels(40));
        zombie.setMerkleRoot(zombie.leafHash(0, user));
        _lockSeed();

        vm.prank(user);
        uint256 commitId = zombie.commitConvert(1, 0, user, _emptyProof(), address(0));
        vm.prank(user);
        normies.transferFrom(user, buyer, 1);
        vm.roll(block.number + 6);

        vm.expectRevert(abi.encodeWithSelector(NormiesZombie.OwnershipChanged.selector, 1));
        zombie.revealConvert(commitId);
    }

    function testRejectsNonHuman() public {
        _mintRevealedTo(user, 1, CAT_TRAITS, _bitmapWithPixels(40));
        zombie.setMerkleRoot(zombie.leafHash(0, user));
        _lockSeed();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(NormiesZombie.NotHuman.selector, 1));
        zombie.commitConvert(1, 0, user, _emptyProof(), address(0));
    }

    function testRejectsLevelTwo() public {
        _mintRevealedTo(user, 1, HUMAN_TRAITS, _bitmapWithPixels(40));
        _giveTokenTransformActions(1);
        zombie.setMerkleRoot(zombie.leafHash(0, user));
        _lockSeed();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(NormiesZombie.NotLevelOne.selector, 1));
        zombie.commitConvert(1, 0, user, _emptyProof(), address(0));
    }

    function testSeedLockRequiresSealedPoolWithAtLeastTwentyOneEntries() public {
        NormiesZombieStorage smallStorage = new NormiesZombieStorage();
        NormiesZombie smallZombie = new NormiesZombie(
            address(normies),
            INormiesStorage(address(normiesStorage)),
            INormiesCanvas(address(canvas)),
            INormiesZombieStorage(address(smallStorage))
        );
        smallStorage.addZombie(_bitmapWithPixels(1), _attrs("Only"));
        smallStorage.sealPool();
        smallZombie.setSeedBlock(block.number + 1);
        vm.roll(block.number + 2);

        vm.expectRevert(abi.encodeWithSelector(NormiesZombie.PoolNotReady.selector, 1));
        smallZombie.lockSeed();
    }

    function testRevealOrderDoesNotAffectAssignedZombie() public {
        _mintRevealedTo(user, 1, HUMAN_TRAITS, _bitmapWithPixels(40));
        _mintRevealedTo(user2, 2, HUMAN_TRAITS, _bitmapWithPixels(41));

        bytes32 leaf0 = zombie.leafHash(0, user);
        bytes32 leaf1 = zombie.leafHash(1, user2);
        zombie.setMerkleRoot(_hashPair(leaf0, leaf1));
        _lockSeed();
        uint256 expected0 = zombie.assignedPoolIndex(0);
        uint256 expected1 = zombie.assignedPoolIndex(1);

        bytes32[] memory proof0 = new bytes32[](1);
        proof0[0] = leaf1;
        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = leaf0;

        vm.prank(user);
        uint256 commit0 = zombie.commitConvert(1, 0, user, proof0, address(0));
        vm.prank(user2);
        uint256 commit1 = zombie.commitConvert(2, 1, user2, proof1, address(0));

        vm.roll(block.number + 6);
        zombie.revealConvert(commit1);
        zombie.revealConvert(commit0);

        assertEq(zombieStorage.poolIndexOf(1), expected0);
        assertEq(zombieStorage.poolIndexOf(2), expected1);
    }

    function testLeafMatchesStandardMerkleTreeFormula() public {
        assertEq(zombie.leafHash(4, user), keccak256(bytes.concat(keccak256(abi.encode(uint256(4), user)))));
    }

    function _lockSeed() internal {
        zombie.setSeedBlock(block.number + 1);
        vm.roll(block.number + 2);
        zombie.lockSeed();
    }

    function _addZombiePool(uint256 count) internal {
        for (uint256 i; i < count; i++) {
            zombieStorage.addZombie(_bitmapWithPixels(i + 1), _attrs(vm.toString(i)));
        }
    }

    function _attrs(string memory mutation) internal pure returns (bytes memory) {
        return bytes(
            abi.encodePacked(
                '{"trait_type":"Type","value":"Zombie"},{"trait_type":"Mutation","value":"', mutation, '"}'
            )
        );
    }

    function _mockDelegateV2(address delegate, address vault, bool allowed) internal {
        vm.mockCall(
            address(zombie.DELEGATE_REGISTRY_V2()),
            abi.encodeWithSelector(
                zombie.DELEGATE_REGISTRY_V2().checkDelegateForAll.selector, delegate, vault, bytes32(0)
            ),
            abi.encode(allowed)
        );
    }

    function _mintRevealedTo(address to, uint256 tokenId, bytes8 traits, bytes memory bitmap) internal {
        normies.mint(to, tokenId);
        normiesStorage.setTokenRawImageData(tokenId, _xorEncryptImageData(bitmap, TEST_REVEAL_HASH));
        normiesStorage.setTokenTraits(tokenId, traits ^ bytes8(TEST_REVEAL_HASH));
    }

    function _giveTokenTransformActions(uint256 targetTokenId) internal {
        _mintRevealedTo(user, 9000, HUMAN_TRAITS, _bitmapWithPixels(1600));
        vm.startPrank(user);
        normies.setApprovalForAll(address(canvas), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 9000;
        uint256 commitId = canvas.nextCommitId();
        canvas.commitBurn(ids, targetTokenId);
        vm.roll(block.number + 6);
        canvas.revealBurn(commitId);
        vm.stopPrank();
        assertGt(canvas.getLevel(targetTokenId), 1);
    }

    function _bitmapWithPixels(uint256 pixelCount) internal pure returns (bytes memory) {
        bytes memory bitmap = new bytes(200);
        uint256 set;
        for (uint256 i; i < 200 && set < pixelCount; i++) {
            uint256 bitsToSet = pixelCount - set;
            if (bitsToSet >= 8) {
                bitmap[i] = bytes1(0xFF);
                set += 8;
            } else {
                bitmap[i] = bytes1(uint8(0xFF << (8 - bitsToSet)));
                set += bitsToSet;
            }
        }
        return bitmap;
    }

    function _xorEncryptImageData(bytes memory data, bytes32 revealHash) internal pure returns (bytes memory) {
        bytes memory encrypted = new bytes(data.length);
        bytes32 key;
        for (uint256 i; i < data.length; i++) {
            if (i & 31 == 0) {
                key = keccak256(abi.encodePacked(revealHash, i >> 5));
            }
            encrypted[i] = bytes1(uint8(data[i]) ^ uint8(key[i & 31]));
        }
        return encrypted;
    }

    function _emptyProof() internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](0);
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
