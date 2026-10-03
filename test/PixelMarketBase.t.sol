// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { MockDelegateRegistryV1, MockDelegateRegistryV2 } from "./mocks/MockDelegateRegistries.sol";
import { Test } from "forge-std/src/Test.sol";
import { Base64 } from "solady/utils/Base64.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesStorage } from "../src/NormiesStorage.sol";
import { NormiesCanvasStorage } from "../src/NormiesCanvasStorage.sol";
import { NormiesCanvas } from "../src/NormiesCanvas.sol";
import { NormiesRendererV5 } from "../src/NormiesRendererV5.sol";
import { NormiesCanvasStorageV2 } from "../src/NormiesCanvasStorageV2.sol";
import { NormiesCanvasV2 } from "../src/NormiesCanvasV2.sol";
import { NormiesPixelMarket } from "../src/NormiesPixelMarket.sol";
import { NormiesRendererV6 } from "../src/NormiesRendererV6.sol";
import { NormiesBitmap } from "../src/NormiesBitmap.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";
import { INormiesCanvasStorage } from "../src/interfaces/INormiesCanvasStorage.sol";
import { INormiesCanvasStorageV2 } from "../src/interfaces/INormiesCanvasStorageV2.sol";
import { INormiesCanvas } from "../src/interfaces/INormiesCanvas.sol";
import { INormiesCanvasV1 } from "../src/interfaces/INormiesCanvasV1.sol";

