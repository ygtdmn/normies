// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { NormiesLegendaryCanvas } from "../src/NormiesLegendaryCanvas.sol";

contract NormiesLegendaryCanvasTest is Test {
    NormiesLegendaryCanvas legendaryCanvas;

    event LegendaryCanvasSet(uint256 indexed tokenId, string artistName, address indexed operator);
    event LegendaryCanvasCleared(uint256 indexed tokenId, address indexed operator);

    function setUp() public {
        legendaryCanvas = new NormiesLegendaryCanvas();
    }

    function testOwnerCanSetAndClearArtist() public {
        vm.expectEmit(true, false, true, true);
        emit LegendaryCanvasSet(42, "Serc", address(this));
        legendaryCanvas.setLegendaryCanvas(42, "Serc");

        assertTrue(legendaryCanvas.hasLegendaryCanvas(42));
        assertEq(legendaryCanvas.legendaryCanvasArtist(42), "Serc");
        assertFalse(legendaryCanvas.hasLegendaryCanvas(43));

        vm.expectEmit(true, false, true, true);
        emit LegendaryCanvasCleared(42, address(this));
        legendaryCanvas.clearLegendaryCanvas(42);

        assertFalse(legendaryCanvas.hasLegendaryCanvas(42));
        vm.expectRevert(NormiesLegendaryCanvas.NoLegendaryCanvas.selector);
        legendaryCanvas.legendaryCanvasArtist(42);
    }

    function testLegendaryCanvasArtistRevertsWhenUnset() public {
        assertFalse(legendaryCanvas.hasLegendaryCanvas(99));
        vm.expectRevert(NormiesLegendaryCanvas.NoLegendaryCanvas.selector);
        legendaryCanvas.legendaryCanvasArtist(99);
    }

    function testAnyArtistNameIsAllowed() public {
        legendaryCanvas.setLegendaryCanvas(2, 'Quote " In Name');
        assertEq(legendaryCanvas.legendaryCanvasArtist(2), 'Quote " In Name');

        legendaryCanvas.setLegendaryCanvas(3, "Slash \\ In Name");
        assertEq(legendaryCanvas.legendaryCanvasArtist(3), "Slash \\ In Name");
    }

    function testLongArtistNamesAreAllowed() public {
        string memory longArtistName =
            "This artist name is intentionally longer than sixty four bytes exactly now and remains valid.";

        legendaryCanvas.setLegendaryCanvas(1, longArtistName);

        assertEq(legendaryCanvas.legendaryCanvasArtist(1), longArtistName);
    }

    function testOnlyOwnerCanManage() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        legendaryCanvas.setLegendaryCanvas(1, "Serc");

        legendaryCanvas.setLegendaryCanvas(1, "Serc");

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        legendaryCanvas.clearLegendaryCanvas(1);
    }
}
