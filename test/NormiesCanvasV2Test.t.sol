// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { PixelMarketBase } from "./PixelMarketBase.t.sol";
import { MockZombie } from "./mocks/MockZombie.sol";
import { NormiesCanvasV2 } from "../src/NormiesCanvasV2.sol";
import { NormiesCanvasStorageV2 } from "../src/NormiesCanvasStorageV2.sol";
import { NormiesBitmap } from "../src/NormiesBitmap.sol";
import { INormiesCanvasV2 } from "../src/interfaces/INormiesCanvasV2.sol";
import { INormiesZombie } from "../src/interfaces/INormiesZombie.sol";

contract NormiesCanvasV2Test is PixelMarketBase {
    INormiesCanvasV2.PaySource constant WALLET = INormiesCanvasV2.PaySource.Wallet;
    INormiesCanvasV2.PaySource constant ATTACHED = INormiesCanvasV2.PaySource.Attached;

    // ──────────────────────────────────────────────
    //  Compatibility views
    // ──────────────────────────────────────────────

    function testActionPointsAndLevelProxyLedger() public {
        _mintRealTo(user, 1);
        uint256 got = _giveTokenPixels(user, 1, 48);
        assertEq(canvas.actionPoints(1), got);
        assertEq(canvas.actionPoints(1), storageV2.attachedOf(1));
        assertEq(canvas.getLevel(1), got / 10 + 1);
        assertEq(canvas.gridSize(1), 40);
        assertFalse(canvas.baseCleared(1));
    }

    function testLegacyBalanceVisibleThroughV2() public {
        _mintRealTo(user, 1);
        uint256 got = _giveTokenPixelsV1(user, 1, 48);
        assertEq(canvas.actionPoints(1), got);
        assertEq(canvas.lockedPixels(1), 0);
    }

    // ──────────────────────────────────────────────
    //  Transform
    // ──────────────────────────────────────────────

    function testTransformRequiresExactLength() public {
        _mintRealTo(user, 1);
        _giveTokenPixels(user, 1, 48);
        vm.prank(user);
        vm.expectRevert(NormiesCanvasV2.InvalidBitmapLength.selector);
        canvas.setTransformBitmap(1, new bytes(199));
    }

    function testTransformRejectsDirtyPadding() public {
        _mintRealTo(user, 1);
        _giveWalletPixels(user, 900);
        vm.prank(user);
        canvas.enlargeCanvas(1, 50, WALLET, false);

        bytes memory bitmap = new bytes(313);
        bitmap[312] = 0x01;
        vm.prank(user);
        vm.expectRevert(NormiesCanvasV2.InvalidBitmapPadding.selector);
        canvas.setTransformBitmap(1, bitmap);
    }

    function testTransformCeiling() public {
        _mintRealTo(user, 1);
        uint256 got = _giveTokenPixels(user, 1, 48);
        vm.startPrank(user);
        vm.expectRevert(NormiesCanvasV2.InsufficientTransformActions.selector);
        canvas.setTransformBitmap(1, _createBitmapWithPixels(got + 1));
        canvas.setTransformBitmap(1, _createBitmapWithPixels(got));
        vm.stopPrank();
        assertTrue(storageV2.isTransformed(1));
        assertEq(canvas.lockedPixels(1), got);
        // The ceiling is never consumed: repainting the same count is fine.
        vm.prank(user);
        canvas.setTransformBitmap(1, _createBitmapWithPixels(got));
        assertEq(storageV2.attachedOf(1), got);
    }

    function testTransformEmitsCompositeCount() public {
        bytes memory art = new bytes(200);
        _setPixel(art, 0, 0, 40);
        _setPixel(art, 1, 0, 40);
        _mintRevealedTo(user, 1, art);
        _giveTokenPixels(user, 1, 48);
        bytes memory overlay = new bytes(200);
        _setPixel(overlay, 0, 0, 40); // erase
        _setPixel(overlay, 5, 5, 40); // add
        vm.expectEmit(true, true, false, true);
        emit NormiesCanvasV2.PixelsTransformed(user, 1, 2, 2);
        vm.prank(user);
        canvas.setTransformBitmap(1, overlay);
    }

    function testLegacyOverlayReadableThroughV2Storage() public {
        _mintRealTo(user, 1);
        uint256 got = _giveTokenPixelsV1(user, 1, 48);
        canvasV1.setPaused(false);
        vm.prank(user);
        canvasV1.setTransformBitmap(1, _createBitmapWithPixels(got));
        canvasV1.setPaused(true);

        assertTrue(storageV2.isTransformed(1));
        assertEq(canvas.lockedPixels(1), got);
        assertFalse(storageV2.isOwnedHere(1));
    }

    // ──────────────────────────────────────────────
    //  Withdraw / deposit
    // ──────────────────────────────────────────────

    function testWithdrawWithinCeilingKeepsOverlay() public {
        _mintRealTo(user, 1);
        uint256 got = _giveTokenPixels(user, 1, 48);
        vm.startPrank(user);
        canvas.setTransformBitmap(1, _createBitmapWithPixels(got - 10));
        canvas.withdrawPixels(1, 10, false);
        _cool();
        vm.stopPrank();
        assertTrue(storageV2.isTransformed(1));
        assertEq(storageV2.attachedOf(1), got - 10);
        assertEq(storageV2.balanceOf(user), 10);
    }

    function testWithdrawBelowCeilingNeedsAcknowledgement() public {
        _mintRealTo(user, 1);
        uint256 got = _giveTokenPixels(user, 1, 48);
        vm.startPrank(user);
        canvas.setTransformBitmap(1, _createBitmapWithPixels(got));

        vm.expectRevert(abi.encodeWithSelector(NormiesCanvasV2.OverlayExceedsBalance.selector, got, got - 1));
        canvas.withdrawPixels(1, 1, false);
        _cool();

        vm.expectEmit(true, false, false, true);
        emit NormiesCanvasV2.OverlayCleared(1, uint8(INormiesCanvasV2.ClearReason.Withdraw));
        canvas.withdrawPixels(1, 1, true);
        _cool();
        vm.stopPrank();

        assertFalse(storageV2.isTransformed(1));
        assertTrue(storageV2.isOwnedHere(1));
        assertEq(canvas.lockedPixels(1), 0);
        assertEq(storageV2.attachedOf(1), got - 1);
        assertEq(storageV2.balanceOf(user), 1);
    }

    function testWithdrawClearsLegacyOverlayToo() public {
        _mintRealTo(user, 1);
        uint256 got = _giveTokenPixelsV1(user, 1, 48);
        canvasV1.setPaused(false);
        vm.prank(user);
        canvasV1.setTransformBitmap(1, _createBitmapWithPixels(got));
        canvasV1.setPaused(true);

        vm.prank(user);
        canvas.withdrawPixels(1, got, true);
        _cool();
        assertFalse(storageV2.isTransformed(1));
        assertTrue(storageV1.isTransformed(1)); // V1 storage is untouched, V2 masks it
        assertEq(storageV2.attachedOf(1), 0);
    }

    function testWithdrawOwnerOnlyAndNonZero() public {
        _mintRealTo(user, 1);
        _giveTokenPixels(user, 1, 48);
        vm.prank(delegate_);
        vm.expectRevert(NormiesCanvasV2.NotTokenOwner.selector);
        canvas.withdrawPixels(1, 1, false);
        _cool();
        vm.prank(user);
        vm.expectRevert(NormiesCanvasV2.ZeroAmount.selector);
        canvas.withdrawPixels(1, 0, false);
        _cool();
    }

    function testDepositOwnerOnly() public {
        _mintRealTo(user, 1);
        _giveWalletPixels(buyer, 30);
        // Depositing onto someone else's Normie would hand pixels over without the market, so it is refused.
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(NormiesCanvasStorageV2.InsufficientAllowance.selector, user, buyer, 0, 30)
        );
        canvas.depositPixels(1, 30);
        assertEq(storageV2.balanceOf(buyer), 30);

        _giveWalletPixels(user, 20);
        vm.prank(user);
        canvas.depositPixels(1, 20);
        assertEq(storageV2.attachedOf(1), 20);
        assertEq(storageV2.balanceOf(user), 0);
        vm.prank(user);
        vm.expectRevert(NormiesCanvasV2.ZeroAmount.selector);
        canvas.depositPixels(1, 0);
    }

    function testDepositOntoNonExistentTokenReverts() public {
        _giveWalletPixels(buyer, 10);
        vm.prank(buyer);
        vm.expectRevert();
        canvas.depositPixels(4242, 10);
    }

    // ──────────────────────────────────────────────
    //  delegate.xyz: a hot wallet manages a Normie, the vault keeps everything
    // ──────────────────────────────────────────────

    function _vaultWithPixels() internal returns (uint256 got) {
        _mintRealTo(user, 1);
        got = _giveTokenPixels(user, 1, 2000);
    }

    function testDelegateXyzV2CanPaintAtEveryLevel() public {
        _vaultWithPixels();
        bytes memory bitmap = new bytes(200);
        bitmap[0] = 0x80;

        vm.prank(hotWallet);
        vm.expectRevert(NormiesCanvasV2.NotTokenOwnerOrDelegate.selector);
        canvas.setTransformBitmap(1, bitmap);

        delegateV2.delegateERC721(hotWallet, user, address(normies), 1, true);
        vm.prank(hotWallet);
        canvas.setTransformBitmap(1, bitmap);

        delegateV2.delegateERC721(hotWallet, user, address(normies), 1, false);
        delegateV2.delegateContract(hotWallet, user, address(normies), true);
        vm.prank(hotWallet);
        canvas.setTransformBitmap(1, bitmap);

        delegateV2.delegateContract(hotWallet, user, address(normies), false);
        delegateV2.delegateAll(hotWallet, user, true);
        vm.prank(hotWallet);
        canvas.setTransformBitmap(1, bitmap);
    }

    function testDelegateXyzV1CanOnlyPaint() public {
        _vaultWithPixels();
        delegateV1.delegateForToken(hotWallet, user, address(normies), 1, true);
        bytes memory bitmap = new bytes(200);
        bitmap[0] = 0x80;
        vm.startPrank(hotWallet);
        canvas.setTransformBitmap(1, bitmap);
        vm.expectRevert(NormiesCanvasV2.NotTokenOwner.selector);
        canvas.withdrawPixels(1, 10, false);
        vm.stopPrank();
    }

    function testDelegateXyzIsTheSameAsACanvasDelegate() public {
        _vaultWithPixels();
        delegateV2.delegateAll(hotWallet, user, true);
        bytes memory bitmap = new bytes(200);
        bitmap[0] = 0x80;
        vm.startPrank(hotWallet);
        canvas.setTransformBitmap(1, bitmap); // painting is the whole of it
        vm.expectRevert(NormiesCanvasV2.NotTokenOwner.selector);
        canvas.withdrawPixels(1, 1, false);
        vm.expectRevert(
            abi.encodeWithSelector(NormiesCanvasStorageV2.InsufficientAllowance.selector, user, hotWallet, 0, 1)
        );
        canvas.depositPixels(1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(NormiesCanvasStorageV2.InsufficientAllowance.selector, user, hotWallet, 0, 900)
        );
        canvas.enlargeCanvas(1, 50, ATTACHED, true);
        vm.expectRevert(
            abi.encodeWithSelector(NormiesCanvasStorageV2.InsufficientAllowance.selector, user, hotWallet, 0, 200)
        );
        canvas.clearBase(1, WALLET, false);
        vm.stopPrank();
        assertEq(canvas.gridSize(1), 40);
        assertFalse(canvas.baseCleared(1));
    }

    function testApprovedWalletSpendsExactlyItsAllowance() public {
        uint256 got = _vaultWithPixels();
        vm.startPrank(user);
        canvas.withdrawPixels(1, 1200, false);
        _cool();
        storageV2.approve(hotWallet, 1200); // no delegation at all, just an allowance
        vm.stopPrank();

        vm.startPrank(hotWallet);
        canvas.depositPixels(1, 100); // 100 from the owner's wallet onto the owner's token
        canvas.clearBase(1, WALLET, false); // 200 from the owner's wallet
        canvas.enlargeCanvas(1, 50, ATTACHED, true); // 900 from the token
        assertEq(storageV2.allowance(user, hotWallet), 0);
        assertEq(canvas.gridSize(1), 50);
        vm.expectRevert(
            abi.encodeWithSelector(NormiesCanvasStorageV2.InsufficientAllowance.selector, user, hotWallet, 0, 1)
        );
        canvas.depositPixels(1, 1);
        vm.expectRevert(NormiesCanvasV2.NotTokenOwner.selector);
        canvas.withdrawPixels(1, 1, false); // an allowance never lets pixels out of the token
        vm.stopPrank();

        assertEq(storageV2.balanceOf(user), 1200 - 100 - 200);
        assertEq(storageV2.balanceOf(hotWallet), 0);
        assertEq(storageV2.attachedOf(1), got - 1200 + 100 - 900);
        assertTrue(canvas.baseCleared(1));

        // A free service (price 0) still needs the owner: an allowance of zero pixels authorises nothing.
        canvas.setBlankCanvasPrice(0);
        _mintRealTo(user, 2);
        vm.prank(hotWallet);
        vm.expectRevert(NormiesCanvasV2.NotTokenOwner.selector);
        canvas.clearBase(2, WALLET, false);
    }

    function testAllowancePauseStopsApprovedSpendsButNotTheOwner() public {
        uint256 got = _vaultWithPixels();
        vm.startPrank(user);
        canvas.withdrawPixels(1, 10, false);
        _cool();
        storageV2.approve(hotWallet, type(uint256).max);
        vm.stopPrank();
        storageV2.setAllowancesPaused(true);

        vm.startPrank(hotWallet);
        vm.expectRevert(NormiesCanvasStorageV2.AllowancesPaused.selector);
        canvas.depositPixels(1, 10);
        vm.expectRevert(NormiesCanvasStorageV2.AllowancesPaused.selector);
        canvas.enlargeCanvas(1, 50, ATTACHED, true);
        vm.expectRevert(NormiesCanvasStorageV2.AllowancesPaused.selector);
        canvas.clearBase(1, WALLET, false);
        vm.stopPrank();

        // The owner is unaffected.
        vm.startPrank(user);
        canvas.depositPixels(1, 10);
        canvas.enlargeCanvas(1, 50, ATTACHED, true);
        vm.stopPrank();
        assertEq(canvas.gridSize(1), 50);
        assertEq(storageV2.attachedOf(1), got - 900);

        storageV2.setAllowancesPaused(false);
        vm.prank(hotWallet);
        canvas.clearBase(1, ATTACHED, true);
        assertTrue(canvas.baseCleared(1));
    }

    function testAllowanceIsPerSpenderAndInfiniteNeverDecreases() public {
        _vaultWithPixels();
        vm.startPrank(user);
        canvas.withdrawPixels(1, 1000, false);
        _cool();
        storageV2.approve(hotWallet, type(uint256).max);
        vm.stopPrank();
        vm.prank(hotWallet);
        canvas.depositPixels(1, 400);
        assertEq(storageV2.allowance(user, hotWallet), type(uint256).max);
        // Another wallet has no allowance of its own, delegated or not.
        delegateV2.delegateAll(delegate_, user, true);
        vm.prank(delegate_);
        vm.expectRevert(
            abi.encodeWithSelector(NormiesCanvasStorageV2.InsufficientAllowance.selector, user, delegate_, 0, 1)
        );
        canvas.depositPixels(1, 1);
        // The owner never needs one.
        vm.prank(user);
        canvas.depositPixels(1, 600);
        assertEq(storageV2.balanceOf(user), 0);
    }

    function testDelegateXyzCannotBurnOrSetNormiesDelegates() public {
        _vaultWithPixels();
        _mintRealTo(user, 2);
        delegateV2.delegateAll(hotWallet, user, true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 2;
        vm.startPrank(hotWallet);
        vm.expectRevert(NormiesCanvasV2.NotTokenOwner.selector);
        canvas.commitBurn(ids, 1);
        vm.expectRevert(NormiesCanvasV2.NotTokenOwner.selector);
        canvas.commitBurnToWallet(ids);
        vm.expectRevert(NormiesCanvasV2.NotTokenOwnerForDelegation.selector);
        canvas.setDelegate(1, hotWallet);
        vm.stopPrank();
    }

    function testNormiesDelegateCanOnlyPaint() public {
        _vaultWithPixels();
        vm.prank(user);
        canvas.setDelegate(1, delegate_);
        bytes memory bitmap = new bytes(200);
        bitmap[0] = 0x80;
        vm.startPrank(delegate_);
        canvas.setTransformBitmap(1, bitmap);
        vm.expectRevert(NormiesCanvasV2.NotTokenOwner.selector);
        canvas.withdrawPixels(1, 1, false);
        _cool();
        vm.expectRevert(
            abi.encodeWithSelector(NormiesCanvasStorageV2.InsufficientAllowance.selector, user, delegate_, 0, 1)
        );
        canvas.depositPixels(1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(NormiesCanvasStorageV2.InsufficientAllowance.selector, user, delegate_, 0, 900)
        );
        canvas.enlargeCanvas(1, 50, ATTACHED, false);
        vm.expectRevert(
            abi.encodeWithSelector(NormiesCanvasStorageV2.InsufficientAllowance.selector, user, delegate_, 0, 200)
        );
        canvas.clearBase(1, ATTACHED, false);
        vm.stopPrank();
    }

    function testDelegateXyzFollowsTheCurrentOwner() public {
        _vaultWithPixels();
        delegateV2.delegateAll(hotWallet, user, true);
        vm.prank(user);
        normies.transferFrom(user, buyer, 1);
        // The delegation was from the previous owner; it means nothing for the new one.
        bytes memory bitmap = new bytes(200);
        bitmap[0] = 0x80;
        vm.prank(hotWallet);
        vm.expectRevert(NormiesCanvasV2.NotTokenOwnerOrDelegate.selector);
        canvas.setTransformBitmap(1, bitmap);
    }

    // ──────────────────────────────────────────────
    //  Enlargement
    // ──────────────────────────────────────────────

    function testEnlargeDeltasBurnPixels() public {
        _mintRealTo(user, 1);
        _giveWalletPixels(user, 4800);
        vm.startPrank(user);

        vm.expectEmit(true, false, false, true);
        emit NormiesCanvasV2.CanvasEnlarged(1, 40, 50, 900, uint8(WALLET));
        canvas.enlargeCanvas(1, 50, WALLET, false);
        assertEq(canvas.gridSize(1), 50);
        assertEq(storageV2.totalWallet(), 4800 - 900); // spent pixels are burned, nobody is credited

        vm.expectRevert(abi.encodeWithSelector(NormiesCanvasV2.GridNotLarger.selector, 50, 50));
        canvas.enlargeCanvas(1, 50, WALLET, false);
        vm.expectRevert(abi.encodeWithSelector(NormiesCanvasV2.InvalidGridSize.selector, 45));
        canvas.enlargeCanvas(1, 45, WALLET, false);

        canvas.enlargeCanvas(1, 80, WALLET, false);
        assertEq(canvas.gridSize(1), 80);
        assertEq(storageV2.totalWallet(), 0);
        assertEq(storageV2.balanceOf(user), 0);

        vm.expectRevert(abi.encodeWithSelector(NormiesCanvasV2.GridNotLarger.selector, 80, 60));
        canvas.enlargeCanvas(1, 60, WALLET, false);
        vm.stopPrank();
    }

    function testEnlargeReembedsOverlay() public {
        _mintRealTo(user, 1);
        uint256 got = _giveTokenPixels(user, 1, 48);
        _giveWalletPixels(user, 2000);
        bytes memory overlay = new bytes(200);
        _setPixel(overlay, 3, 4, 40);
        _setPixel(overlay, 39, 0, 40);
        vm.startPrank(user);
        canvas.setTransformBitmap(1, overlay);
        canvas.enlargeCanvas(1, 60, WALLET, false);
        vm.stopPrank();

        bytes memory stored = storageV2.getTransformedImageData(1);
        assertEq(stored.length, 450);
        assertTrue(_pixelOn(stored, 13, 14, 60));
        assertTrue(_pixelOn(stored, 49, 10, 60));
        assertEq(canvas.lockedPixels(1), 2);
        assertEq(storageV2.attachedOf(1), got);

        // Painting now needs the 60x60 length.
        vm.prank(user);
        vm.expectRevert(NormiesCanvasV2.InvalidBitmapLength.selector);
        canvas.setTransformBitmap(1, overlay);
        vm.prank(user);
        canvas.setTransformBitmap(1, _bitmapWithPixels(got, 60));
    }

    function testEnlargeFromAttachedAppliesCeiling() public {
        _mintRealTo(user, 1);
        uint256 got = _giveTokenPixels(user, 1, 1000);
        assertGe(got, 1000);
        vm.startPrank(user);
        canvas.setTransformBitmap(1, _createBitmapWithPixels(got - 900 + 1));

        vm.expectRevert(
            abi.encodeWithSelector(NormiesCanvasV2.OverlayExceedsBalance.selector, got - 900 + 1, got - 900)
        );
        canvas.enlargeCanvas(1, 50, ATTACHED, false);

        canvas.enlargeCanvas(1, 50, ATTACHED, true);
        vm.stopPrank();
        assertEq(canvas.gridSize(1), 50);
        assertFalse(storageV2.isTransformed(1));
        assertEq(storageV2.attachedOf(1), got - 900);
        assertEq(storageV2.totalAttached(), got - 900);
        assertEq(storageV2.totalWallet(), 0);
    }

    function testEnlargePriceConfigurable() public {
        canvas.setEnlargePrice(50, 10);
        _mintRealTo(user, 1);
        _giveWalletPixels(user, 10);
        vm.prank(user);
        canvas.enlargeCanvas(1, 50, WALLET, false);
        assertEq(storageV2.totalWallet(), 0);
        vm.expectRevert(abi.encodeWithSelector(NormiesCanvasV2.InvalidGridSize.selector, 40));
        canvas.setEnlargePrice(40, 1);
    }

    // ──────────────────────────────────────────────
    //  Blank canvas
    // ──────────────────────────────────────────────

    function testClearBase() public {
        _mintRealTo(user, 1);
        _giveWalletPixels(user, 200);
        vm.prank(user);
        vm.expectEmit(true, false, false, true);
        emit NormiesCanvasV2.BaseCleared(1, 200, uint8(WALLET));
        canvas.clearBase(1, WALLET, false);
        assertTrue(canvas.baseCleared(1));
        assertEq(storageV2.totalWallet(), 0);

        vm.prank(user);
        vm.expectRevert(NormiesCanvasV2.BaseAlreadyCleared.selector);
        canvas.clearBase(1, WALLET, false);

        // Burn rewards still count the original art.
        _mintRealTo(user, 2);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.startPrank(user);
        normies.setApprovalForAll(address(canvas), true);
        uint256 commitId = canvas.nextCommitId();
        canvas.commitBurn(ids, 2);
        vm.stopPrank();
        uint256[] memory counts = canvas.commitPixelCounts(commitId);
        assertEq(counts[0], NormiesBitmap.countPixels(_createRealBitmap(), 40));
    }

    function testClearBaseZombieNotAllowed() public {
        MockZombie zombie = new MockZombie();
        canvas.setZombieContract(INormiesZombie(address(zombie)));
        _mintRealTo(user, 1);
        zombie.setZombie(1, _createBitmapWithPixels(13));
        _giveWalletPixels(user, 200);
        vm.prank(user);
        vm.expectRevert(NormiesCanvasV2.ZombieNotAllowed.selector);
        canvas.clearBase(1, WALLET, false);
    }

    function testClearBasePriceConfigurable() public {
        canvas.setBlankCanvasPrice(0);
        _mintRealTo(user, 1);
        vm.prank(user);
        canvas.clearBase(1, ATTACHED, false);
        assertTrue(canvas.baseCleared(1));
    }

    // ──────────────────────────────────────────────
    //  Burn: commit / reveal
    // ──────────────────────────────────────────────

    function testCommitRevealMatchesV1Formula() public {
        _mintRealTo(user, 1);
        _mintRevealedTo(user, 2, _createBitmapWithPixels(300));
        uint256[] memory ids = new uint256[](1);
        ids[0] = 2;
        vm.startPrank(user);
        normies.setApprovalForAll(address(canvas), true);
        canvas.commitBurn(ids, 1);
        (,, uint64 commitBlock,,,,) = canvas.burnCommitments(0);
        vm.roll(block.number + 6);
        bytes32 entropy = blockhash(uint256(commitBlock) + 5);
        uint256 pct;
        if (entropy == bytes32(0)) {
            pct = 1;
        } else {
            pct = 1 + (uint256(keccak256(abi.encodePacked(entropy, uint256(0), uint256(0)))) % 4);
        }
        canvas.revealBurn(0);
        vm.stopPrank();
        assertEq(storageV2.attachedOf(1), (300 * pct) / 100);
    }

    function testAttachedPixelsMoveAtCommit() public {
        _mintRealTo(user, 1);
        _mintRealTo(user, 2);
        uint256 got = _giveTokenPixels(user, 2, 48);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 2;
        vm.startPrank(user);
        uint256 commitId = canvas.nextCommitId();
        canvas.commitBurn(ids, 1);
        assertEq(storageV2.attachedOf(1), got);
        assertEq(storageV2.attachedOf(2), 0);
        (,,,,,, uint256 transferred) = canvas.burnCommitments(commitId);
        assertEq(transferred, got);
        vm.roll(block.number + 6);
        canvas.revealBurn(commitId);
        vm.stopPrank();
        assertGt(storageV2.attachedOf(1), got);
    }

    function testRewardFallsBackToWalletWhenReceiverBurned() public {
        _mintRealTo(user, 1);
        _mintRealTo(user, 2);
        _mintRevealedTo(user, 3, _createBitmapWithPixels(1600));
        vm.startPrank(user);
        normies.setApprovalForAll(address(canvas), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 3;
        canvas.commitBurn(ids, 1); // commit 0 -> receiver 1
        ids[0] = 1;
        canvas.commitBurn(ids, 2); // burns receiver 1
        vm.roll(block.number + 6);
        canvas.revealBurn(0);
        vm.stopPrank();
        assertGe(storageV2.balanceOf(user), 48);
        assertEq(storageV2.attachedOf(1), 0);
    }

    function testBurnToWalletCreditsWallet() public {
        _mintRealTo(user, 1);
        uint256 carried = _giveTokenPixels(user, 1, 48);
        _mintRevealedTo(user, 2, _createBitmapWithPixels(1600));
        vm.startPrank(user);
        normies.setApprovalForAll(address(canvas), true);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        uint256 commitId = canvas.nextCommitId();
        vm.expectEmit(true, true, true, true);
        emit NormiesCanvasV2.BurnCommitted(commitId, user, 0, 2, carried, true);
        canvas.commitBurnToWallet(ids);
        vm.stopPrank();

        // Carried pixels reach the wallet at commit; the tokens are gone.
        assertEq(storageV2.balanceOf(user), carried);
        assertEq(storageV2.attachedOf(1), 0);
        vm.expectRevert();
        normies.ownerOf(1);
        (uint256[] memory pendingIds,, bool[] memory toWallet) = canvas.pendingBurnCommitments(user);
        assertEq(pendingIds.length, 1);
        assertTrue(toWallet[0]);

        vm.roll(block.number + 6);
        canvas.revealBurn(commitId);
        // Two 1600-pixel Normies pay at least 1% each; nothing is attached anywhere.
        assertGe(storageV2.balanceOf(user), carried + 32);
        assertEq(storageV2.totalAttached(), 0);
        (,,,, bool revealed, bool walletFlag,) = canvas.burnCommitments(commitId);
        assertTrue(revealed);
        assertTrue(walletFlag);
        (pendingIds,,) = canvas.pendingBurnCommitments(user);
        assertEq(pendingIds.length, 0);
    }

    function testBurnToWalletGuards() public {
        _mintRealTo(user, 1);
        uint256[] memory none = new uint256[](0);
        vm.prank(user);
        vm.expectRevert(NormiesCanvasV2.NoTokensProvided.selector);
        canvas.commitBurnToWallet(none);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(buyer);
        vm.expectRevert(NormiesCanvasV2.NotTokenOwner.selector);
        canvas.commitBurnToWallet(ids);

        vm.prank(owner);
        canvas.setPaused(true);
        vm.prank(user);
        vm.expectRevert(NormiesCanvasV2.Paused.selector);
        canvas.commitBurnToWallet(ids);
    }

    function testBurnedIdStateReset() public {
        _mintRealTo(user, 1);
        _mintRealTo(user, 2);
        _giveWalletPixels(user, 1100);
        vm.startPrank(user);
        canvas.enlargeCanvas(1, 50, WALLET, false);
        canvas.clearBase(1, WALLET, false);
        canvas.setDelegate(1, delegate_);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        canvas.commitBurn(ids, 2);
        vm.stopPrank();

        _mintRealTo(buyer, 1);
        assertEq(canvas.gridSize(1), 40);
        assertFalse(canvas.baseCleared(1));
        assertEq(canvas.delegates(1), address(0));
        assertFalse(storageV2.isTransformed(1));
    }

    function testPausedBlocksMutations() public {
        canvas.setPaused(true);
        _mintRealTo(user, 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.startPrank(user);
        vm.expectRevert(NormiesCanvasV2.Paused.selector);
        canvas.commitBurn(ids, 1);
        vm.expectRevert(NormiesCanvasV2.Paused.selector);
        canvas.withdrawPixels(1, 1, false);
        _cool();
        vm.expectRevert(NormiesCanvasV2.Paused.selector);
        canvas.setTransformBitmap(1, new bytes(200));
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  Burn tiers
    // ──────────────────────────────────────────────

    function testBurnTiersAreDynamicAndValidated() public {
        (uint256[] memory t, uint256[] memory m) = canvas.burnTiers();
        assertEq(t.length, 2);
        assertEq(m.length, 3);

        uint256[] memory thresholds = new uint256[](4);
        uint256[] memory mins = new uint256[](5);
        (thresholds[0], thresholds[1], thresholds[2], thresholds[3]) = (200, 400, 800, 1200);
        (mins[0], mins[1], mins[2], mins[3], mins[4]) = (1, 1, 2, 3, 4);
        vm.expectEmit(false, false, false, true);
        emit NormiesCanvasV2.BurnTiersSet(thresholds, mins);
        canvas.setBurnTiers(thresholds, mins);
        assertEq(canvas.tierThresholds(3), 1200);
        assertEq(canvas.tierMinPercents(4), 4);

        // A 1,600-pixel fodder now sits above every threshold and rolls the top minimum, 4 = maxBurnPercent.
        _mintRealTo(user, 1);
        uint256 got = _giveTokenPixels(user, 1, 48);
        assertEq(got, 64);

        // Length, order and cap are all checked.
        uint256[] memory wrongLen = new uint256[](4);
        vm.expectRevert(NormiesCanvasV2.InvalidBurnTiers.selector);
        canvas.setBurnTiers(thresholds, wrongLen);
        (thresholds[1], thresholds[2]) = (800, 400);
        vm.expectRevert(NormiesCanvasV2.InvalidBurnTiers.selector);
        canvas.setBurnTiers(thresholds, mins);
        (thresholds[1], thresholds[2]) = (400, 800);
        mins[4] = 5; // above maxBurnPercent
        vm.expectRevert(NormiesCanvasV2.InvalidBurnTiers.selector);
        canvas.setBurnTiers(thresholds, mins);
        vm.expectRevert(NormiesCanvasV2.InvalidBurnTiers.selector);
        canvas.setMaxBurnPercent(3); // below the current top minimum of 4
        canvas.setMaxBurnPercent(10);
        canvas.setBurnTiers(thresholds, mins);

        // One tier, no thresholds: everything rolls at least mins[0].
        uint256[] memory none = new uint256[](0);
        uint256[] memory flat = new uint256[](1);
        flat[0] = 10;
        canvas.setBurnTiers(none, flat);
        _mintRealTo(user, 2);
        assertEq(_giveTokenPixels(user, 2, 48), 160);
    }

    // ──────────────────────────────────────────────
    //  Delegation
    // ──────────────────────────────────────────────

    function testDelegateStaleAfterTransfer() public {
        _mintRealTo(user, 1);
        uint256 got = _giveTokenPixels(user, 1, 48);
        vm.prank(user);
        canvas.setDelegate(1, delegate_);
        vm.prank(user);
        normies.transferFrom(user, buyer, 1);
        vm.prank(delegate_);
        vm.expectRevert(NormiesCanvasV2.NotTokenOwnerOrDelegate.selector);
        canvas.setTransformBitmap(1, _createBitmapWithPixels(got));
    }

    function testDelegateCannotMovePixels() public {
        _mintRealTo(user, 1);
        _giveTokenPixels(user, 1, 48);
        vm.prank(user);
        canvas.setDelegate(1, delegate_);
        vm.startPrank(delegate_);
        vm.expectRevert(NormiesCanvasV2.NotTokenOwner.selector);
        canvas.withdrawPixels(1, 1, false);
        _cool();
        vm.expectRevert(
            abi.encodeWithSelector(NormiesCanvasStorageV2.InsufficientAllowance.selector, user, delegate_, 0, 200)
        );
        canvas.clearBase(1, ATTACHED, false);
        vm.stopPrank();
    }
}
