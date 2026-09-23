// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesCanvas } from "../src/NormiesCanvas.sol";
import { NormiesCanvasStorageV2 } from "../src/NormiesCanvasStorageV2.sol";
import { NormiesCanvasV2 } from "../src/NormiesCanvasV2.sol";
import { NormiesRevenuePool } from "../src/NormiesRevenuePool.sol";
import { IWETH } from "../src/interfaces/IWETH.sol";
import { INormiesPixelMarket } from "../src/interfaces/INormiesPixelMarket.sol";
import { NormiesPixelMarket } from "../src/NormiesPixelMarket.sol";
import { NormiesRendererV6 } from "../src/NormiesRendererV6.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";
import { INormiesCanvasStorage } from "../src/interfaces/INormiesCanvasStorage.sol";
import { INormiesCanvasStorageV2 } from "../src/interfaces/INormiesCanvasStorageV2.sol";
import { INormiesCanvasV1 } from "../src/interfaces/INormiesCanvasV1.sol";
import { INormiesZombie } from "../src/interfaces/INormiesZombie.sol";

/// @notice Cutover rehearsal against mainnet state. Skipped when API_KEY_ALCHEMY is not configured.
contract NormiesPixelMarketForkTest is Test {
    address constant NORMIES = 0x9Eb6E2025B64f340691e424b7fe7022fFDE12438;
    address constant STORAGE = 0x1B976bAf51cF51F0e369C070d47FBc47A706e602;
    address constant CANVAS_V1 = 0x64951d92e345C50381267380e2975f66810E869c;
    address constant CANVAS_STORAGE_V1 = 0xC255BE0983776BAB027a156681b6925cde47B2D1;
    address constant ZOMBIE = 0x18533ad55a54c3847Da06A48b51aD7DcB2551202;

    Normies normies = Normies(NORMIES);
    NormiesCanvas canvasV1 = NormiesCanvas(CANVAS_V1);
    NormiesCanvasStorageV2 storageV2;
    NormiesCanvasV2 canvas;
    NormiesPixelMarket market;
    NormiesRendererV6 renderer;
    NormiesRevenuePool revenuePool;
    address treasury;
    uint256 constant FORK_BLOCK = 25_999_628;

    function setUp() public {
        if (bytes(vm.envOr("API_KEY_ALCHEMY", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("mainnet", FORK_BLOCK);

        storageV2 = new NormiesCanvasStorageV2(INormiesCanvasStorage(CANVAS_STORAGE_V1), INormiesCanvasV1(CANVAS_V1));
        canvas = new NormiesCanvasV2(NORMIES, INormiesStorage(STORAGE), INormiesCanvasStorageV2(address(storageV2)));
        market = new NormiesPixelMarket(INormiesCanvasStorageV2(address(storageV2)));
        treasury = makeAddr("fork fee treasury");
        revenuePool = new NormiesRevenuePool(IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
        market.setFeeRecipients(treasury, address(revenuePool));
        renderer = new NormiesRendererV6(INormiesStorage(STORAGE), INormiesCanvasStorageV2(address(storageV2)));

        storageV2.setMoverRoles(address(canvas), storageV2.ROLE_CANVAS());
        storageV2.setMoverRoles(address(market), storageV2.ROLE_MARKET());
        storageV2.setAuthorizedWriter(address(canvas), true);
        canvas.setZombieContract(INormiesZombie(ZOMBIE));
        renderer.setZombieContract(INormiesZombie(ZOMBIE));

        // Cutover steps performed by the respective owners.
        vm.prank(canvasV1.owner());
        canvasV1.setPaused(true);
        // Original balances of the tokens these tests touch are copied in (MigrateLegacy.s.sol does the whole set).
        uint256[] memory ids = new uint256[](300);
        for (uint256 i; i < 300; i++) {
            ids[i] = i;
        }
        storageV2.migrateBatch(ids);
        storageV2.finalizeMigration();
        storageV2.finalizeDelegations();
        canvas.setPaused(false);
        market.setPaused(false);
        vm.prank(normies.owner());
        normies.setRendererContract(INormiesRenderer(address(renderer)));
    }

    /// @dev A missing or burned fixture must fail the rehearsal instead of silently omitting assertions.
    function _liveTokenWithPixels() internal view returns (uint256 tokenId, address holder, uint256 pixels) {
        for (uint256 i = 1; i < 300; i++) {
            uint256 ap = canvasV1.actionPoints(i);
            if (ap == 0) continue;
            try normies.ownerOf(i) returns (address owner) {
                return (i, owner, ap);
            } catch { }
        }
        revert("Fork fixture: no live token with legacy pixels");
    }

    function testFork_LegacyBalancesVisibleAndTokenZeroRenders() public view {
        (uint256 found,, uint256 ap) = _liveTokenWithPixels();
        assertGt(ap, 0);
        assertEq(storageV2.attachedOf(found), ap);
        assertEq(canvas.actionPoints(found), ap);
        assertTrue(storageV2.isTransformed(0) == INormiesCanvasStorage(CANVAS_STORAGE_V1).isTransformed(0));
        assertGt(bytes(normies.tokenURI(0)).length, 1000);
    }

    function testFork_WithdrawWithAckOnRealToken() public {
        (uint256 found, address holder, uint256 ap) = _liveTokenWithPixels();
        assertGt(ap, 0);
        assertLe(ap, type(uint32).max);
        bool transformedBefore = storageV2.isTransformed(found);

        vm.prank(holder);
        canvas.withdrawPixels(found, ap, true);

        assertEq(storageV2.attachedOf(found), 0);
        assertEq(storageV2.balanceOf(holder), ap);
        if (transformedBefore && canvas.lockedPixels(found) == 0) {
            assertFalse(storageV2.isTransformed(found));
        }
        assertGt(bytes(normies.tokenURI(found)).length, 1000);

        // Complete a real fill and verify custody plus both fee destinations.
        vm.prank(holder);
        uint256 id = market.list(uint32(ap), 1 gwei, true, 0);
        assertEq(storageV2.balanceOf(holder), 0);
        assertEq(storageV2.balanceOf(address(market)), ap);
        address taker = makeAddr("fork pixel buyer");
        uint256 gross = ap * 1 gwei;
        uint256 fee = gross * market.feeBps() / 10_000;
        uint256 revenueFee = fee * market.revenueShareBps() / 10_000;
        assertGt(revenueFee, 0);
        assertGt(fee - revenueFee, 0);
        uint256 sellerBefore = holder.balance;
        uint256 treasuryBefore = treasury.balance;
        uint256 poolBefore = address(revenuePool).balance;
        uint256 marketBefore = address(market).balance;
        vm.deal(taker, gross);

        vm.prank(taker);
        market.buy{ value: gross }(id, uint32(ap));

        assertEq(storageV2.balanceOf(taker), ap);
        assertEq(storageV2.balanceOf(address(market)), 0);
        assertEq(market.getListing(id).remaining, 0);
        assertEq(uint8(market.getListing(id).status), uint8(INormiesPixelMarket.Status.Filled));
        assertEq(holder.balance - sellerBefore, gross - fee);
        assertEq(treasury.balance - treasuryBefore, fee - revenueFee);
        assertEq(address(revenuePool).balance - poolBefore, revenueFee);
        assertEq(address(market).balance, marketBefore);
        assertEq(taker.balance, 0);
    }
}
