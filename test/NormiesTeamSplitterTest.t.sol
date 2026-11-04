// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { NormiesTeamSplitter } from "../src/NormiesTeamSplitter.sol";
import { NormiesRoyaltySplitter } from "../src/NormiesRoyaltySplitter.sol";
import { NormiesRevenuePool } from "../src/NormiesRevenuePool.sol";
import { IWETH } from "../src/interfaces/IWETH.sol";
import { MockWETH } from "./mocks/MockWETH.sol";
import { DeployTeamSplitter } from "../script/DeployTeamSplitter.s.sol";

contract TeamRejectsEth {
    receive() external payable {
        revert("no thanks");
    }
}

contract TeamForceSender {
    constructor() payable { }

    function boom(address payable to) external {
        selfdestruct(to);
    }
}

contract TeamMockToken {
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

contract NormiesTeamSplitterTest is Test {
    NormiesTeamSplitter team;
    MockWETH weth;
    address primary = address(0x9090);
    address secondary = address(0x1010);

    function setUp() public {
        weth = new MockWETH();
        team = new NormiesTeamSplitter(IWETH(address(weth)), primary, secondary, 9000);
    }

    function testSplitsNinetyTenAndTheSecondaryTakesTheOddWei() public {
        vm.deal(address(this), 1 ether + 9);
        (bool ok,) = address(team).call{ value: 1 ether + 9 }("");
        assertTrue(ok);
        vm.prank(address(0xA11)); // anyone
        team.release();
        assertEq(primary.balance, 0.9 ether + 8);
        assertEq(secondary.balance, 0.1 ether + 1);
        assertEq(address(team).balance, 0);
    }

    function testReceivesA2300GasTransfer() public {
        vm.deal(address(this), 1 ether);
        payable(address(team)).transfer(1 ether);
        assertEq(address(team).balance, 1 ether);
    }

    function testARejectingPayeeCannotHoldTheOtherShareBack() public {
        TeamRejectsEth hostile = new TeamRejectsEth();
        NormiesTeamSplitter t = new NormiesTeamSplitter(IWETH(address(weth)), address(hostile), secondary, 9000);
        vm.deal(address(t), 10 ether);
        t.release();
        assertEq(address(hostile).balance, 9 ether); // forced
        assertEq(secondary.balance, 1 ether);

        NormiesTeamSplitter t2 = new NormiesTeamSplitter(IWETH(address(weth)), primary, address(hostile), 9000);
        vm.deal(address(t2), 10 ether);
        t2.release();
        assertEq(primary.balance, 9 ether);
    }

    function testForcedEthIsSplitLikeAnyOther() public {
        TeamForceSender sender = new TeamForceSender{ value: 1 ether }();
        sender.boom(payable(address(team)));
        team.release();
        assertEq(primary.balance, 0.9 ether);
        assertEq(secondary.balance, 0.1 ether);
    }

    function testEmptyReleasesAreNoops() public {
        team.release();
        team.releaseToken(address(new TeamMockToken()));
        assertEq(primary.balance, 0);
    }

    function testDustGoesToTheSecondary() public {
        vm.deal(address(team), 1);
        team.release();
        assertEq(primary.balance, 0);
        assertEq(secondary.balance, 1);
    }

    function testOtherTokensAreSplitTheSameWay() public {
        TeamMockToken usdc = new TeamMockToken();
        usdc.mint(address(team), 1001);
        vm.expectEmit(true, false, false, true);
        emit NormiesTeamSplitter.TokenReleased(address(usdc), 900, 101);
        team.releaseToken(address(usdc));
        assertEq(usdc.balanceOf(primary), 900);
        assertEq(usdc.balanceOf(secondary), 101);

        vm.expectRevert(NormiesTeamSplitter.UseRelease.selector);
        team.releaseToken(address(weth));
    }

    function testReleaseUnwrapsWethAndSplitsItWithTheEth() public {
        vm.deal(address(this), 3 ether);
        weth.deposit{ value: 2 ether }();
        weth.transfer(address(team), 2 ether); // WETH, no callback
        payable(address(team)).transfer(1 ether);
        vm.expectEmit(false, false, false, true, address(team));
        emit NormiesTeamSplitter.Released(2.7 ether, 0.3 ether);
        team.release();
        assertEq(primary.balance, 2.7 ether);
        assertEq(secondary.balance, 0.3 ether);
        assertEq(weth.balanceOf(address(team)), 0);
        assertEq(weth.balanceOf(primary), 0);
        assertEq(address(team).balance, 0);
    }

    function testWethOnlyRelease() public {
        vm.deal(address(this), 1 ether);
        weth.deposit{ value: 1 ether }();
        weth.transfer(address(team), 1 ether);
        team.release();
        assertEq(primary.balance, 0.9 ether);
        assertEq(secondary.balance, 0.1 ether);
    }

    function testConstructorRejectsBadConfig() public {
        IWETH w = IWETH(address(weth));
        vm.expectRevert(NormiesTeamSplitter.ZeroAddress.selector);
        new NormiesTeamSplitter(IWETH(address(0)), primary, secondary, 9000);
        vm.expectRevert(NormiesTeamSplitter.ZeroAddress.selector);
        new NormiesTeamSplitter(w, address(0), secondary, 9000);
        vm.expectRevert(NormiesTeamSplitter.ZeroAddress.selector);
        new NormiesTeamSplitter(w, primary, address(0), 9000);
        vm.expectRevert(NormiesTeamSplitter.SamePayee.selector);
        new NormiesTeamSplitter(w, primary, primary, 9000);
        vm.expectRevert(NormiesTeamSplitter.InvalidBps.selector);
        new NormiesTeamSplitter(w, primary, secondary, 0);
        vm.expectRevert(NormiesTeamSplitter.InvalidBps.selector);
        new NormiesTeamSplitter(w, primary, secondary, 10_000);
    }

    /// The royalty splitter pays the holders' half to the pool and the team half here; then this splits 90/10.
    function testEndToEndBehindTheRoyaltySplitter() public {
        NormiesRevenuePool pool = new NormiesRevenuePool(IWETH(address(weth)));
        NormiesRoyaltySplitter royalties =
            new NormiesRoyaltySplitter(IWETH(address(weth)), address(pool), address(0x7EA4));
        royalties.setTeam(address(team));

        vm.deal(address(this), 4 ether);
        payable(address(royalties)).transfer(2 ether); // a sale
        weth.deposit{ value: 2 ether }();
        weth.transfer(address(royalties), 2 ether); // an accepted offer
        royalties.release();
        assertEq(address(pool).balance, 2 ether);
        assertEq(address(team).balance, 2 ether);

        team.release();
        assertEq(primary.balance, 1.8 ether);
        assertEq(secondary.balance, 0.2 ether);
    }

    function testFuzzSplitAddsUp(uint96 amount, uint16 bps) public {
        bps = uint16(bound(bps, 1, 9999));
        NormiesTeamSplitter t = new NormiesTeamSplitter(IWETH(address(weth)), primary, secondary, bps);
        vm.deal(address(t), amount);
        t.release();
        assertEq(primary.balance + secondary.balance, amount);
        assertEq(primary.balance, (uint256(amount) * bps) / 10_000);
        assertEq(address(t).balance, 0);
    }

    function testDeployScriptUsesTheAgreedPayees() public {
        NormiesTeamSplitter deployed = new DeployTeamSplitter().run();
        assertEq(deployed.primary(), 0x0391AbD7969D494a671F14ed01C85411A596BAEa);
        assertEq(deployed.secondary(), 0x20edb6cfA307495CFD2e10ca400346b0A15baA0A);
        assertEq(deployed.primaryBps(), 9000);
        assertEq(address(deployed.weth()), 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    }
}
