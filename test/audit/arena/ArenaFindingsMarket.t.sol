// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { PixelMarketBase } from "../../PixelMarketBase.t.sol";
import { NormiesArenaStorage } from "../../../src/NormiesArenaStorage.sol";
import { NormiesArenaQueue } from "../../../src/NormiesArenaQueue.sol";
import { NormiesArenaSkins } from "../../../src/NormiesArenaSkins.sol";
import { NormiesArena } from "../../../src/NormiesArena.sol";
import { AuditAdapter } from "./ArenaAuditBase.sol";

/// @notice A desk that sells pixels for ETH with no market: the buyer makes the desk a delegate of one Normie, pays,
///         and the desk tops that Normie up from its own ledger wallet in the same transaction.
contract OtcDesk {
    NormiesArenaQueue public immutable queue;
    address public immutable seller;
    uint256 public immutable weiPerPixel;

    constructor(NormiesArenaQueue queue_, uint256 weiPerPixel_) {
        queue = queue_;
        seller = msg.sender;
        weiPerPixel = weiPerPixel_;
    }

    function buy(uint256 normieId, uint256 amount) external payable {
        require(msg.value == amount * weiPerPixel, "price");
        queue.deposit(normieId, amount, false);
        (bool ok,) = seller.call{ value: msg.value }("");
        require(ok, "pay");
    }
}

/// @notice F-01 on the full Pixel Market stack of this repo: the real ledger, the real Canvas V2, the real market
///         and the real Normies collection. Only the delegate registries and the adapter are stand-ins.
contract ArenaFindingsMarketTest is PixelMarketBase {
    NormiesArenaStorage store;
    NormiesArenaQueue queue;
    NormiesArenaSkins skins;
    NormiesArena arena;
    AuditAdapter adapter;

    address seller = address(0x5E11E2);
    address buyerWallet = address(0xB0BB1E);

    function setUp() public override {
        super.setUp();
        adapter = new AuditAdapter(address(normies));
        store = new NormiesArenaStorage(
            address(storageV2), address(normies), address(adapter), address(delegateV2), address(delegateV1), owner
        );
        arena = new NormiesArena(address(store), owner);
        queue = new NormiesArenaQueue(address(store), owner);
        skins = new NormiesArenaSkins(address(store), owner, feeTreasury);
        store.setAuthorizedWriter(address(arena), true);
        store.setAuthorizedWriter(address(queue), true);
        store.setAuthorizedWriter(address(skins), true);
        storageV2.setMoverRoles(address(store), storageV2.ROLE_WRAPPER());
        storageV2.setMoverRoles(address(queue), storageV2.ROLE_WRAPPER());
        storageV2.setMoverRoles(address(skins), storageV2.ROLE_WRAPPER());
        queue.setPaused(false);
        _mintRealTo(buyerWallet, 1);
        storageV2.mintTo(seller, 500);
    }

    /// @notice Wallet pixels move from one wallet to another through the Arena with no market fill: the receiver
    ///         makes the sender a delegate of one Normie, the sender tops it up, the receiver withdraws. The Canvas
    ///         refuses the same move ("pixels only change hands through the market").
    function test_F01_delegateTopUpMovesPixelsBetweenWalletsWithoutTheMarket() public {
        // The buyer delegates Normie #1 to the seller (token level, delegate.xyz v2).
        delegateV2.delegateERC721(seller, buyerWallet, address(normies), 1, true);

        // Canvas: a delegate cannot put its own pixels on someone else's Normie.
        vm.prank(seller);
        vm.expectRevert();
        canvas.depositPixels(1, 500);

        // Arena: the same delegate tops up Normie #1 from its own wallet ...
        vm.prank(seller);
        queue.deposit(1, 500, false);
        assertEq(storageV2.balanceOf(seller), 0);
        // ... and the holder takes the pixels out to its own wallet.
        vm.prank(buyerWallet);
        store.withdraw(1, 500);
        assertEq(storageV2.balanceOf(buyerWallet), 500, "500 pixels changed wallets");

        // No listing, no fill, no fee: the market's fee recipients received nothing.
        assertEq(feeTreasury.balance, 0);
        assertEq(revShare.balance, 0);
        assertEq(market.nextListingId(), 1, "no listing was ever created");
        // One minute later the pixels are freely usable in the receiver's wallet.
        assertEq(storageV2.availableBalance(buyerWallet), 0);
        vm.warp(block.timestamp + 61);
        assertEq(storageV2.availableBalance(buyerWallet), 500);
    }

    /// @notice The same move made trustless and atomic for ETH: an escrow desk holding pixels sells them at any
    ///         price (here a tenth of the market's listing floor), with no fee to the treasury or the revenue pool.
    function test_F01_trustlessOtcDeskBelowTheMarketFloor() public {
        uint256 floor = market.minPricePerPixel();
        uint256 deskPrice = floor / 10;
        vm.prank(seller);
        OtcDesk desk = new OtcDesk(queue, deskPrice);
        // The desk holds wallet pixels (a contract gets them by buying on the market, by withdrawing from a
        // Normie it holds, or from an Arena withdrawal of a Normie it holds).
        storageV2.mintTo(address(desk), 300);

        // The buyer delegates Normie #1 to the desk and buys 300 pixels in one transaction.
        delegateV2.delegateERC721(address(desk), buyerWallet, address(normies), 1, true);
        vm.deal(buyerWallet, 1 ether);
        vm.prank(buyerWallet);
        desk.buy{ value: 300 * deskPrice }(1, 300);
        assertEq(store.balanceOf(1), 300);
        assertEq(seller.balance, 300 * deskPrice, "the seller got the full price, no 10% fee");
        vm.prank(buyerWallet);
        store.withdraw(1, 300);
        assertEq(storageV2.balanceOf(buyerWallet), 300);

        // What the same trade costs on the market: it cannot be listed below the floor at all, and a fill pays a fee.
        assertEq(market.feeBps(), 1000);
        assertEq(feeTreasury.balance + revShare.balance, 0);
    }
}
