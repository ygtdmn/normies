// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { NormiesRoyaltySplitter } from "../src/NormiesRoyaltySplitter.sol";
import { NormiesRevenuePool } from "../src/NormiesRevenuePool.sol";
import { IWETH } from "../src/interfaces/IWETH.sol";
import { MockWETH } from "./mocks/MockWETH.sol";

contract RejectsEth {
    receive() external payable {
        revert("no thanks");
    }
}

contract ForceSender {
    constructor() payable { }

    function boom(address payable to) external {
        selfdestruct(to);
    }
}

contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract NormiesRoyaltySplitterTest is Test {
    NormiesRoyaltySplitter splitter;
    NormiesRevenuePool pool;
    MockWETH weth;
    address team = address(0x7EA4);

    function setUp() public {
        weth = new MockWETH();
        pool = new NormiesRevenuePool(IWETH(address(weth)));
        splitter = new NormiesRoyaltySplitter(IWETH(address(weth)), address(pool), team);
    }

    function testSplitsEthInHalfAndTheTeamTakesTheOddWei() public {
        vm.deal(address(this), 1 ether + 1);
        (bool ok,) = address(splitter).call{ value: 1 ether + 1 }("");
        assertTrue(ok);
        vm.prank(address(0xA11)); // anyone
        splitter.release();
        assertEq(address(pool).balance, 0.5 ether);
        assertEq(team.balance, 0.5 ether + 1);
        assertEq(address(splitter).balance, 0);
    }

    function testReceivesA2300GasTransferAndUnwrapsWethOnRelease() public {
        vm.deal(address(this), 3 ether);
        weth.deposit{ value: 2 ether }();
        weth.transfer(address(splitter), 2 ether); // an accepted offer: WETH, no callback
        payable(address(splitter)).transfer(1 ether); // a sale: bare transfer
        splitter.release();
        assertEq(address(pool).balance, 1.5 ether);
        assertEq(team.balance, 1.5 ether);
        assertEq(weth.balanceOf(address(splitter)), 0);
    }

    function testRejectingTeamCannotHoldThePoolShareBack() public {
        RejectsEth hostile = new RejectsEth();
        splitter.setTeam(address(hostile));
        vm.deal(address(splitter), 2 ether);
        splitter.release();
        assertEq(address(pool).balance, 1 ether);
        assertEq(address(hostile).balance, 1 ether); // forced
    }

    function testForcedEthIsSplitLikeAnyOther() public {
        ForceSender sender = new ForceSender{ value: 1 ether }();
        sender.boom(payable(address(splitter)));
        splitter.release();
        assertEq(address(pool).balance, 0.5 ether);
    }

    function testPoolBpsIsConfigurableWithinBounds() public {
        splitter.setPoolBps(7500);
        vm.deal(address(splitter), 4 ether);
        splitter.release();
        assertEq(address(pool).balance, 3 ether);
        assertEq(team.balance, 1 ether);

        vm.expectRevert(NormiesRoyaltySplitter.InvalidBps.selector);
        splitter.setPoolBps(10_001);
        vm.prank(team);
        vm.expectRevert("Ownable: caller is not the owner");
        splitter.setPoolBps(0);
    }

    function testEmptyReleaseIsANoop() public {
        splitter.release();
        assertEq(address(pool).balance, 0);
    }

    function testOtherTokensGoToTheTeamWithTheHoldersShareRecorded() public {
        MockToken usdc = new MockToken();
        usdc.mint(address(splitter), 1000);
        vm.expectEmit(true, false, false, true);
        emit NormiesRoyaltySplitter.TokenReleased(address(usdc), 500, 500);
        splitter.releaseToken(address(usdc));
        assertEq(usdc.balanceOf(team), 1000);

        vm.expectRevert(NormiesRoyaltySplitter.UseRelease.selector);
        splitter.releaseToken(address(weth));
    }

    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(NormiesRoyaltySplitter.ZeroAddress.selector);
        new NormiesRoyaltySplitter(IWETH(address(weth)), address(0), team);
        vm.expectRevert(NormiesRoyaltySplitter.ZeroAddress.selector);
        splitter.setTeam(address(0));
    }
}
