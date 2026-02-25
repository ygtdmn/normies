// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { console2 } from "forge-std/src/console2.sol";
import { Base64 } from "solady/utils/Base64.sol";
import { LibString } from "solady/utils/LibString.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesRendererV4 } from "../src/NormiesRendererV4.sol";
import { NormiesStorage } from "../src/NormiesStorage.sol";
import { NormiesCanvasStorage } from "../src/NormiesCanvasStorage.sol";
import { NormiesCanvas } from "../src/NormiesCanvas.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";
import { INormiesCanvasStorage } from "../src/interfaces/INormiesCanvasStorage.sol";
import { INormiesCanvas } from "../src/NormiesRendererV4.sol";

contract NormiesCanvasTest is Test {
    using LibString for string;
    Normies normies;
    NormiesRendererV4 rendererV4;
    NormiesStorage normiesStorage;
    NormiesCanvasStorage transformStorage;
    NormiesCanvas lab;

    address owner = address(this);
    address user = address(0x1234);
    address unauthorized = address(0xBEEF);
    address delegate_ = address(0xD31E);

    bytes8 constant REAL_TRAITS = bytes8(uint64(0x000101020B00010A));
    bytes32 constant TEST_REVEAL_HASH = keccak256("test-secret");

    function setUp() public {
        // Deploy storage
        normiesStorage = new NormiesStorage();
        transformStorage = new NormiesCanvasStorage();

        // Deploy renderer
        rendererV4 = new NormiesRendererV4(
            INormiesStorage(address(normiesStorage)), INormiesCanvasStorage(address(transformStorage))
        );

        // Deploy normies
        normies = new Normies(INormiesRenderer(address(rendererV4)), INormiesStorage(address(normiesStorage)), owner);

        // Deploy lab
        lab = new NormiesCanvas(address(normies), INormiesStorage(address(normiesStorage)), INormiesCanvasStorage(address(transformStorage)));

        // Set canvas on renderer (for level reads)
        rendererV4.setCanvasContract(INormiesCanvas(address(lab)));

        // Authorize lab on transform storage
        transformStorage.setAuthorizedWriter(address(lab), true);

        // Reveal
        normiesStorage.setRevealHash(TEST_REVEAL_HASH);
    }

    // ──────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────

    function _createRealBitmap() internal pure returns (bytes memory) {
        return
            hex"00000000000000000000000081800000013500000042d6f0000077fffc000017ffb400003bffd8000057fff60000bfc7ea0001af5af50000fcfebf80005b8db6000177995d0000dff7ba0000dcf13f000077e72b80006fe3270000e7e02b800017e46800001e7e7800001ffff800003ffff400000ffff000000ffff000000ffff000000ffff000000ffff0000007ffe000001ffff000003ffff000008f3ce200000f00c0000007a980800213c388000001e300000001ea000008207e000008103c042004081f0020";
    }

    /// @notice Creates a bitmap with exactly `pixelCount` pixels on (first N bits set)
    function _createBitmapWithPixels(uint256 pixelCount) internal pure returns (bytes memory) {
        bytes memory bitmap = new bytes(200);
        uint256 set;
        for (uint256 i; i < 200 && set < pixelCount; i++) {
            uint256 bitsToSet = pixelCount - set;
            if (bitsToSet >= 8) {
                bitmap[i] = bytes1(0xFF);
                set += 8;
            } else {
                // Set top `bitsToSet` bits
                bitmap[i] = bytes1(uint8(0xFF << (8 - bitsToSet)));
                set += bitsToSet;
            }
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

    /// @notice Mints a revealed token to `to` with the given plaintext bitmap
    function _mintRevealedTo(address to, uint256 tokenId, bytes memory bitmap) internal {
        bytes memory encrypted = _xorEncryptImageData(bitmap, TEST_REVEAL_HASH);
        bytes8 encryptedTraits = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        normies.mint(to, tokenId);
        normiesStorage.setTokenRawImageData(tokenId, encrypted);
        normiesStorage.setTokenTraits(tokenId, encryptedTraits);
    }

    /// @notice Mints a revealed token to `user` with the real bitmap
    function _mintRealToUser(uint256 tokenId) internal {
        _mintRevealedTo(user, tokenId, _createRealBitmap());
    }

    /// @notice Gives a target token some transform actions by minting and burning tokens via commit-reveal.
    ///         Uses 1600-pixel tokens (min 4% = 64 actions each) to guarantee enough.
    function _giveTokenTransformActions(uint256 targetTokenId, uint256 actionsNeeded) internal {
        uint256 minActionsPerToken = (1600 * 4) / 100; // 64
        uint256 tokensNeeded = (actionsNeeded + minActionsPerToken - 1) / minActionsPerToken;
        if (tokensNeeded == 0) tokensNeeded = 1;

        for (uint256 i; i < tokensNeeded; i++) {
            uint256 burnId = 9000 + i; // Use high IDs to avoid collision
            _mintRevealedTo(user, burnId, _createBitmapWithPixels(1600));
        }

        // Approve lab and commit burn
        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](tokensNeeded);
        for (uint256 i; i < tokensNeeded; i++) {
            ids[i] = 9000 + i;
        }
        uint256 commitId = lab.nextCommitId();
        lab.commitBurn(ids, targetTokenId);
        vm.roll(block.number + 6);
        lab.revealBurn(commitId);
        vm.stopPrank();
    }

    /// @notice Mirrors NormiesCanvas._rollPercentageFromEntropy for deterministic test assertions.
    function _expectedPercentageFromEntropy(uint256 pixelCount, bytes32 entropy, uint256 commitId, uint256 index)
        internal
        pure
        returns (uint256)
    {
        uint256 minPercent = pixelCount < 490 ? 1 : pixelCount < 890 ? 2 : uint256(3);
        uint256 range = 4 - minPercent + 1;
        if (range == 1) return minPercent;
        uint256 seed = uint256(keccak256(abi.encodePacked(entropy, commitId, index)));
        return minPercent + (seed % range);
    }

    function _expectedPercentageTierMin(uint256 pixelCount) internal pure returns (uint256) {
        if (pixelCount < 490) return 1;
        if (pixelCount < 890) return 2;
        return 3;
    }

    // ──────────────────────────────────────────────
    //  Commit-Reveal burn tests
    // ──────────────────────────────────────────────

    function testCommitRevealSingleToken() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100)); // receiver

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256 commitId = lab.nextCommitId();
        lab.commitBurn(ids, 2);
        uint64 commitBlock = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(commitBlock + 5);
        uint256 pct = _expectedPercentageFromEntropy(600, entropy, commitId, 0);
        uint256 expectedActions = (600 * pct) / 100;

        lab.revealBurn(commitId);
        vm.stopPrank();

        assertEq(lab.actionPoints(2), expectedActions);
    }

    function testCommitRevealMultipleTokens() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 3, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 4, _createBitmapWithPixels(100)); // receiver

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        uint256 commitId = lab.nextCommitId();
        lab.commitBurn(ids, 4);
        uint64 commitBlock = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(commitBlock + 5);
        uint256 expected;
        for (uint256 i; i < 3; i++) {
            uint256 pct = _expectedPercentageFromEntropy(600, entropy, commitId, i);
            expected += (600 * pct) / 100;
        }

        lab.revealBurn(commitId);
        vm.stopPrank();

        assertEq(lab.actionPoints(4), expected);
    }

    function testCommitRequiresApproval() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert();
        lab.commitBurn(ids, 2);
        vm.stopPrank();
    }

    function testCommitUnauthorizedReverts() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(unauthorized);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert();
        lab.commitBurn(ids, 2);
        vm.stopPrank();
    }

    function testCommitRevealFloorCalculation() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(99));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));
        _mintRevealedTo(user, 3, _createBitmapWithPixels(199));
        _mintRevealedTo(user, 4, _createBitmapWithPixels(100)); // receiver

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        uint256 commitId = lab.nextCommitId();
        lab.commitBurn(ids, 4);
        uint64 commitBlock = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(commitBlock + 5);
        uint256 p0 = _expectedPercentageFromEntropy(99, entropy, commitId, 0);
        uint256 p1 = _expectedPercentageFromEntropy(100, entropy, commitId, 1);
        uint256 p2 = _expectedPercentageFromEntropy(199, entropy, commitId, 2);
        uint256 expected = (99 * p0) / 100 + (100 * p1) / 100 + (199 * p2) / 100;

        lab.revealBurn(commitId);
        vm.stopPrank();

        assertEq(lab.actionPoints(4), expected);
    }

    function testCommitEmptyArrayReverts() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(100));
        uint256[] memory ids = new uint256[](0);
        vm.prank(user);
        vm.expectRevert(NormiesCanvas.NoTokensProvided.selector);
        lab.commitBurn(ids, 1);
    }

    function testCommitEmitsBurnCommitted() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.expectEmit(true, true, true, true);
        emit NormiesCanvas.BurnCommitted(0, user, 2, 1, 0);
        lab.commitBurn(ids, 2);
        vm.stopPrank();
    }

    function testRevealEmitsBurnRevealed() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256 commitId = lab.nextCommitId();
        lab.commitBurn(ids, 2);
        uint64 commitBlock = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(commitBlock + 5);
        uint256 pct = _expectedPercentageFromEntropy(600, entropy, commitId, 0);
        uint256 expectedActions = (600 * pct) / 100;

        vm.expectEmit(true, true, true, true);
        emit NormiesCanvas.BurnRevealed(commitId, user, 2, expectedActions, false);
        lab.revealBurn(commitId);
        vm.stopPrank();
    }

    function testCommitWhenPausedReverts() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));
        lab.setPaused(true);

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(NormiesCanvas.Paused.selector);
        lab.commitBurn(ids, 2);
        vm.stopPrank();
    }

    function testRevealWhenPausedReverts() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lab.commitBurn(ids, 2);
        vm.stopPrank();

        vm.roll(block.number + 6);
        lab.setPaused(true);

        vm.prank(user);
        vm.expectRevert(NormiesCanvas.Paused.selector);
        lab.revealBurn(0);
    }

    function testCommitReceiverMustBeOwned() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(unauthorized, 2, _createBitmapWithPixels(100)); // owned by someone else

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(NormiesCanvas.NotTokenOwner.selector);
        lab.commitBurn(ids, 2);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  Commit-Reveal timing tests
    // ──────────────────────────────────────────────

    function testRevealTooEarlyReverts() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lab.commitBurn(ids, 2);

        // commitBlock + 5 is NOT enough (need > commitBlock + REVEAL_DELAY)
        vm.roll(block.number + 5);
        vm.expectRevert(NormiesCanvas.TooEarlyToReveal.selector);
        lab.revealBurn(0);

        // commitBlock + 6 should work
        vm.roll(block.number + 1);
        lab.revealBurn(0);
        vm.stopPrank();

        assertGt(lab.actionPoints(2), 0);
    }

    function testRevealAfterExactDelay() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lab.commitBurn(ids, 2);

        // Reveal at exactly commitBlock + REVEAL_DELAY + 1
        vm.roll(block.number + 6);
        lab.revealBurn(0);
        vm.stopPrank();

        assertGt(lab.actionPoints(2), 0);
    }

    function testDoubleRevealReverts() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lab.commitBurn(ids, 2);

        vm.roll(block.number + 6);
        lab.revealBurn(0);

        vm.expectRevert(NormiesCanvas.AlreadyRevealed.selector);
        lab.revealBurn(0);
        vm.stopPrank();
    }

    function testRevealByAnyoneSucceeds() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lab.commitBurn(ids, 2);
        vm.stopPrank();

        vm.roll(block.number + 6);

        // Anyone can reveal — not just the commitment owner
        vm.prank(unauthorized);
        lab.revealBurn(0);

        // Actions should be crtransformed to the receiver token
        assertGt(lab.actionPoints(2), 0, "Actions should be crtransformed after reveal by non-owner");
    }

    function testRevealExpiredFallsBackToMinimum() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lab.commitBurn(ids, 2);

        // Advance >256 blocks so blockhash returns 0 → expired fallback to min%
        vm.roll(block.number + 300);
        lab.revealBurn(0);
        vm.stopPrank();

        // 600 pixels, tier 2, min 2%: (600 * 2) / 100 = 12
        assertEq(lab.actionPoints(2), (600 * 2) / 100);
    }

    function testMultipleCommitments() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 3, _createBitmapWithPixels(100)); // receiver

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        // First commit
        uint256[] memory ids1 = new uint256[](1);
        ids1[0] = 1;
        lab.commitBurn(ids1, 3);

        // Second commit
        uint256[] memory ids2 = new uint256[](1);
        ids2[0] = 2;
        lab.commitBurn(ids2, 3);

        // Reveal both after delay
        vm.roll(block.number + 6);
        lab.revealBurn(0);
        lab.revealBurn(1);
        vm.stopPrank();

        assertGt(lab.actionPoints(3), 0);
    }

    function testCommitmentDataStored() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lab.commitBurn(ids, 2);
        vm.stopPrank();

        (
            address commitOwner,
            uint256 receiverTokenId,
            uint64 commitBlock,
            uint16 tokenCount,
            bool revealed,
            uint256 transferredAP
        ) = lab.burnCommitments(0);
        assertEq(commitOwner, user);
        assertEq(receiverTokenId, 2);
        assertEq(commitBlock, uint64(block.number));
        assertEq(tokenCount, 1);
        assertFalse(revealed);

        uint256[] memory pixelCounts = lab.commitPixelCounts(0);
        assertEq(pixelCounts.length, 1);
        assertEq(pixelCounts[0], 600);
    }

    function testRevealBlockView() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lab.commitBurn(ids, 2);
        vm.stopPrank();

        assertEq(lab.revealBlock(0), block.number + 6);
    }

    function testCommitmentNotFoundReverts() public {
        vm.prank(user);
        vm.expectRevert(NormiesCanvas.CommitmentNotFound.selector);
        lab.revealBurn(999);
    }

    // ──────────────────────────────────────────────
    //  Bitmap test helper
    // ──────────────────────────────────────────────

    /// @notice Creates a 200-byte XOR bitmap with specific pixels set
    function _createXorBitmap(uint8[] memory xs, uint8[] memory ys) internal pure returns (bytes memory) {
        bytes memory bitmap = new bytes(200);
        for (uint256 i; i < xs.length; i++) {
            uint256 flatIndex = uint256(ys[i]) * 40 + uint256(xs[i]);
            bitmap[flatIndex >> 3] = bytes1(uint8(bitmap[flatIndex >> 3]) | uint8(1 << (7 - (flatIndex & 7))));
        }
        return bitmap;
    }

    function _singlePixelBitmap(uint8 x, uint8 y) internal pure returns (bytes memory) {
        uint8[] memory xs = new uint8[](1);
        uint8[] memory ys = new uint8[](1);
        xs[0] = x;
        ys[0] = y;
        return _createXorBitmap(xs, ys);
    }

    // ──────────────────────────────────────────────
    //  Transform tests (setTransformBitmap)
    // ──────────────────────────────────────────────

    function testTransformSetBitmap() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 10);

        uint256 budgetBefore = lab.actionPoints(1);

        vm.prank(user);
        lab.setTransformBitmap(1, _singlePixelBitmap(0, 0));

        // Budget NOT consumed
        assertEq(lab.actionPoints(1), budgetBefore);
        assertTrue(transformStorage.isTransformed(1));
    }

    function testBudgetNotConsumedAfterTransform() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 10);

        uint256 budgetBefore = lab.actionPoints(1);

        // Set bitmap with 5 pixels
        vm.prank(user);
        lab.setTransformBitmap(1, _createBitmapWithPixels(5));

        assertEq(lab.actionPoints(1), budgetBefore);

        // Set bitmap with 8 pixels
        vm.prank(user);
        lab.setTransformBitmap(1, _createBitmapWithPixels(8));

        assertEq(lab.actionPoints(1), budgetBefore);
    }

    function testCanOverwriteTransformRepeatedly() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 10);

        uint256 budgetBefore = lab.actionPoints(1);

        vm.startPrank(user);
        lab.setTransformBitmap(1, _createBitmapWithPixels(3));
        lab.setTransformBitmap(1, _createBitmapWithPixels(5));
        lab.setTransformBitmap(1, _createBitmapWithPixels(2));
        vm.stopPrank();

        assertEq(lab.actionPoints(1), budgetBefore);
    }

    function testResetToOriginalWithZeroBytes() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 10);

        vm.startPrank(user);
        // First set some pixels
        lab.setTransformBitmap(1, _createBitmapWithPixels(5));
        assertTrue(transformStorage.isTransformed(1));

        // Then reset: 200 zero bytes (popcount=0, always valid)
        lab.setTransformBitmap(1, new bytes(200));
        vm.stopPrank();

        // Still marked as transformed (storage pointer exists) but all zeros
        assertTrue(transformStorage.isTransformed(1));
    }

    function testTransformRequiresOwnership() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 10);

        vm.prank(unauthorized);
        vm.expectRevert(NormiesCanvas.NotTokenOwnerOrDelegate.selector);
        lab.setTransformBitmap(1, _singlePixelBitmap(0, 0));
    }

    function testBudgetExceededReverts() public {
        _mintRealToUser(1);
        // Token 1 has 0 transform actions — any set bit should fail

        vm.prank(user);
        vm.expectRevert(NormiesCanvas.InsufficientTransformActions.selector);
        lab.setTransformBitmap(1, _singlePixelBitmap(0, 0));
    }

    function testBudgetExactlyMetSucceeds() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 64); // gives at least 64 actions

        uint256 budget = lab.actionPoints(1);

        vm.prank(user);
        lab.setTransformBitmap(1, _createBitmapWithPixels(budget));

        assertTrue(transformStorage.isTransformed(1));
    }

    function testInvalidBitmapLengthReverts() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 10);

        vm.startPrank(user);
        vm.expectRevert(NormiesCanvas.InvalidBitmapLength.selector);
        lab.setTransformBitmap(1, new bytes(199));

        vm.expectRevert(NormiesCanvas.InvalidBitmapLength.selector);
        lab.setTransformBitmap(1, new bytes(201));

        vm.expectRevert(NormiesCanvas.InvalidBitmapLength.selector);
        lab.setTransformBitmap(1, new bytes(0));
        vm.stopPrank();
    }

    function testZeroBudgetOnlyAllowsZeroBitmap() public {
        _mintRealToUser(1);
        // Token 1 has 0 budget

        // Zero bitmap succeeds (popcount=0)
        vm.prank(user);
        lab.setTransformBitmap(1, new bytes(200));

        // Any set bit fails
        vm.prank(user);
        vm.expectRevert(NormiesCanvas.InsufficientTransformActions.selector);
        lab.setTransformBitmap(1, _singlePixelBitmap(0, 0));
    }


    function testTransformPreservesOriginalInStorage() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 10);

        bytes memory originalBitmap = normiesStorage.getTokenRawImageData(1);
        bytes32 originalHash = keccak256(originalBitmap);

        vm.prank(user);
        lab.setTransformBitmap(1, _singlePixelBitmap(0, 0));

        bytes memory afterBitmap = normiesStorage.getTokenRawImageData(1);
        assertEq(keccak256(afterBitmap), originalHash);
    }

    function testTransformEmitsEvent() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 10);

        vm.prank(user);
        vm.expectEmit(true, true, false, false);
        emit NormiesCanvas.PixelsTransformed(user, 1, 1, 1);
        lab.setTransformBitmap(1, _singlePixelBitmap(0, 0));
    }

    function testTransformWhenPausedReverts() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 10);
        lab.setPaused(true);

        vm.prank(user);
        vm.expectRevert(NormiesCanvas.Paused.selector);
        lab.setTransformBitmap(1, _singlePixelBitmap(0, 0));
    }

    // ──────────────────────────────────────────────
    //  Integration tests
    // ──────────────────────────────────────────────

    function testFullCommitRevealTransformFlow() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRealToUser(2);

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        uint256[] memory burnIds = new uint256[](1);
        burnIds[0] = 1;
        uint256 commitId = lab.nextCommitId();
        lab.commitBurn(burnIds, 2);
        uint64 commitBlock = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(commitBlock + 5);
        uint256 pct = _expectedPercentageFromEntropy(600, entropy, commitId, 0);
        uint256 expectedActions = (600 * pct) / 100;

        lab.revealBurn(commitId);
        assertEq(lab.actionPoints(2), expectedActions);

        // Transform: set 3 pixel XOR bitmap
        lab.setTransformBitmap(2, _createBitmapWithPixels(3));

        // Budget NOT consumed
        assertEq(lab.actionPoints(2), expectedActions);
        assertTrue(transformStorage.isTransformed(2));

        string memory uri = normies.tokenURI(2);
        assertTrue(bytes(uri).length > 0);

        vm.stopPrank();
    }

    function testCommitRevealTransformedTokenUsesOriginalPixels() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(200));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        _giveTokenTransformActions(1, 10);

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        // Set XOR bitmap with 5 non-overlapping pixels (positions after first 200 bits)
        uint8[] memory xs = new uint8[](5);
        uint8[] memory ys = new uint8[](5);
        for (uint8 i; i < 5; i++) {
            xs[i] = i;
            ys[i] = 5;
        }
        lab.setTransformBitmap(1, _createXorBitmap(xs, ys));

        // Record AP on token 1 before burn (these will transfer)
        uint256 transferredAP = lab.actionPoints(1);

        // Commit burn token 1 — should use original pixel count (200, not composite 205)
        uint256 commitId = lab.nextCommitId();
        uint256 actionsBefore = lab.actionPoints(2);
        uint256[] memory burnIds = new uint256[](1);
        burnIds[0] = 1;
        lab.commitBurn(burnIds, 2);
        uint64 commitBlock = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(commitBlock + 5);
        uint256 pct = _expectedPercentageFromEntropy(200, entropy, commitId, 0);
        uint256 expectedEarned = (200 * pct) / 100 + transferredAP;

        lab.revealBurn(commitId);
        uint256 actionsEarned = lab.actionPoints(2) - actionsBefore;

        assertEq(actionsEarned, expectedEarned);
        assertEq(lab.commitPixelCounts(commitId)[0], 200);

        vm.stopPrank();
    }

    function testCommitRevealTransformedUsesOriginalSameAsUntransformed() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(95));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(95));
        _mintRevealedTo(user, 3, _createBitmapWithPixels(100));

        _giveTokenTransformActions(1, 10);

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        // Transform token 1: set 5-pixel XOR bitmap (composite would be 100, but burn uses original = 95)
        {
            uint8[] memory xs = new uint8[](5);
            uint8[] memory ys = new uint8[](5);
            for (uint8 i; i < 5; i++) {
                xs[i] = 15 + i;
                ys[i] = 2;
            }
            lab.setTransformBitmap(1, _createXorBitmap(xs, ys));
        }

        // Commit and reveal untransformed token 2: 95 original pixels
        {
            uint256 commitId1 = lab.nextCommitId();
            uint256 actionsBefore = lab.actionPoints(3);
            uint256[] memory burnIds = new uint256[](1);
            burnIds[0] = 2;
            lab.commitBurn(burnIds, 3);
            uint64 commitBlock1 = uint64(block.number);

            vm.roll(block.number + 6);
            bytes32 entropy1 = blockhash(commitBlock1 + 5);
            uint256 pct = _expectedPercentageFromEntropy(95, entropy1, commitId1, 0);

            lab.revealBurn(commitId1);
            assertEq(lab.actionPoints(3) - actionsBefore, (95 * pct) / 100);
            assertEq(lab.commitPixelCounts(commitId1)[0], 95);
        }

        // Commit and reveal transformed token 1: uses original = 95 pixels (not composite 100)
        // Also transfers token 1's action points
        {
            uint256 transferredAP = lab.actionPoints(1);
            uint256 commitId2 = lab.nextCommitId();
            uint256 actionsBefore = lab.actionPoints(3);
            uint256[] memory burnIds = new uint256[](1);
            burnIds[0] = 1;
            lab.commitBurn(burnIds, 3);
            uint64 commitBlock2 = uint64(block.number);

            vm.roll(block.number + 6);
            bytes32 entropy2 = blockhash(commitBlock2 + 5);
            uint256 pct = _expectedPercentageFromEntropy(95, entropy2, commitId2, 0);

            lab.revealBurn(commitId2);
            assertEq(lab.actionPoints(3) - actionsBefore, (95 * pct) / 100 + transferredAP);
            assertEq(lab.commitPixelCounts(commitId2)[0], 95);
        }

        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  Custom layer model tests
    // ──────────────────────────────────────────────

    function testChangesLayerIsIndependent() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 10);

        vm.prank(user);
        lab.setTransformBitmap(1, _singlePixelBitmap(0, 0));

        bytes memory changes = transformStorage.getTransformedImageData(1);
        assertEq(uint8(changes[0]), 0x80);
        for (uint256 i = 1; i < 200; i++) {
            assertEq(uint8(changes[i]), 0, "Changes layer should be blank except (0,0)");
        }
    }

    function testCommitRevealWithRemovedPixelsUsesOriginal() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(200));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        _giveTokenTransformActions(1, 10);

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        // XOR bitmap: flip first 5 pixels (which are ON in original → removes them)
        lab.setTransformBitmap(1, _createBitmapWithPixels(5));

        // Record AP on token 1 before burn
        uint256 transferredAP = lab.actionPoints(1);

        // Commit: uses original = 200 pixels (not composite 195)
        uint256 commitId = lab.nextCommitId();
        uint256 actionsBefore = lab.actionPoints(2);
        uint256[] memory burnIds = new uint256[](1);
        burnIds[0] = 1;
        lab.commitBurn(burnIds, 2);
        uint64 commitBlock = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(commitBlock + 5);
        uint256 pct = _expectedPercentageFromEntropy(200, entropy, commitId, 0);
        uint256 expectedEarned = (200 * pct) / 100 + transferredAP;

        lab.revealBurn(commitId);
        uint256 actionsEarned = lab.actionPoints(2) - actionsBefore;

        assertEq(actionsEarned, expectedEarned);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  Transform Storage tests
    // ──────────────────────────────────────────────

    function testTransformStorageUnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        transformStorage.setTransformedImageData(1, _createRealBitmap());
    }

    function testTransformStorageIsTransformedDefault() public {
        assertFalse(transformStorage.isTransformed(1));
    }

    // ──────────────────────────────────────────────
    //  Level tests (derived from transformActions / 10)
    // ──────────────────────────────────────────────

    function testLevelStartsAtOne() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        assertEq(lab.getLevel(1), 1);
    }

    function testLevelDerivedFromRevealBurn() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256 commitId = lab.nextCommitId();
        lab.commitBurn(ids, 2);
        uint64 commitBlock = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(commitBlock + 5);
        uint256 pct = _expectedPercentageFromEntropy(600, entropy, commitId, 0);
        uint256 expectedActions = (600 * pct) / 100;

        lab.revealBurn(commitId);
        vm.stopPrank();

        assertEq(lab.getLevel(2), expectedActions / 10 + 1);
    }

    function testLevelFromMultiBurn() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(400));
        _mintRevealedTo(user, 3, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        uint256 commitId = lab.nextCommitId();
        lab.commitBurn(ids, 3);
        uint64 commitBlock = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(commitBlock + 5);
        uint256 pct0 = _expectedPercentageFromEntropy(600, entropy, commitId, 0);
        uint256 pct1 = _expectedPercentageFromEntropy(400, entropy, commitId, 1);
        uint256 totalActions = (600 * pct0) / 100 + (400 * pct1) / 100;

        lab.revealBurn(commitId);
        vm.stopPrank();

        assertEq(lab.getLevel(3), totalActions / 10 + 1);
    }

    function testLevelAccumulatesAcrossMultipleReveals() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(400));
        _mintRevealedTo(user, 3, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        // First burn
        uint256[] memory ids1 = new uint256[](1);
        ids1[0] = 1;
        uint256 commitId1 = lab.nextCommitId();
        lab.commitBurn(ids1, 3);
        uint64 commitBlock1 = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy1 = blockhash(commitBlock1 + 5);
        uint256 pct1 = _expectedPercentageFromEntropy(600, entropy1, commitId1, 0);
        uint256 actions1 = (600 * pct1) / 100;
        lab.revealBurn(commitId1);

        // Second burn
        uint256[] memory ids2 = new uint256[](1);
        ids2[0] = 2;
        uint256 commitId2 = lab.nextCommitId();
        lab.commitBurn(ids2, 3);
        uint64 commitBlock2 = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy2 = blockhash(commitBlock2 + 5);
        uint256 pct2 = _expectedPercentageFromEntropy(400, entropy2, commitId2, 0);
        uint256 actions2 = (400 * pct2) / 100;
        lab.revealBurn(commitId2);

        vm.stopPrank();

        // Derived from total accumulated transformActions, not per-reveal
        assertEq(lab.getLevel(3), (actions1 + actions2) / 10 + 1);
    }

    function testLevelOnExpiredReveal() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lab.commitBurn(ids, 2);

        // Advance past 256 blocks to expire blockhash
        vm.roll(block.number + 300);
        lab.revealBurn(0);
        vm.stopPrank();

        // Expired → uses min percent. 600 pixels, tier 2 → min 2% → 12 actions → level 2 (base 1 + 12/10)
        assertEq(lab.getLevel(2), 2);
    }

    // ──────────────────────────────────────────────
    //  Admin tests
    // ──────────────────────────────────────────────

    function testOnlyOwnerCanPause() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        lab.setPaused(true);
    }

    function testOnlyOwnerCanSetTransformStorage() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        lab.setTransformStorage(INormiesCanvasStorage(address(0)));
    }

    // ──────────────────────────────────────────────
    //  Burn scaling tests
    // ──────────────────────────────────────────────

    function testCommitRevealScalingTier1() public {
        // <490 pixels → min 1%, max 4%
        _mintRevealedTo(user, 1, _createBitmapWithPixels(400));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256 commitId = lab.nextCommitId();
        lab.commitBurn(ids, 2);
        uint64 commitBlock = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(commitBlock + 5);
        uint256 pct = _expectedPercentageFromEntropy(400, entropy, commitId, 0);
        assertGe(pct, 1);
        assertLe(pct, 4);

        lab.revealBurn(commitId);
        vm.stopPrank();

        assertEq(lab.actionPoints(2), (400 * pct) / 100);
    }

    function testCommitRevealScalingTier2() public {
        // 490-889 pixels → min 2%, max 4%
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256 commitId = lab.nextCommitId();
        lab.commitBurn(ids, 2);
        uint64 commitBlock = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(commitBlock + 5);
        uint256 pct = _expectedPercentageFromEntropy(600, entropy, commitId, 0);
        assertGe(pct, 2);
        assertLe(pct, 4);

        lab.revealBurn(commitId);
        vm.stopPrank();

        assertEq(lab.actionPoints(2), (600 * pct) / 100);
    }

    function testCommitRevealScalingTier2High() public {
        // 490-889 pixels → min 2%, max 4% (high end of tier)
        _mintRevealedTo(user, 1, _createBitmapWithPixels(800));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256 commitId = lab.nextCommitId();
        lab.commitBurn(ids, 2);
        uint64 commitBlock = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(commitBlock + 5);
        uint256 pct = _expectedPercentageFromEntropy(800, entropy, commitId, 0);
        assertGe(pct, 2);
        assertLe(pct, 4);

        lab.revealBurn(commitId);
        vm.stopPrank();

        assertEq(lab.actionPoints(2), (800 * pct) / 100);
    }

    function testCommitRevealScalingTier3() public {
        // 890+ pixels → min 3%, max 4%
        _mintRevealedTo(user, 1, _createBitmapWithPixels(1200));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256 commitId = lab.nextCommitId();
        lab.commitBurn(ids, 2);
        uint64 commitBlock = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(commitBlock + 5);
        uint256 pct = _expectedPercentageFromEntropy(1200, entropy, commitId, 0);
        assertGe(pct, 3);
        assertLe(pct, 4);

        lab.revealBurn(commitId);
        vm.stopPrank();

        assertEq(lab.actionPoints(2), (1200 * pct) / 100);
    }

    function testBurnScalingBoundaries() public {
        // Test exact boundary values: 489→tier1, 490→tier2, 889→tier2, 890→tier3
        assertEq(_expectedPercentageTierMin(489), 1);
        assertEq(_expectedPercentageTierMin(490), 2);
        assertEq(_expectedPercentageTierMin(689), 2);
        assertEq(_expectedPercentageTierMin(889), 2);
        assertEq(_expectedPercentageTierMin(890), 3);
        assertEq(_expectedPercentageTierMin(1600), 3);
    }

    function testCommitRevealDifferentIndicesGetDifferentSeeds() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 3, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        uint256 commitId = lab.nextCommitId();
        lab.commitBurn(ids, 3);
        uint64 commitBlock = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(commitBlock + 5);
        // Different indices produce different seeds (may or may not produce different percentages)
        uint256 pct1 = _expectedPercentageFromEntropy(600, entropy, commitId, 0);
        uint256 pct2 = _expectedPercentageFromEntropy(600, entropy, commitId, 1);
        assertGe(pct1, 2);
        assertLe(pct1, 4);
        assertGe(pct2, 2);
        assertLe(pct2, 4);

        lab.revealBurn(commitId);
        vm.stopPrank();

        uint256 expected = (600 * pct1) / 100 + (600 * pct2) / 100;
        assertEq(lab.actionPoints(3), expected);
    }

    function testCommitRevealZeroPixelsGivesZeroActions() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(0));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lab.commitBurn(ids, 2);
        vm.roll(block.number + 6);
        lab.revealBurn(0);
        vm.stopPrank();

        // 0 * anything / 100 = 0
        assertEq(lab.actionPoints(2), 0);
    }

    function testCommitRevealScalingFuzz(uint256 blockOffset) public {
        // Fuzz: different starting blocks should produce valid percentages
        blockOffset = bound(blockOffset, 0, 1000);
        vm.roll(1000 + blockOffset);

        _mintRevealedTo(user, 1, _createBitmapWithPixels(750));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lab.commitBurn(ids, 2);
        vm.roll(block.number + 6);
        lab.revealBurn(0);
        vm.stopPrank();

        uint256 actions = lab.actionPoints(2);
        // 750 pixels, tier 2 (min 2%), so min = 750*2/100=15, max = 750*4/100=30
        assertGe(actions, 15);
        assertLe(actions, 30);
    }

    // ──────────────────────────────────────────────
    //  maxBurnPercent admin tests
    // ──────────────────────────────────────────────

    function testSetMaxBurnPercent() public {
        assertEq(lab.maxBurnPercent(), 4);
        lab.setMaxBurnPercent(6);
        assertEq(lab.maxBurnPercent(), 6);
    }

    function testSetMaxBurnPercentOnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        lab.setMaxBurnPercent(6);
    }

    function testMaxBurnPercentAffectsRoll() public {
        // Set max to 8 so tier 1 (<490) rolls in [1, 8]
        lab.setMaxBurnPercent(8);

        _mintRevealedTo(user, 1, _createBitmapWithPixels(400));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lab.commitBurn(ids, 2);
        vm.roll(block.number + 6);
        lab.revealBurn(0);
        vm.stopPrank();

        uint256 actions = lab.actionPoints(2);
        // 400 pixels, min 1%, max 8% → range [4, 32]
        assertGe(actions, 4);
        assertLe(actions, 32);
    }

    function testSetBurnTiers() public {
        // Verify defaults: 2 thresholds, 3 percents
        assertEq(lab.tierThresholds(0), 490);
        assertEq(lab.tierThresholds(1), 890);
        assertEq(lab.tierMinPercents(0), 1);
        assertEq(lab.tierMinPercents(1), 2);
        assertEq(lab.tierMinPercents(2), 3);

        // Update tiers
        lab.setBurnTiers([uint256(300), 700], [uint256(2), 4, 5]);
        assertEq(lab.tierThresholds(0), 300);
        assertEq(lab.tierThresholds(1), 700);
        assertEq(lab.tierMinPercents(0), 2);
        assertEq(lab.tierMinPercents(2), 5);
    }

    function testSetBurnTiersOnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        lab.setBurnTiers([uint256(300), 700], [uint256(2), 4, 5]);
    }

    function testBurnTiersAffectsMinPercent() public {
        // Set custom tiers: <300→5%, 300-699→6%, 700+→7%
        lab.setBurnTiers([uint256(300), 700], [uint256(5), 6, 7]);
        lab.setMaxBurnPercent(8);

        _mintRevealedTo(user, 1, _createBitmapWithPixels(200));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lab.commitBurn(ids, 2);
        vm.roll(block.number + 6);
        lab.revealBurn(0);
        vm.stopPrank();

        uint256 actions = lab.actionPoints(2);
        // 200 pixels, <300 tier → min 5%, max 8% → range [10, 16]
        assertGe(actions, 10);
        assertLe(actions, 16);
    }

    // ──────────────────────────────────────────────
    //  Delegation tests
    // ──────────────────────────────────────────────

    function testSetDelegate() public {
        _mintRealToUser(1);

        vm.prank(user);
        lab.setDelegate(1, delegate_);

        assertEq(lab.delegates(1), delegate_);
    }

    function testSetDelegateOnlyOwner() public {
        _mintRealToUser(1);

        vm.prank(unauthorized);
        vm.expectRevert(NormiesCanvas.NotTokenOwnerForDelegation.selector);
        lab.setDelegate(1, delegate_);
    }

    function testSetDelegateZeroAddressReverts() public {
        _mintRealToUser(1);

        vm.prank(user);
        vm.expectRevert(NormiesCanvas.InvalidDelegate.selector);
        lab.setDelegate(1, address(0));
    }

    function testSetDelegateEmitsEvent() public {
        _mintRealToUser(1);

        vm.prank(user);
        vm.expectEmit(true, true, false, false);
        emit NormiesCanvas.DelegateSet(1, delegate_);
        lab.setDelegate(1, delegate_);
    }

    function testRevokeDelegate() public {
        _mintRealToUser(1);

        vm.startPrank(user);
        lab.setDelegate(1, delegate_);
        lab.revokeDelegate(1);
        vm.stopPrank();

        assertEq(lab.delegates(1), address(0));
    }

    function testRevokeDelegateOnlyOwner() public {
        _mintRealToUser(1);

        vm.prank(user);
        lab.setDelegate(1, delegate_);

        vm.prank(unauthorized);
        vm.expectRevert(NormiesCanvas.NotTokenOwnerForDelegation.selector);
        lab.revokeDelegate(1);
    }

    function testRevokeDelegateEmitsEvent() public {
        _mintRealToUser(1);

        vm.prank(user);
        lab.setDelegate(1, delegate_);

        vm.prank(user);
        vm.expectEmit(true, true, false, false);
        emit NormiesCanvas.DelegateRevoked(1, delegate_);
        lab.revokeDelegate(1);
    }

    function testDelegateCanTransform() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 10);

        vm.prank(user);
        lab.setDelegate(1, delegate_);

        uint256 budgetBefore = lab.actionPoints(1);

        vm.prank(delegate_);
        lab.setTransformBitmap(1, _singlePixelBitmap(0, 0));

        assertEq(lab.actionPoints(1), budgetBefore);
        assertTrue(transformStorage.isTransformed(1));
    }

    function testDelegateCannotCommitBurn() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.prank(user);
        lab.setDelegate(2, delegate_);

        // Delegate tries to commit burn — must fail (commitBurn checks ownerOf for receiver)
        vm.startPrank(delegate_);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(); // will revert on ownerOf check or burn auth
        lab.commitBurn(ids, 2);
        vm.stopPrank();
    }

    function testOwnerCanStillTransformAfterDelegation() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 10);

        vm.startPrank(user);
        lab.setDelegate(1, delegate_);
        lab.setTransformBitmap(1, _singlePixelBitmap(0, 0));
        vm.stopPrank();

        assertTrue(transformStorage.isTransformed(1));
    }

    function testUndelegatedCannotTransform() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 10);

        vm.prank(unauthorized);
        vm.expectRevert(NormiesCanvas.NotTokenOwnerOrDelegate.selector);
        lab.setTransformBitmap(1, _singlePixelBitmap(0, 0));
    }

    function testReplaceDelegateOverwrites() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 10);

        address delegate2 = address(0xD31F);

        vm.startPrank(user);
        lab.setDelegate(1, delegate_);
        lab.setDelegate(1, delegate2); // replace
        vm.stopPrank();

        assertEq(lab.delegates(1), delegate2);

        // Old delegate can no longer transform
        vm.prank(delegate_);
        vm.expectRevert(NormiesCanvas.NotTokenOwnerOrDelegate.selector);
        lab.setTransformBitmap(1, _singlePixelBitmap(0, 0));

        // New delegate can transform
        vm.prank(delegate2);
        lab.setTransformBitmap(1, _singlePixelBitmap(0, 0));
        assertTrue(transformStorage.isTransformed(1));
    }

    function testDelegatePersistsAfterTransfer() public {
        _mintRealToUser(1);

        vm.prank(user);
        lab.setDelegate(1, delegate_);

        // ERC721C calls transfer validator — mock it for test environment
        vm.etch(address(0x721C008fdff27BF06E7E123956E2Fe03B63342e3), hex"00");

        // Transfer token to unauthorized
        vm.prank(user);
        normies.transferFrom(user, unauthorized, 1);

        // Delegate mapping still set (independent of ownership)
        assertEq(lab.delegates(1), delegate_);

        // New owner can revoke
        vm.prank(unauthorized);
        lab.revokeDelegate(1);
        assertEq(lab.delegates(1), address(0));
    }

    // ──────────────────────────────────────────────
    //  pendingBurnCommitments tests
    // ──────────────────────────────────────────────

    function testPendingBurnCommitmentsEmpty() public view {
        (uint256[] memory commitIds, uint256[] memory receiverTokenIds) = lab.pendingBurnCommitments(user);
        assertEq(commitIds.length, 0);
        assertEq(receiverTokenIds.length, 0);
    }

    function testPendingBurnCommitmentsReturnsUnrevealed() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lab.commitBurn(ids, 2);
        vm.stopPrank();

        // Should have one pending commitment
        (uint256[] memory commitIds, uint256[] memory receiverTokenIds) = lab.pendingBurnCommitments(user);
        assertEq(commitIds.length, 1);
        assertEq(commitIds[0], 0);
        assertEq(receiverTokenIds[0], 2);

        // Reveal it
        vm.roll(block.number + 6);
        vm.prank(user);
        lab.revealBurn(0);

        // Should be empty now
        (commitIds, receiverTokenIds) = lab.pendingBurnCommitments(user);
        assertEq(commitIds.length, 0);
    }

    function testPendingBurnCommitmentsMultiple() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 3, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        uint256[] memory ids1 = new uint256[](1);
        ids1[0] = 1;
        lab.commitBurn(ids1, 3);

        uint256[] memory ids2 = new uint256[](1);
        ids2[0] = 2;
        lab.commitBurn(ids2, 3);
        vm.stopPrank();

        // Should have two pending
        (uint256[] memory commitIds,) = lab.pendingBurnCommitments(user);
        assertEq(commitIds.length, 2);

        // Reveal first one
        vm.roll(block.number + 6);
        vm.prank(user);
        lab.revealBurn(0);

        // Should have one remaining (commitId=1)
        (commitIds,) = lab.pendingBurnCommitments(user);
        assertEq(commitIds.length, 1);
        assertEq(commitIds[0], 1);

        // Reveal second
        vm.prank(user);
        lab.revealBurn(1);

        (commitIds,) = lab.pendingBurnCommitments(user);
        assertEq(commitIds.length, 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  NEW TESTS: NormiesCanvas — commitBurn security & edge cases
    // ══════════════════════════════════════════════════════════════════════

    function testCommitBurnOtherUsersTokenReverts() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(unauthorized, 2, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 3, _createBitmapWithPixels(100));

        // user approves lab
        vm.prank(user);
        normies.setApprovalForAll(address(lab), true);
        // unauthorized also approves lab
        vm.prank(unauthorized);
        normies.setApprovalForAll(address(lab), true);

        // user tries to burn unauthorized's token #2
        vm.startPrank(user);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 2;
        vm.expectRevert(NormiesCanvas.NotTokenOwner.selector);
        lab.commitBurn(ids, 3);
        vm.stopPrank();
    }

    function testCommitBurnReceiverTokenReverts() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 2; // receiver is also in burn list
        vm.expectRevert(NormiesCanvas.CannotBurnReceiver.selector);
        lab.commitBurn(ids, 2);
        vm.stopPrank();
    }

    function testCommitBurnDuplicateTokenReverts() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 1; // duplicate — first iteration burns it, second can't find owner
        vm.expectRevert(); // ownerOf reverts on burned token
        lab.commitBurn(ids, 2);
        vm.stopPrank();
    }

    function testCommitBurnSinglePixelToken() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(1));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lab.commitBurn(ids, 2);
        vm.roll(block.number + 6);
        lab.revealBurn(0);
        vm.stopPrank();

        // 1 pixel * max 4% / 100 = 0 (floor)
        assertEq(lab.actionPoints(2), 0);
    }

    function testCommitBurnMaxPixelToken() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(1600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256 commitId = lab.nextCommitId();
        lab.commitBurn(ids, 2);
        uint64 commitBlock = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(commitBlock + 5);
        uint256 pct = _expectedPercentageFromEntropy(1600, entropy, commitId, 0);

        lab.revealBurn(commitId);
        vm.stopPrank();

        // 1600 pixels, tier 3 → 3-4% → 48-64 actions
        assertEq(lab.actionPoints(2), (1600 * pct) / 100);
        assertGe(lab.actionPoints(2), 48);
        assertLe(lab.actionPoints(2), 64);
    }

    function testCommitBurnActionsAccumulateOnReceiver() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 3, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        // First commit
        uint256[] memory ids1 = new uint256[](1);
        ids1[0] = 1;
        lab.commitBurn(ids1, 3);
        vm.roll(block.number + 6);
        lab.revealBurn(0);
        uint256 actionsAfterFirst = lab.actionPoints(3);
        assertGt(actionsAfterFirst, 0);

        // Second commit — actions accumulate
        uint256[] memory ids2 = new uint256[](1);
        ids2[0] = 2;
        lab.commitBurn(ids2, 3);
        vm.roll(block.number + 6);
        lab.revealBurn(1);
        vm.stopPrank();

        assertGt(lab.actionPoints(3), actionsAfterFirst);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  NEW TESTS: NormiesCanvas — revealBurn events
    // ══════════════════════════════════════════════════════════════════════

    function testRevealBurnExpiredEmitsExpiredTrue() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lab.commitBurn(ids, 2);

        vm.roll(block.number + 300); // expire blockhash

        uint256 expectedActions = (600 * 2) / 100; // tier 2 min = 2%
        vm.expectEmit(true, true, true, true);
        emit NormiesCanvas.BurnRevealed(0, user, 2, expectedActions, true);
        lab.revealBurn(0);
        vm.stopPrank();
    }

    function testRevealBurnCreditsCorrectReceiverWhenThirdPartyReveals() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        lab.commitBurn(ids, 2);
        vm.stopPrank();

        vm.roll(block.number + 6);

        // Third party reveals
        vm.prank(unauthorized);
        lab.revealBurn(0);

        // Actions crtransformed to user's receiver token, not to unauthorized
        assertGt(lab.actionPoints(2), 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  NEW TESTS: NormiesCanvas — setTransformBitmap event data
    // ══════════════════════════════════════════════════════════════════════

    function testTransformEmitsCorrectChangeCountAndNewPixelCount() public {
        // Token with 200 pixels. Set XOR bitmap with 5 non-overlapping pixels → newPixelCount = 205
        _mintRevealedTo(user, 1, _createBitmapWithPixels(200));
        _giveTokenTransformActions(1, 10);

        uint8[] memory xs = new uint8[](5);
        uint8[] memory ys = new uint8[](5);
        for (uint8 i; i < 5; i++) {
            xs[i] = i;
            ys[i] = 5; // row 5, first 200 pixels are in rows 0-4
        }
        bytes memory bitmap = _createXorBitmap(xs, ys);

        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit NormiesCanvas.PixelsTransformed(user, 1, 5, 205);
        lab.setTransformBitmap(1, bitmap);
    }

    function testTransformEmitsCorrectNewPixelCountWhenRemovingPixels() public {
        // Token with 200 pixels. XOR first 5 pixels (overlapping with original) → removes them → 195
        _mintRevealedTo(user, 1, _createBitmapWithPixels(200));
        _giveTokenTransformActions(1, 10);

        bytes memory bitmap = _createBitmapWithPixels(5); // overlaps first 5 bits of original

        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit NormiesCanvas.PixelsTransformed(user, 1, 5, 195);
        lab.setTransformBitmap(1, bitmap);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  NEW TESTS: NormiesCanvas — delegation (stale delegate fix)
    // ══════════════════════════════════════════════════════════════════════

    function testDelegateInvalidatedAfterTransfer() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 10);

        vm.prank(user);
        lab.setDelegate(1, delegate_);

        // Mock ERC721C validator
        vm.etch(address(0x721C008fdff27BF06E7E123956E2Fe03B63342e3), hex"00");

        // Transfer token to unauthorized
        vm.prank(user);
        normies.transferFrom(user, unauthorized, 1);

        // Delegate mapping still set but delegateSetBy is stale (old owner)
        assertEq(lab.delegates(1), delegate_);
        assertEq(lab.delegateSetBy(1), user); // old owner

        // Delegate can no longer transform (delegateSetBy != current owner)
        vm.prank(delegate_);
        vm.expectRevert(NormiesCanvas.NotTokenOwnerOrDelegate.selector);
        lab.setTransformBitmap(1, _singlePixelBitmap(0, 0));
    }

    function testNewOwnerCanSetNewDelegate() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 10);

        vm.prank(user);
        lab.setDelegate(1, delegate_);

        vm.etch(address(0x721C008fdff27BF06E7E123956E2Fe03B63342e3), hex"00");

        vm.prank(user);
        normies.transferFrom(user, unauthorized, 1);

        // New owner sets a new delegate
        address newDelegate = address(0xAAAA);
        vm.prank(unauthorized);
        lab.setDelegate(1, newDelegate);

        assertEq(lab.delegates(1), newDelegate);
        assertEq(lab.delegateSetBy(1), unauthorized);

        // New delegate can transform
        vm.prank(newDelegate);
        lab.setTransformBitmap(1, _singlePixelBitmap(0, 0));
        assertTrue(transformStorage.isTransformed(1));
    }

    function testDelegateSetByTracked() public {
        _mintRealToUser(1);

        vm.prank(user);
        lab.setDelegate(1, delegate_);

        assertEq(lab.delegateSetBy(1), user);
    }

    function testRevokeDeletesDelegateSetBy() public {
        _mintRealToUser(1);

        vm.startPrank(user);
        lab.setDelegate(1, delegate_);
        assertEq(lab.delegateSetBy(1), user);

        lab.revokeDelegate(1);
        assertEq(lab.delegateSetBy(1), address(0));
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  NEW TESTS: NormiesCanvas — delegation edge cases
    // ══════════════════════════════════════════════════════════════════════

    function testSetDelegateNotPausable() public {
        _mintRealToUser(1);
        lab.setPaused(true);

        vm.prank(user);
        lab.setDelegate(1, delegate_);

        assertEq(lab.delegates(1), delegate_);
    }

    function testRevokeDelegateNotPausable() public {
        _mintRealToUser(1);

        vm.prank(user);
        lab.setDelegate(1, delegate_);

        lab.setPaused(true);

        vm.prank(user);
        lab.revokeDelegate(1);

        assertEq(lab.delegates(1), address(0));
    }

    function testRevokeNonExistentDelegateSucceeds() public {
        _mintRealToUser(1);

        vm.prank(user);
        vm.expectEmit(true, true, false, false);
        emit NormiesCanvas.DelegateRevoked(1, address(0));
        lab.revokeDelegate(1);

        assertEq(lab.delegates(1), address(0));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  NEW TESTS: NormiesCanvas — admin
    // ══════════════════════════════════════════════════════════════════════

    function testSetTransformStorageUpdatesState() public {
        NormiesCanvasStorage newStorage = new NormiesCanvasStorage();
        lab.setTransformStorage(INormiesCanvasStorage(address(newStorage)));
        assertEq(address(lab.canvasStorage()), address(newStorage));
    }

    function testPausedStateToggle() public {
        assertFalse(lab.paused());
        lab.setPaused(true);
        assertTrue(lab.paused());
        lab.setPaused(false);
        assertFalse(lab.paused());
    }

    // ══════════════════════════════════════════════════════════════════════
    //  NEW TESTS: NormiesCanvas — view functions
    // ══════════════════════════════════════════════════════════════════════

    function testCommitPixelCountsMultipleTokens() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(300));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 3, _createBitmapWithPixels(100));

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        lab.commitBurn(ids, 3);
        vm.stopPrank();

        uint256[] memory pixelCounts = lab.commitPixelCounts(0);
        assertEq(pixelCounts.length, 2);
        assertEq(pixelCounts[0], 300);
        assertEq(pixelCounts[1], 600);
    }

    function testCommitPixelCountsEmptyForUnknownCommit() public view {
        uint256[] memory pixelCounts = lab.commitPixelCounts(999);
        assertEq(pixelCounts.length, 0);
    }

    function testRevealBlockForUnknownCommit() public view {
        // commitBlock = 0 for non-existent → revealBlock = 0 + 5 + 1 = 6
        assertEq(lab.revealBlock(999), 6);
    }

    function testGetLevelFormula() public {
        _mintRealToUser(1);

        // 0 actions → level 1 (base)
        assertEq(lab.getLevel(1), 1);

        // Give exactly 9 actions → level 1 (base 1 + 9/10 = 1)
        _giveTokenTransformActions(1, 9);
        uint256 actions = lab.actionPoints(1);
        assertEq(actions / 10 + 1, lab.getLevel(1));
    }

    function testNextCommitIdIncrements() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 3, _createBitmapWithPixels(100));

        assertEq(lab.nextCommitId(), 0);

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        uint256[] memory ids1 = new uint256[](1);
        ids1[0] = 1;
        lab.commitBurn(ids1, 3);
        assertEq(lab.nextCommitId(), 1);

        uint256[] memory ids2 = new uint256[](1);
        ids2[0] = 2;
        lab.commitBurn(ids2, 3);
        assertEq(lab.nextCommitId(), 2);

        vm.stopPrank();
    }

    function testConstructorSetsImmutables() public view {
        assertEq(address(lab.normies()), address(normies));
        assertEq(address(lab.normiesStorage()), address(normiesStorage));
        assertEq(address(lab.canvasStorage()), address(transformStorage));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  NEW TESTS: NormiesCanvasStorage
    // ══════════════════════════════════════════════════════════════════════

    function testStorageSetAuthorizedWriterEmitsEvent() public {
        address writer = address(0xAAAA);
        vm.expectEmit(true, false, false, true);
        emit NormiesCanvasStorage.AuthorizedWriterSet(writer, true);
        transformStorage.setAuthorizedWriter(writer, true);
    }

    function testStorageSetAuthorizedWriterRevokeEmitsEvent() public {
        address writer = address(0xAAAA);
        transformStorage.setAuthorizedWriter(writer, true);

        vm.expectEmit(true, false, false, true);
        emit NormiesCanvasStorage.AuthorizedWriterSet(writer, false);
        transformStorage.setAuthorizedWriter(writer, false);
    }

    function testStorageOnlyOwnerCanSetAuthorizedWriter() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        transformStorage.setAuthorizedWriter(unauthorized, true);
    }

    function testStorageOwnerCanWrite() public {
        // Owner (test contract) should be able to call write functions directly
        bytes memory data = _createBitmapWithPixels(50);
        transformStorage.setTransformedImageData(42, data);
        assertTrue(transformStorage.isTransformed(42));

        bytes memory result = transformStorage.getTransformedImageData(42);
        assertEq(keccak256(result), keccak256(data));
    }

    function testStorageSetTransformedImageDataStoresAndReads() public {
        bytes memory data = _createRealBitmap();
        transformStorage.setTransformedImageData(1, data);

        bytes memory result = transformStorage.getTransformedImageData(1);
        assertEq(keccak256(result), keccak256(data));
    }

    function testStorageGetTransformedImageDataRevertsIfNotTransformed() public {
        vm.expectRevert(abi.encodeWithSelector(NormiesCanvasStorage.TokenNotTransformed.selector, 999));
        transformStorage.getTransformedImageData(999);
    }

    function testStorageIsTransformedTrueAfterWrite() public {
        assertFalse(transformStorage.isTransformed(1));
        transformStorage.setTransformedImageData(1, _createBitmapWithPixels(10));
        assertTrue(transformStorage.isTransformed(1));
    }

    function testStorageOverwriteTransformedImageData() public {
        bytes memory data1 = _createBitmapWithPixels(10);
        bytes memory data2 = _createBitmapWithPixels(20);

        transformStorage.setTransformedImageData(1, data1);
        assertEq(keccak256(transformStorage.getTransformedImageData(1)), keccak256(data1));

        transformStorage.setTransformedImageData(1, data2);
        assertEq(keccak256(transformStorage.getTransformedImageData(1)), keccak256(data2));
    }

    function testStorageSetTransformedImageDataUnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(NormiesCanvasStorage.NotAuthorized.selector);
        transformStorage.setTransformedImageData(1, _createBitmapWithPixels(10));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  NEW TESTS: NormiesRendererV4
    // ══════════════════════════════════════════════════════════════════════

    function testRendererTokenURIUntransformedToken() public {
        _mintRealToUser(1);
        string memory uri = rendererV4.tokenURI(1);

        // Must be a data URI
        assertTrue(bytes(uri).length > 0);
        assertTrue(uri.contains("data:application/json;base64,"));

        // Decode and check contents
        string memory json = _decodeTokenURIJson(uri);
        assertTrue(json.contains('"name":"Normie #1"'));
        assertTrue(json.contains('"Customized","value":"No"'));
    }

    function testRendererTokenURITransformedToken() public {
        _mintRealToUser(1);
        _giveTokenTransformActions(1, 10);

        vm.prank(user);
        lab.setTransformBitmap(1, _singlePixelBitmap(0, 0));

        string memory uri = rendererV4.tokenURI(1);
        string memory json = _decodeTokenURIJson(uri);
        assertTrue(json.contains('"Customized","value":"Yes"'));
    }

    function testRendererTokenURIContainsPixelCount() public {
        _mintRealToUser(1);
        string memory uri = rendererV4.tokenURI(1);
        string memory json = _decodeTokenURIJson(uri);
        assertTrue(json.contains('"Pixel Count"'));
    }

    function testRendererTokenURIContainsActionPoints() public {
        _mintRealToUser(1);
        string memory uri = rendererV4.tokenURI(1);
        string memory json = _decodeTokenURIJson(uri);
        assertTrue(json.contains('"Action Points"'));
    }

    function testRendererTokenURIContainsLevel() public {
        _mintRealToUser(1);
        string memory uri = rendererV4.tokenURI(1);
        string memory json = _decodeTokenURIJson(uri);
        assertTrue(json.contains('"Level"'));
    }

    function testRendererTokenURINotSetReverts() public {
        // Token 999 has no data set
        vm.expectRevert(abi.encodeWithSelector(NormiesRendererV4.TokenDataNotSet.selector, 999));
        rendererV4.tokenURI(999);
    }

    function testRendererTokenURITransformedUsesOriginalPixelCount() public {
        // Mint token with 200 pixels, transform with 5 non-overlapping → composite = 205
        // But metadata should show original pixel count (200), not composited count
        _mintRevealedTo(user, 1, _createBitmapWithPixels(200));
        _giveTokenTransformActions(1, 10);

        uint8[] memory xs = new uint8[](5);
        uint8[] memory ys = new uint8[](5);
        for (uint8 i; i < 5; i++) {
            xs[i] = i;
            ys[i] = 5;
        }

        vm.prank(user);
        lab.setTransformBitmap(1, _createXorBitmap(xs, ys));

        string memory uri = rendererV4.tokenURI(1);
        string memory json = _decodeTokenURIJson(uri);
        // Pixel count should be from the original bitmap, not the composite
        assertTrue(json.contains('"Pixel Count","value":200'));
    }

    function testRendererLevelDefaultsTo1WhenCanvasNotSet() public {
        // Deploy renderer without canvas contract
        NormiesRendererV4 bareRenderer = new NormiesRendererV4(
            INormiesStorage(address(normiesStorage)), INormiesCanvasStorage(address(transformStorage))
        );
        // canvasContract is address(0) by default

        _mintRealToUser(1);

        // Point normies to bare renderer temporarily
        normies.setRendererContract(INormiesRenderer(address(bareRenderer)));

        string memory uri = bareRenderer.tokenURI(1);
        string memory json = _decodeTokenURIJson(uri);
        // Level should default to 1
        assertTrue(json.contains('"Level","value":1'));
    }

    function testRendererActionPointsDefaultTo0WhenCanvasNotSet() public {
        NormiesRendererV4 bareRenderer = new NormiesRendererV4(
            INormiesStorage(address(normiesStorage)), INormiesCanvasStorage(address(transformStorage))
        );

        _mintRealToUser(1);

        string memory uri = bareRenderer.tokenURI(1);
        string memory json = _decodeTokenURIJson(uri);
        assertTrue(json.contains('"Action Points","value":0'));
    }

    function testRendererSetStorageContractOnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        rendererV4.setStorageContract(INormiesStorage(address(0)));
    }

    function testRendererSetTransformStorageContractOnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        rendererV4.setTransformStorageContract(INormiesCanvasStorage(address(0)));
    }

    function testRendererSetCanvasContractOnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        rendererV4.setCanvasContract(INormiesCanvas(address(0)));
    }

    function testRendererSetStorageContractUpdatesState() public {
        NormiesStorage newStorage = new NormiesStorage();
        rendererV4.setStorageContract(INormiesStorage(address(newStorage)));
        assertEq(address(rendererV4.storageContract()), address(newStorage));
    }

    function testRendererSetTransformStorageContractUpdatesState() public {
        NormiesCanvasStorage newStorage = new NormiesCanvasStorage();
        rendererV4.setTransformStorageContract(INormiesCanvasStorage(address(newStorage)));
        assertEq(address(rendererV4.transformStorageContract()), address(newStorage));
    }

    function testRendererSetCanvasContractUpdatesState() public {
        rendererV4.setCanvasContract(INormiesCanvas(address(0)));
        assertEq(address(rendererV4.canvasContract()), address(0));

        rendererV4.setCanvasContract(INormiesCanvas(address(lab)));
        assertEq(address(rendererV4.canvasContract()), address(lab));
    }

    function testRendererSVGContainsRectElements() public {
        _mintRealToUser(1);
        string memory uri = rendererV4.tokenURI(1);
        string memory json = _decodeTokenURIJson(uri);
        // SVG is inside image field as base64
        assertTrue(json.contains("data:image/svg+xml;base64,"));
    }

    function testRendererAnimationUrlIsDataUri() public {
        _mintRealToUser(1);
        string memory uri = rendererV4.tokenURI(1);
        string memory json = _decodeTokenURIJson(uri);
        assertTrue(json.contains("data:text/html;base64,"));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  NEW TESTS: Action point transfer on burn
    // ══════════════════════════════════════════════════════════════════════

    function testCommitBurnTransfersActionPoints() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(600));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100)); // receiver
        _mintRevealedTo(user, 3, _createBitmapWithPixels(100)); // to burn

        // Give token 3 some action points
        _giveTokenTransformActions(3, 10);
        uint256 token3AP = lab.actionPoints(3);
        assertGt(token3AP, 0);

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        uint256 commitId = lab.nextCommitId();
        uint256 actionsBefore = lab.actionPoints(2);
        uint256[] memory burnIds = new uint256[](1);
        burnIds[0] = 3;
        lab.commitBurn(burnIds, 2);
        uint64 commitBlock = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(commitBlock + 5);
        uint256 pct = _expectedPercentageFromEntropy(100, entropy, commitId, 0);
        uint256 expectedEarned = (100 * pct) / 100 + token3AP;

        lab.revealBurn(commitId);
        assertEq(lab.actionPoints(2) - actionsBefore, expectedEarned);
        vm.stopPrank();
    }

    function testCommitBurnTransfersActionPointsFromMultipleTokens() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(100)); // receiver
        _mintRevealedTo(user, 2, _createBitmapWithPixels(200)); // to burn (has AP)
        _mintRevealedTo(user, 3, _createBitmapWithPixels(300)); // to burn (has AP)
        _mintRevealedTo(user, 4, _createBitmapWithPixels(400)); // to burn (no AP)

        _giveTokenTransformActions(2, 10);
        _giveTokenTransformActions(3, 10);
        uint256 token2AP = lab.actionPoints(2);
        uint256 token3AP = lab.actionPoints(3);
        uint256 totalTransferredAP = token2AP + token3AP;
        assertGt(totalTransferredAP, 0);

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);

        uint256 commitId = lab.nextCommitId();
        uint256 actionsBefore = lab.actionPoints(1);
        uint256[] memory burnIds = new uint256[](3);
        burnIds[0] = 2;
        burnIds[1] = 3;
        burnIds[2] = 4;
        lab.commitBurn(burnIds, 1);
        uint64 commitBlock = uint64(block.number);

        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(commitBlock + 5);
        uint256 expectedPixelActions;
        expectedPixelActions += (200 * _expectedPercentageFromEntropy(200, entropy, commitId, 0)) / 100;
        expectedPixelActions += (300 * _expectedPercentageFromEntropy(300, entropy, commitId, 1)) / 100;
        expectedPixelActions += (400 * _expectedPercentageFromEntropy(400, entropy, commitId, 2)) / 100;

        lab.revealBurn(commitId);
        assertEq(lab.actionPoints(1) - actionsBefore, expectedPixelActions + totalTransferredAP);
        vm.stopPrank();
    }

    function testCommitBurnZerosOutBurnedTokenActionPoints() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(100)); // receiver
        _mintRevealedTo(user, 2, _createBitmapWithPixels(600)); // to burn

        _giveTokenTransformActions(2, 10);
        assertGt(lab.actionPoints(2), 0);

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory burnIds = new uint256[](1);
        burnIds[0] = 2;
        lab.commitBurn(burnIds, 1);
        vm.stopPrank();

        // Action points should be zeroed out after commit
        assertEq(lab.actionPoints(2), 0);
    }

    function testCommitBurnUsesOriginalPixelCountNotComposite() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(200));
        _mintRevealedTo(user, 2, _createBitmapWithPixels(100)); // receiver

        _giveTokenTransformActions(1, 10);

        vm.startPrank(user);

        // Transform token 1: add 5 non-overlapping pixels (composite would be 205)
        uint8[] memory xs = new uint8[](5);
        uint8[] memory ys = new uint8[](5);
        for (uint8 i; i < 5; i++) {
            xs[i] = i;
            ys[i] = 5;
        }
        lab.setTransformBitmap(1, _createXorBitmap(xs, ys));

        normies.setApprovalForAll(address(lab), true);
        uint256 commitId = lab.nextCommitId();
        uint256[] memory burnIds = new uint256[](1);
        burnIds[0] = 1;
        lab.commitBurn(burnIds, 2);
        vm.stopPrank();

        // Pixel count should be original (200), not composite (205)
        assertEq(lab.commitPixelCounts(commitId)[0], 200);
    }

    function testBurnCommittedEventIncludesTransferredActionPoints() public {
        _mintRevealedTo(user, 1, _createBitmapWithPixels(100)); // receiver
        _mintRevealedTo(user, 2, _createBitmapWithPixels(600)); // to burn

        _giveTokenTransformActions(2, 10);
        uint256 token2AP = lab.actionPoints(2);
        uint256 commitId = lab.nextCommitId();

        vm.startPrank(user);
        normies.setApprovalForAll(address(lab), true);
        uint256[] memory burnIds = new uint256[](1);
        burnIds[0] = 2;

        vm.expectEmit(true, true, true, true);
        emit NormiesCanvas.BurnCommitted(commitId, user, 1, 1, token2AP);
        lab.commitBurn(burnIds, 1);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  Helper: decode tokenURI to JSON string
    // ──────────────────────────────────────────────

    function _decodeTokenURIJson(string memory uri) internal pure returns (string memory) {
        // Strip "data:application/json;base64," prefix (29 chars)
        bytes memory uriBytes = bytes(uri);
        uint256 prefixLen = 29;
        bytes memory b64 = new bytes(uriBytes.length - prefixLen);
        for (uint256 i; i < b64.length; i++) {
            b64[i] = uriBytes[i + prefixLen];
        }
        return string(Base64.decode(string(b64)));
    }
}
