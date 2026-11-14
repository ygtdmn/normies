// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaFindingsMarketTest } from "./ArenaFindingsMarket.t.sol";

/// @notice Reviewer check: does a Normie round trip move wallet pixels between wallets without a delegate,
///         in the Arena and in the Canvas itself?
contract ArenaVerifyTest is ArenaFindingsMarketTest {
    function test_V_arenaRoundTripWithoutDelegate() public {
        // seller has 500 wallet pixels; buyerWallet holds Normie #1. Buyer lends the Normie to the seller.
        vm.prank(buyerWallet);
        normies.transferFrom(buyerWallet, seller, 1);
        vm.prank(seller);
        queue.deposit(1, 500, false);
        vm.prank(seller);
        normies.transferFrom(seller, buyerWallet, 1);
        vm.prank(buyerWallet);
        store.withdraw(1, 500);
        assertEq(storageV2.balanceOf(buyerWallet), 500);
        assertEq(storageV2.balanceOf(seller), 0);
    }

    function test_V_canvasRoundTrip() public {
        vm.prank(buyerWallet);
        normies.transferFrom(buyerWallet, seller, 1);
        vm.warp(block.timestamp + 3600);
        vm.prank(seller);
        canvas.depositPixels(1, 500);
        vm.prank(seller);
        normies.transferFrom(seller, buyerWallet, 1);
        vm.prank(buyerWallet);
        canvas.withdrawPixels(1, 500, true);
        assertEq(storageV2.balanceOf(buyerWallet), 500);
        assertEq(storageV2.balanceOf(seller), 0);
    }
}
