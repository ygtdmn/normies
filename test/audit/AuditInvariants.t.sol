// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import { Test } from "forge-std/src/Test.sol";
import { PixelMarketBase } from "../PixelMarketBase.t.sol";
import { Normies } from "../../src/Normies.sol";
import { NormiesCanvasV2 } from "../../src/NormiesCanvasV2.sol";
import { NormiesCanvasStorageV2 } from "../../src/NormiesCanvasStorageV2.sol";
import { NormiesPixelMarket } from "../../src/NormiesPixelMarket.sol";
import { NormiesRevenuePool } from "../../src/NormiesRevenuePool.sol";
import { INormiesPixelMarket } from "../../src/interfaces/INormiesPixelMarket.sol";
import { INormiesCanvasV2 } from "../../src/interfaces/INormiesCanvasV2.sol";
import { INormiesCanvasStorageV2 } from "../../src/interfaces/INormiesCanvasStorageV2.sol";
import { INormiesRevenuePool } from "../../src/interfaces/INormiesRevenuePool.sol";
import { IWETH } from "../../src/interfaces/IWETH.sol";
import { MockWETH } from "../mocks/MockWETH.sol";

/// @notice Owns its pool legitimately so generated post/withdraw operations can succeed.
contract AuditRevenueHandler is Test {
    NormiesRevenuePool public pool;
    uint256 public deposited;
    uint256 public paid;
    uint256 public withdrawn;
    uint256 public posts;
    uint256 public claims;
    uint256 public sweeps;
    address public constant ACCOUNT = address(0xA11CE);
    address public constant TREASURY = address(0xFEEE);

    constructor() {
        pool = new NormiesRevenuePool(IWETH(address(new MockWETH())));
    }

    function deposit(uint256 raw) public {
        uint256 amount = bound(raw, 1, 5 ether);
        vm.deal(address(this), address(this).balance + amount);
        (bool ok,) = address(pool).call{ value: amount }("");
        require(ok);
        deposited += amount;
    }

    function post(uint256 raw) public {
        uint256 free = pool.unallocated();
        if (free == 0) return;
        uint256 amount = bound(raw, 1, free);
        uint256 id = pool.nextEpochId();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(id, uint256(0), ACCOUNT, amount))));
        uint64 from = pool.cursorToBlock() + 1;
        uint64 to = from + 10;
        if (block.number <= to) vm.roll(uint256(to) + 1);
        pool.postEpoch(leaf, amount, from, to, bytes32(0), "");
        posts++;
    }

    function claim(uint256 seed) public {
        if (posts == 0) return;
        uint256 id = 1 + seed % posts;
        INormiesRevenuePool.Epoch memory e = pool.getEpoch(id);
        if (e.status != INormiesRevenuePool.Status.Posted || e.claimed != 0) return;
        if (block.timestamp < e.claimableAt) return;
        pool.claim(id, 0, ACCOUNT, e.amount, new bytes32[](0));
        paid += e.amount;
        claims++;
    }

    function sweep(uint256 seed) public {
        if (posts == 0) return;
        uint256 id = 1 + seed % posts;
        INormiesRevenuePool.Epoch memory e = pool.getEpoch(id);
        if (e.status != INormiesRevenuePool.Status.Posted) return;
        if (block.timestamp < e.sweepableAt) return;
        pool.sweep(id);
        sweeps++;
    }

    function advance(uint256 raw) public {
        vm.warp(block.timestamp + bound(raw, 1 hours, 400 days));
    }

    function withdraw(uint256 raw) public {
        uint256 free = pool.unallocated();
        if (free == 0) return;
        uint256 amount = bound(raw, 1, free);
        pool.withdrawUnallocated(TREASURY, amount);
        withdrawn += amount;
    }
}

