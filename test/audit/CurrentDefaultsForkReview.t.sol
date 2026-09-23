// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import { Test } from "forge-std/src/Test.sol";
import { NormiesZombie } from "../../src/NormiesZombie.sol";
import { Normies } from "../../src/Normies.sol";
import { NormiesCanvas } from "../../src/NormiesCanvas.sol";
import { NormiesCanvasV2 } from "../../src/NormiesCanvasV2.sol";
import { NormiesCanvasStorageV2 } from "../../src/NormiesCanvasStorageV2.sol";
import { NormiesPixelMarket } from "../../src/NormiesPixelMarket.sol";
import { NormiesRevenuePool } from "../../src/NormiesRevenuePool.sol";
import { NormiesRoyaltySplitter } from "../../src/NormiesRoyaltySplitter.sol";
import { INormiesCanvasStorage } from "../../src/interfaces/INormiesCanvasStorage.sol";
import { INormiesCanvasStorageV2 } from "../../src/interfaces/INormiesCanvasStorageV2.sol";
import { INormiesCanvasV1 } from "../../src/interfaces/INormiesCanvasV1.sol";
import { INormiesStorage } from "../../src/interfaces/INormiesStorage.sol";
import { IWETH } from "../../src/interfaces/IWETH.sol";

/// @notice Fixed-state integration checks; never broadcasts a transaction.
contract CurrentDefaultsForkReviewTest is Test {
    uint256 constant FORK_BLOCK = 25_999_628;
    Normies constant NFT = Normies(0x9Eb6E2025B64f340691e424b7fe7022fFDE12438);
    NormiesCanvas constant V1 = NormiesCanvas(0x64951d92e345C50381267380e2975f66810E869c);
    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    NormiesCanvasStorageV2 pixels;
    NormiesCanvasV2 canvas;
    NormiesPixelMarket market;
    NormiesRevenuePool pool;
    NormiesRoyaltySplitter splitter;
    address constant TEAM = address(0x7EA4);
    address constant BUYER = address(0xB0B);

    function setUp() public {
        if (bytes(vm.envOr("API_KEY_ALCHEMY", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("mainnet", FORK_BLOCK);
        pool = new NormiesRevenuePool(WETH);
        splitter = new NormiesRoyaltySplitter(WETH, address(pool), TEAM);
        pixels = new NormiesCanvasStorageV2(
            INormiesCanvasStorage(0xC255BE0983776BAB027a156681b6925cde47B2D1), INormiesCanvasV1(address(V1))
        );
        canvas = new NormiesCanvasV2(
            address(NFT),
            INormiesStorage(0x1B976bAf51cF51F0e369C070d47FBc47A706e602),
            INormiesCanvasStorageV2(address(pixels))
        );
        market = new NormiesPixelMarket(INormiesCanvasStorageV2(address(pixels)));

        pixels.setMoverRoles(address(canvas), 1);
        pixels.setMoverRoles(address(market), 2);
        pixels.setAuthorizedWriter(address(canvas), true);
        market.setFeeRecipients(TEAM, address(pool));
        vm.prank(V1.owner());
        V1.setPaused(true);
        uint256[] memory ids = new uint256[](300);
        for (uint256 i; i < 300; i++) {
            ids[i] = i;
        }
        pixels.migrateBatch(ids);
        pixels.finalizeMigration();
        pixels.finalizeDelegations();
        canvas.setPaused(false);
        market.setPaused(false);
    }

    function testAuditFork_RealHolderWithdrawalMarketAndFeeRouting() public {
        uint256 selected = type(uint256).max;
        address holder;
        for (uint256 i = 1; i < 300; i++) {
            if (pixels.attachedOf(i) == 0) continue;
            try NFT.ownerOf(i) returns (address h) {
                selected = i;
                holder = h;
                break;
            } catch { }
        }
        assertTrue(selected != type(uint256).max, "fixture needs a live token with migrated pixels");
        uint256 amount = pixels.attachedOf(selected);
        vm.prank(holder);
        canvas.withdrawPixels(selected, amount, true);
        uint96 price = market.minPricePerPixel();
        assertEq(price, 0.0018 ether);
        assertEq(pixels.availableBalance(holder), 0);
        vm.warp(block.timestamp + pixels.DEFAULT_COOLDOWN());
        vm.prank(holder);
        uint256 id = market.list(uint32(amount), price, true, 0);
        uint256 gross = amount * price;
        uint256 beforeSeller = holder.balance;
        uint256 beforeTeam = TEAM.balance;
        uint256 beforePool = address(pool).balance;
        vm.deal(BUYER, gross);
        vm.prank(BUYER);
        market.buy{ value: gross }(id, uint32(amount));
        uint256 fee = gross / 10;
        assertEq(holder.balance - beforeSeller, gross - fee);
        assertEq(pixels.balanceOf(BUYER), amount);
        assertEq(pixels.availableBalance(BUYER), 0);
        assertEq(pixels.balanceOf(address(market)), 0);
        assertEq(TEAM.balance - beforeTeam, fee - fee / 2);
        assertEq(address(pool).balance - beforePool, fee / 2);
    }

    function testPinnedZombieConfiguration() public {
        NormiesZombie z = NormiesZombie(0x18533ad55a54c3847Da06A48b51aD7DcB2551202);
        emit log_named_address("Existing zombie canvas at pinned block", address(z.canvas()));
        emit log_named_uint("Existing zombie paused at pinned block", z.paused() ? 1 : 0);
        emit log_named_uint("Existing zombie seed locked at pinned block", z.seedLocked() ? 1 : 0);
        assertEq(address(z.canvas()), address(V1));
    }

    function testAuditFork_CanonicalWethSplitAndMerkleClaim() public {
        vm.deal(address(this), 2 ether);
        (bool ok,) = address(WETH).call{ value: 2 ether }(abi.encodeWithSignature("deposit()"));
        assertTrue(ok);
        WETH.transfer(address(splitter), 2 ether);
        uint256 beforeTeam = TEAM.balance;
        uint256 beforePool = address(pool).balance;
        uint256 distributable = address(splitter).balance + WETH.balanceOf(address(splitter));
        splitter.release();
        assertEq(WETH.balanceOf(address(splitter)), 0);
        assertEq(address(pool).balance - beforePool, distributable / 2);
        assertEq(TEAM.balance - beforeTeam, distributable - distributable / 2);
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(uint256(1), uint256(0), BUYER, uint256(1 ether)))));
        pool.postEpoch(leaf, 1 ether, uint64(FORK_BLOCK - 1), uint64(FORK_BLOCK - 1), bytes32(0), "");
        uint256 beforeBuyer = BUYER.balance;
        pool.claim(1, 0, BUYER, 1 ether, new bytes32[](0));
        assertEq(BUYER.balance - beforeBuyer, 1 ether);
        assertEq(pool.outstanding(), 0);
        assertEq(address(pool).balance, beforePool + distributable / 2 - 1 ether);
    }

    function testAuditFork_RealNftRoundTripBypassesPixelMarket() public {
        uint256 selected = type(uint256).max;
        address holder;
        for (uint256 i = 1; i < 300; i++) {
            if (pixels.attachedOf(i) == 0) continue;
            try NFT.ownerOf(i) returns (address h) {
                selected = i;
                holder = h;
                break;
            } catch { }
        }
        assertTrue(selected != type(uint256).max, "fixture needs a live token with migrated pixels");
        uint256 amount = pixels.attachedOf(selected);
        uint256 beforePool = address(pool).balance;
        uint256 beforeTeam = TEAM.balance;
        vm.prank(holder);
        NFT.transferFrom(holder, BUYER, selected);
        vm.startPrank(BUYER);
        canvas.withdrawPixels(selected, amount, true);
        NFT.transferFrom(BUYER, holder, selected);
        vm.stopPrank();
        assertEq(NFT.ownerOf(selected), holder);
        assertEq(pixels.balanceOf(BUYER), amount);
        assertEq(pixels.availableBalance(BUYER), 0);
        assertEq(pixels.attachedOf(selected), 0);
        assertEq(address(pool).balance, beforePool);
        assertEq(TEAM.balance, beforeTeam);
        assertEq(market.nextListingId(), 1);
    }
}
