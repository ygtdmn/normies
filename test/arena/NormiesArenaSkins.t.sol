// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaTestBase } from "./ArenaTestBase.sol";
import { NormiesArenaSkins } from "../../src/NormiesArenaSkins.sol";
import { ArenaAccess } from "../../src/arena/ArenaAccess.sol";
import { Ownable } from "solady/auth/Ownable.sol";

/// @notice Skin purchases: gifts, allowance-paid purchases, and never from an Arena balance.
contract NormiesArenaSkinsTest is ArenaTestBase {
    function testHolderBuysFromItsWallet() public {
        join(1, alice, 10);
        vm.prank(alice);
        skins.purchase(1, 5, alice);
        assertEq(ledger.balanceOf(treasury), 5);
        assertEq(ledger.balanceOf(alice), 99_985);
        assertEq(store.balanceOf(1), 10);
        assertEq(store.purchased(1), 1);
        assertEq(store.purchaseCount(), 1);
    }

    function testAnyoneCanGiftASkin() public {
        give(1, alice);
        vm.prank(bob);
        skins.purchase(1, 5, bob);
        assertEq(ledger.balanceOf(bob), 99_995);
        assertEq(store.purchased(1), 1);
    }

    function testPaidFromAWalletThatGaveAnAllowance() public {
        give(1, alice);
        vm.prank(bob);
        vm.expectRevert("allowance");
        skins.purchase(1, 5, carol);
        vm.prank(carol);
        ledger.approve(bob, 7);
        vm.prank(bob);
        skins.purchase(1, 5, carol);
        assertEq(ledger.balanceOf(carol), 99_995);
        assertEq(ledger.balanceOf(bob), 100_000);
        assertEq(ledger.allowance(carol, bob), 2);
        vm.prank(bob);
        vm.expectRevert("allowance");
        skins.purchase(1, 5, carol);
    }

    function testRejectsBurnedOutOfRangeAndZeroPayer() public {
        give(1, alice);
        vm.startPrank(alice);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        skins.purchase(10_000, 5, alice);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        skins.purchase(1, 5, address(0));
        vm.stopPrank();
        identity.burn(1);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        skins.purchase(1, 5, alice);
    }

    function testPriceChangeAndPause() public {
        give(1, alice);
        skins.setPrice(9);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NormiesArenaSkins.PriceChanged.selector, 5, 9));
        skins.purchase(1, 5, alice);
        skins.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.Paused.selector);
        skins.purchase(1, 9, alice);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        skins.setPrice(10_001);
    }

    function testTreasuryIsOwnerSet() public {
        give(1, alice);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        skins.setTreasury(alice);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        skins.setTreasury(address(0));
        skins.setTreasury(carol);
        vm.prank(alice);
        skins.purchase(1, 5, alice);
        assertEq(ledger.balanceOf(carol), 100_005);
        assertEq(ledger.balanceOf(treasury), 0);
    }
}