contract AuditRevenueInvariantTest is Test {
    AuditRevenueHandler handler;
    NormiesRevenuePool pool;

    function setUp() public {
        vm.chainId(1);
        handler = new AuditRevenueHandler();
        pool = handler.pool();
        handler.deposit(5 ether);
        handler.post(1 ether);
        handler.post(1 ether);
        vm.warp(block.timestamp + pool.POST_DELAY()); // claims open after the post delay
        handler.claim(0);
        handler.advance(366 days);
        handler.sweep(1);
        handler.withdraw(1 ether);
        handler.post(1 ether);
        targetContract(address(handler));
    }

    function invariantAudit_ExactReservationsAndCashConservation() public view {
        uint256 reserved;
        for (uint256 id = 1; id < pool.nextEpochId(); id++) {
            INormiesRevenuePool.Epoch memory e = pool.getEpoch(id);
            assertLe(e.claimed, e.amount);
            if (e.status == INormiesRevenuePool.Status.Posted) reserved += uint256(e.amount) - e.claimed;
        }
        assertEq(pool.outstanding(), reserved);
        assertGe(address(pool).balance, reserved);
        assertEq(address(pool).balance + handler.paid() + handler.withdrawn(), handler.deposited());
        // Non-vacuity: real posts, claims, sweeps and withdrawals occurred before random sequences.
        assertGe(handler.posts(), 3);
        assertGe(handler.claims(), 1);
        assertGe(handler.sweeps(), 1);
        assertGe(handler.withdrawn(), 1 ether);
    }
}

contract AuditPixelHandler is Test {
    Normies public nft;
    NormiesCanvasV2 public canvas;
    NormiesCanvasStorageV2 public pixels;
    NormiesPixelMarket public market;
    address[3] public actors = [address(0xA1), address(0xA2), address(0xA3)];
    uint256 public spent;
    uint256 public treasuryFees;
    uint256 public revenueFees;
    uint256 public fills;

    constructor(Normies n, NormiesCanvasV2 c, NormiesCanvasStorageV2 p, NormiesPixelMarket m) {
        nft = n;
        canvas = c;
        pixels = p;
        market = m;
    }

    function withdraw(uint256 t, uint256 raw) public {
        uint256 id = t % 3 + 1;
        uint256 bal = pixels.attachedOf(id);
        if (bal == 0) return;
        vm.prank(nft.ownerOf(id));
        canvas.withdrawPixels(id, bound(raw, 1, bal), true);
    }

    function deposit(uint256 t, uint256 raw) public {
        uint256 id = t % 3 + 1;
        address holder = nft.ownerOf(id);
        uint256 bal = pixels.balanceOf(holder);
        if (bal == 0) return;
        vm.prank(holder);
        canvas.depositPixels(id, bound(raw, 1, bal));
    }

    function transferNft(uint256 t, uint256 a) public {
        uint256 id = t % 3 + 1;
        address holder = nft.ownerOf(id);
        vm.prank(holder);
        nft.transferFrom(holder, actors[a % 3], id);
    }

    function paint(uint256 t, uint256 raw) public {
        uint256 id = t % 3 + 1;
        uint256 size = canvas.gridSize(id);
        uint256 count = bound(raw, 0, pixels.attachedOf(id));
        if (count > size * size) count = size * size;
        bytes memory bitmap = new bytes((size * size + 7) / 8);
        for (uint256 i; i < count; i++) {
            bitmap[i / 8] |= bytes1(uint8(0x80 >> (i % 8)));
        }
        vm.prank(nft.ownerOf(id));
        canvas.setTransformBitmap(id, bitmap);
    }

    function service(uint256 t, bool enlarge, bool wallet) public {
        uint256 id = t % 3 + 1;
        address holder = nft.ownerOf(id);
        uint256 size = canvas.gridSize(id);
        if (enlarge && size == 80) return;
        if (!enlarge && canvas.baseCleared(id)) return;
        uint256 cost = enlarge ? canvas.enlargePrice(size + 10) - canvas.enlargePrice(size) : canvas.blankCanvasPrice();
        uint256 bal = wallet ? pixels.balanceOf(holder) : pixels.attachedOf(id);
        if (bal < cost) return;
        INormiesCanvasV2.PaySource source =
            wallet ? INormiesCanvasV2.PaySource.Wallet : INormiesCanvasV2.PaySource.Attached;
        vm.prank(holder);
        if (enlarge) canvas.enlargeCanvas(id, size + 10, source, true);
        else canvas.clearBase(id, source, true);
        spent += cost;
    }

    function list(uint256 a, uint256 raw, uint256 priceRaw, bool partialFill) public {
        address seller = actors[a % 3];
        uint256 bal = pixels.balanceOf(seller);
        if (bal == 0) return;
        vm.prank(seller);
        market.list(uint32(bound(raw, 1, bal)), uint96(bound(priceRaw, 1, 1 gwei)), partialFill, 0);
    }

    function buy(uint256 seed, uint256 a, uint256 raw) public {
        uint256 count = market.nextListingId() - 1;
        if (count == 0) return;
        uint256 id = 1 + seed % count;
        INormiesPixelMarket.Listing memory l = market.getListing(id);
        if (l.status != INormiesPixelMarket.Status.Active) return;
        uint32 amount = l.partialFill ? uint32(bound(raw, 1, l.remaining)) : l.remaining;
        uint256 gross = uint256(amount) * l.pricePerPixel;
        uint256 fee = gross * 1000 / 10_000;
        revenueFees += fee * 5000 / 10_000;
        treasuryFees += fee - fee * 5000 / 10_000;
        address taker = actors[a % 3];
        vm.deal(taker, taker.balance + gross);
        vm.prank(taker);
        market.buy{ value: gross }(id, amount);
        fills++;
    }

    function cancel(uint256 seed) public {
        uint256 count = market.nextListingId() - 1;
        if (count == 0) return;
        uint256 id = 1 + seed % count;
        INormiesPixelMarket.Listing memory l = market.getListing(id);
        if (l.status != INormiesPixelMarket.Status.Active) return;
        vm.prank(l.seller);
        market.cancel(id);
    }
}