/// @notice Full V1 + V2 wiring the way mainnet will look after the cutover: V1 paused, renderer V6 live.
abstract contract PixelMarketBase is Test {
    Normies normies;
    NormiesStorage normiesStorage;
    NormiesCanvasStorage storageV1;
    NormiesCanvas canvasV1;
    NormiesRendererV5 rendererV5;

    NormiesCanvasStorageV2 storageV2;
    NormiesCanvasV2 canvas;
    NormiesPixelMarket market;
    NormiesRendererV6 renderer;

    address owner = address(this);
    address user = address(0x1234);
    address buyer = address(0xB0B);
    address unauthorized = address(0xBEEF);
    address delegate_ = address(0xD31E);
    MockDelegateRegistryV2 delegateV2;
    MockDelegateRegistryV1 delegateV1;
    address hotWallet = address(0x4071);
    address feeTreasury = address(0xFEE1);
    address revShare = address(0xFEE2);

    bytes8 constant REAL_TRAITS = bytes8(uint64(0x000101020B00010A));
    bytes32 constant TEST_REVEAL_HASH = keccak256("test-secret");
    address constant TRANSFER_VALIDATOR = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;

    /// @dev Tests that exercise the cutover itself set this false and call _cutover() when ready.
    bool internal cutoverInSetUp = true;

    uint256 internal nextFodderId = 9000;
    uint256 internal nextSpareId = 8000;

    function setUp() public virtual {
        // V1 stack
        normiesStorage = new NormiesStorage();
        storageV1 = new NormiesCanvasStorage();
        rendererV5 =
            new NormiesRendererV5(INormiesStorage(address(normiesStorage)), INormiesCanvasStorage(address(storageV1)));
        normies = new Normies(INormiesRenderer(address(rendererV5)), INormiesStorage(address(normiesStorage)), owner);
        canvasV1 = new NormiesCanvas(
            address(normies), INormiesStorage(address(normiesStorage)), INormiesCanvasStorage(address(storageV1))
        );
        storageV1.setAuthorizedWriter(address(canvasV1), true);
        rendererV5.setCanvasContract(INormiesCanvas(address(canvasV1)));
        normiesStorage.setRevealHash(TEST_REVEAL_HASH);

        // V2 stack
        storageV2 =
            new NormiesCanvasStorageV2(INormiesCanvasStorage(address(storageV1)), INormiesCanvasV1(address(canvasV1)));
        canvas = new NormiesCanvasV2(
            address(normies), INormiesStorage(address(normiesStorage)), INormiesCanvasStorageV2(address(storageV2))
        );
        market = new NormiesPixelMarket(INormiesCanvasStorageV2(address(storageV2)));
        renderer = new NormiesRendererV6(
            INormiesStorage(address(normiesStorage)), INormiesCanvasStorageV2(address(storageV2))
        );

        // delegate.xyz lives at fixed addresses; tests get mocks there.
        vm.etch(address(canvas.DELEGATE_REGISTRY_V2()), address(new MockDelegateRegistryV2()).code);
        vm.etch(address(canvas.DELEGATE_REGISTRY_V1()), address(new MockDelegateRegistryV1()).code);
        delegateV2 = MockDelegateRegistryV2(address(canvas.DELEGATE_REGISTRY_V2()));
        delegateV1 = MockDelegateRegistryV1(address(canvas.DELEGATE_REGISTRY_V1()));

        storageV2.setMoverRoles(address(canvas), storageV2.ROLE_CANVAS());
        storageV2.setMoverRoles(address(market), storageV2.ROLE_MARKET());
        storageV2.setAuthorizedWriter(address(canvas), true);
        market.setFeeRecipients(feeTreasury, revShare);
        market.setMinPricePerPixel(1); // tests trade at tiny prices; the floor has its own test
        normies.setRendererContract(INormiesRenderer(address(renderer)));

        // The test contract acts as the canvas role for direct credits (legacy top-ups after the cutover).
        storageV2.setMoverRoles(address(this), storageV2.ROLE_CANVAS());

        // ERC721C calls a transfer validator on transfers; stub it for the test environment.
        vm.etch(TRANSFER_VALIDATOR, hex"00");

        canvasV1.setPaused(true);
        if (cutoverInSetUp) _cutover();
    }

    /// @notice What the cutover scripts do after V1 is paused: close both copies, then open V2 and the market.
    function _cutover() internal {
        if (!storageV2.delegationsSeeded()) _sealDelegations(new uint256[](0), new address[](0), new address[](0));
        canvas.setPaused(false);
        market.setPaused(false);
    }

    /// @notice The only delegation copy: finalize balances if needed, then copy and seal in one call.
    function _sealDelegations(uint256[] memory ids, address[] memory ds, address[] memory sbs) internal {
        if (!storageV2.migrationFinalized()) storageV2.finalizeMigration();
        storageV2.seedAndFinalizeDelegations(ids, ds, sbs, block.number, block.timestamp);
    }

    // ──────────────────────────────────────────────
    //  Bitmaps
    // ──────────────────────────────────────────────

    function _createRealBitmap() internal pure returns (bytes memory) {
        return hex"00000000000000000000000081800000013500000042d6f0000077fffc000017ffb400003bffd8000057fff60000bfc7ea0001af5af50000fcfebf80005b8db6000177995d0000dff7ba0000dcf13f000077e72b80006fe3270000e7e02b800017e46800001e7e7800001ffff800003ffff400000ffff000000ffff000000ffff000000ffff000000ffff0000007ffe000001ffff000003ffff000008f3ce200000f00c0000007a980800213c388000001e300000001ea000008207e000008103c042004081f0020";
    }

    /// @notice Bitmap with exactly `pixelCount` leading bits set on an n x n grid.
    function _bitmapWithPixels(uint256 pixelCount, uint256 n) internal pure returns (bytes memory bitmap) {
        bitmap = new bytes(NormiesBitmap.bytesForGrid(n));
        uint256 set;
        for (uint256 i; i < bitmap.length && set < pixelCount; i++) {
            uint256 bitsToSet = pixelCount - set;
            if (bitsToSet >= 8) {
                bitmap[i] = bytes1(0xFF);
                set += 8;
            } else {
                bitmap[i] = bytes1(uint8(0xFF << (8 - bitsToSet)));
                set += bitsToSet;
            }
        }
    }

    function _createBitmapWithPixels(uint256 pixelCount) internal pure returns (bytes memory) {
        return _bitmapWithPixels(pixelCount, 40);
    }

    function _setPixel(bytes memory bitmap, uint256 x, uint256 y, uint256 n) internal pure {
        uint256 flat = y * n + x;
        bitmap[flat >> 3] = bytes1(uint8(bitmap[flat >> 3]) | uint8(0x80 >> (flat & 7)));
    }

    function _pixelOn(bytes memory bitmap, uint256 x, uint256 y, uint256 n) internal pure returns (bool) {
        uint256 flat = y * n + x;
        return (uint8(bitmap[flat >> 3]) >> (7 - (flat & 7))) & 1 == 1;
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

    // ──────────────────────────────────────────────
    //  Minting and pixels
    // ──────────────────────────────────────────────

    function _mintRevealedTo(address to, uint256 tokenId, bytes memory bitmap) internal {
        normies.mint(to, tokenId);
        normiesStorage.setTokenRawImageData(tokenId, _xorEncryptImageData(bitmap, TEST_REVEAL_HASH));
        normiesStorage.setTokenTraits(tokenId, REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH));
    }

    function _mintRealTo(address to, uint256 tokenId) internal {
        _mintRevealedTo(to, tokenId, _createRealBitmap());
    }

    /// @notice Gives `targetTokenId` at least `needed` pixels through V2 burns of 1600-pixel fodder (min 64 each).
    function _giveTokenPixels(address holder, uint256 targetTokenId, uint256 needed) internal returns (uint256 got) {
        uint256 tokensNeeded = (needed + 47) / 48;
        if (tokensNeeded == 0) tokensNeeded = 1;
        uint256[] memory ids = new uint256[](tokensNeeded);
        for (uint256 i; i < tokensNeeded; i++) {
            ids[i] = nextFodderId++;
            _mintRevealedTo(holder, ids[i], _createBitmapWithPixels(1600));
        }
        uint256 before = storageV2.attachedOf(targetTokenId);
        vm.startPrank(holder);
        normies.setApprovalForAll(address(canvas), true);
        uint256 commitId = canvas.nextCommitId();
        canvas.commitBurn(ids, targetTokenId);
        vm.roll(block.number + 6);
        canvas.revealBurn(commitId);
        vm.stopPrank();
        got = storageV2.attachedOf(targetTokenId) - before;
    }

    /// @notice Earns `targetTokenId` at least `needed` pixels on the V1 canvas (temporarily unpaused). Nothing is
    ///         copied into storage V2: the caller decides when to migrate.
    function _earnOnV1(address holder, uint256 targetTokenId, uint256 needed) internal returns (uint256 got) {
        _mintRealIfMissing(holder, targetTokenId);
        uint256 tokensNeeded = (needed + 47) / 48;
        if (tokensNeeded == 0) tokensNeeded = 1;
        uint256[] memory ids = new uint256[](tokensNeeded);
        for (uint256 i; i < tokensNeeded; i++) {
            ids[i] = nextFodderId++;
            _mintRevealedTo(holder, ids[i], _createBitmapWithPixels(1600));
        }
        uint256 before = canvasV1.actionPoints(targetTokenId);
        canvasV1.setPaused(false);
        vm.startPrank(holder);
        normies.setApprovalForAll(address(canvasV1), true);
        uint256 commitId = canvasV1.nextCommitId();
        canvasV1.commitBurn(ids, targetTokenId);
        vm.roll(block.number + 6);
        canvasV1.revealBurn(commitId);
        vm.stopPrank();
        canvasV1.setPaused(true);
        got = canvasV1.actionPoints(targetTokenId) - before;
    }

    /// @notice Same as _giveTokenPixels but earned on the V1 canvas and then copied in, as the cutover does.
    ///         Before the cutover a token is copied once (a second call leaves the new pixels on V1 only); after
    ///         it, the copy is closed, so the amount is credited the way the migration would have.
    function _giveTokenPixelsV1(address holder, uint256 targetTokenId, uint256 needed) internal returns (uint256 got) {
        got = _earnOnV1(holder, targetTokenId, needed);
        if (storageV2.migrationFinalized()) {
            storageV2.creditAttached(targetTokenId, got, INormiesCanvasStorageV2.Reason.Migration);
        } else {
            uint256[] memory migrateIds = new uint256[](1);
            migrateIds[0] = targetTokenId;
            storageV2.migrateBatch(migrateIds);
        }
    }

    function _mintRealIfMissing(address to, uint256 tokenId) internal {
        try normies.ownerOf(tokenId) returns (address) { }
        catch {
            _mintRealTo(to, tokenId);
        }
    }

    /// @notice Lets freshly withdrawn or bought pixels through their cooldown.
    function _cool() internal {
        vm.warp(block.timestamp + storageV2.DEFAULT_COOLDOWN());
    }

    /// @notice Puts `amount` pixels into `who`'s wallet balance (mints a spare token, earns, withdraws).
    function _giveWalletPixels(address who, uint256 amount) internal {
        uint256 spare = nextSpareId++;
        _mintRealTo(who, spare);
        uint256 got = _giveTokenPixels(who, spare, amount);
        vm.prank(who);
        canvas.withdrawPixels(spare, got, false);
        _cool();
        uint256 extra = got - amount;
        if (extra > 0) {
            vm.prank(who);
            canvas.depositPixels(spare, extra);
        }
    }

    // ──────────────────────────────────────────────
    //  tokenURI helpers
    // ──────────────────────────────────────────────

    function _decodeTokenURI(string memory uri) internal pure returns (string memory) {
        bytes memory uriBytes = bytes(uri);
        uint256 prefixLen = 29;
        bytes memory b64 = new bytes(uriBytes.length - prefixLen);
        for (uint256 i; i < b64.length; i++) {
            b64[i] = uriBytes[i + prefixLen];
        }
        return string(Base64.decode(string(b64)));
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; i++) {
            bool found = true;
            for (uint256 j; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }

    /// @dev Extracts the base64 SVG out of a decoded metadata JSON and decodes it.
    function _extractSvg(string memory json) internal pure returns (string memory) {
        bytes memory j = bytes(json);
        bytes memory marker = bytes('"image":"data:image/svg+xml;base64,');
        uint256 start;
        for (uint256 i; i <= j.length - marker.length; i++) {
            bool found = true;
            for (uint256 k; k < marker.length; k++) {
                if (j[i + k] != marker[k]) {
                    found = false;
                    break;
                }
            }
            if (found) {
                start = i + marker.length;
                break;
            }
        }
        uint256 end = start;
        while (j[end] != '"') end++;
        bytes memory b64 = new bytes(end - start);
        for (uint256 i; i < b64.length; i++) {
            b64[i] = j[start + i];
        }
        return string(Base64.decode(string(b64)));
    }
}