contract AuditPixelInvariantTest is PixelMarketBase {
    AuditPixelHandler handler;

    function setUp() public override {
        super.setUp();
        vm.chainId(1);
        handler = new AuditPixelHandler(normies, canvas, storageV2, market);
        for (uint256 i; i < 3; i++) {
            _mintRealTo(handler.actors(i), i + 1);
            storageV2.creditAttached(i + 1, 1000, INormiesCanvasStorageV2.Reason.Migration);
        }
        storageV2.setMoverRoles(address(this), 0);
        handler.withdraw(0, 500);
        vm.warp(block.timestamp + 5 minutes); // withdrawn pixels cool before they can be listed
        handler.list(0, 250, 1 gwei, true);
        handler.buy(0, 1, 100);
        handler.service(2, false, false);
        targetContract(address(handler));
    }

    function invariantAudit_PixelsEscrowFeesAndOverlayCeilings() public view {
        uint256 attached;
        uint256 wallets = storageV2.balanceOf(address(market));
        for (uint256 i; i < 3; i++) {
            attached += storageV2.attachedOf(i + 1);
            wallets += storageV2.balanceOf(handler.actors(i));
            assertLe(canvas.lockedPixels(i + 1), storageV2.attachedOf(i + 1));
        }
        uint256 escrow;
        for (uint256 id = 1; id < market.nextListingId(); id++) {
            INormiesPixelMarket.Listing memory l = market.getListing(id);
            if (l.status == INormiesPixelMarket.Status.Active) escrow += l.remaining;
            else assertEq(l.remaining, 0);
        }
        assertEq(escrow, storageV2.balanceOf(address(market)));
        assertEq(attached, storageV2.totalAttached());
        assertEq(wallets, storageV2.totalWallet());
        assertEq(attached + wallets + handler.spent(), 3000);
        assertEq(feeTreasury.balance, handler.treasuryFees());
        assertEq(revShare.balance, handler.revenueFees());
        assertEq(address(market).balance, 0);
        assertGe(handler.fills(), 1);
        assertGe(handler.spent(), 200);
    }
}
