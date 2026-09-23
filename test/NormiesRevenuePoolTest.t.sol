// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { NormiesRevenuePool } from "../src/NormiesRevenuePool.sol";
import { INormiesRevenuePool } from "../src/interfaces/INormiesRevenuePool.sol";
import { IWETH } from "../src/interfaces/IWETH.sol";
import { MockWETH } from "./mocks/MockWETH.sol";
import { MerkleTreeLib } from "solady/utils/MerkleTreeLib.sol";

/// @notice Tries to claim a second time from inside its own payout.
contract ReentrantClaimer {
    NormiesRevenuePool pool;
    bytes32[] proof;
    uint256 epochId;
    uint256 index;
    uint256 amount;
    bool public attempted;

    constructor(NormiesRevenuePool _pool) {
        pool = _pool;
    }

    function arm(uint256 _epochId, uint256 _index, uint256 _amount, bytes32[] memory _proof) external {
        epochId = _epochId;
        index = _index;
        amount = _amount;
        proof = _proof;
    }

    receive() external payable {
        attempted = true;
        pool.claim(epochId, index, address(this), amount, proof);
    }
}

/// @notice Drives deposits, posts, claims, sweeps and owner withdrawals for the solvency invariant.
contract PoolHandler is Test {
    NormiesRevenuePool public pool;
    address[3] public accounts = [address(0xC1), address(0xC2), address(0xC3)];
    address public constant TREASURY = address(0xFEEE);
    uint256 public deposited;
    uint256 public paid;
    uint256 public withdrawn;
    uint256 public posts;
    uint256 public claims;
    uint256 public sweeps;
    uint256 public withdrawals;

    struct Posted {
        uint256 id;
        uint256[3] amounts;
        bytes32[] tree;
    }

    Posted[] internal _posted;

    constructor(NormiesRevenuePool _pool) {
        pool = _pool;
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 5 ether);
        vm.deal(address(this), address(this).balance + amount);
        (bool ok,) = address(pool).call{ value: amount }("");
        require(ok);
        deposited += amount;
    }

    function post(uint256 a, uint256 b, uint256 c) external {
        uint256 free = pool.unallocated();
        if (free < 3) return;
        uint256[3] memory amounts = [bound(a, 1, free / 3), bound(b, 1, free / 3), bound(c, 1, free / 3)];
        uint256 id = pool.nextEpochId();
        bytes32[] memory leaves = new bytes32[](3);
        for (uint256 i; i < 3; i++) {
            leaves[i] = keccak256(bytes.concat(keccak256(abi.encode(id, i, accounts[i], amounts[i]))));
        }
        bytes32[] memory tree = MerkleTreeLib.build(leaves);
        uint64 from = pool.cursorToBlock() + 1;
        uint64 to = from + 10;
        if (block.number <= to) vm.roll(uint256(to) + 1);
        pool.postEpoch(MerkleTreeLib.root(tree), amounts[0] + amounts[1] + amounts[2], from, to, bytes32(0), "");
        _posted.push(Posted({ id: id, amounts: amounts, tree: tree }));
        posts++;
    }

    function setWindow(uint64 seconds_) external {
        pool.setClaimWindow(uint64(bound(seconds_, pool.MIN_CLAIM_WINDOW(), 730 days)));
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 hours, 400 days));
    }

    function claim(uint256 which, uint256 who) external {
        if (_posted.length == 0) return;
        Posted storage p = _posted[which % _posted.length];
        uint256 i = who % 3;
        if (pool.getEpoch(p.id).status != INormiesRevenuePool.Status.Posted || pool.isClaimed(p.id, i)) return;
        pool.claim(p.id, i, accounts[i], p.amounts[i], MerkleTreeLib.leafProof(p.tree, i));
        paid += p.amounts[i];
        claims++;
    }

    function sweep(uint256 which) external {
        if (_posted.length == 0) return;
        uint256 id = _posted[which % _posted.length].id;
        INormiesRevenuePool.Epoch memory e = pool.getEpoch(id);
        if (e.status != INormiesRevenuePool.Status.Posted) return;
        if (block.timestamp < e.sweepableAt) return;
        pool.sweep(id);
        sweeps++;
    }

    function withdraw(uint256 amount) external {
        uint256 free = pool.unallocated();
        if (free == 0) return;
        amount = bound(amount, 1, free);
        pool.withdrawUnallocated(TREASURY, amount);
        withdrawn += amount;
        withdrawals++;
    }
}

contract NormiesRevenuePoolTest is Test {
    NormiesRevenuePool pool;
    MockWETH weth;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    function setUp() public {
        weth = new MockWETH();
        pool = new NormiesRevenuePool(IWETH(address(weth)));
        vm.roll(1000);
        vm.warp(1_800_000_000);
    }

    // ──────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────

    function _leaf(uint256 epochId, uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epochId, index, account, amount))));
    }

    function _tree(uint256 epochId, uint256[3] memory amounts) internal view returns (bytes32[] memory) {
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = _leaf(epochId, 0, alice, amounts[0]);
        leaves[1] = _leaf(epochId, 1, bob, amounts[1]);
        leaves[2] = _leaf(epochId, 2, carol, amounts[2]);
        return MerkleTreeLib.build(leaves);
    }

    function _post(bytes32[] memory tree, uint256 amount, uint64 fromBlock, uint64 toBlock) internal returns (uint256) {
        return pool.postEpoch(MerkleTreeLib.root(tree), amount, fromBlock, toBlock, keccak256("config"), "ipfs://epoch");
    }

    function _fundAndPost() internal returns (uint256 id, bytes32[] memory tree, uint256[3] memory amounts) {
        vm.deal(address(pool), 10 ether);
        amounts = [uint256(1 ether), 2 ether, 3 ether];
        tree = _tree(1, amounts);
        id = _post(tree, 6 ether, 100, 900);
    }

    // ──────────────────────────────────────────────
    //  Posting
    // ──────────────────────────────────────────────

    function testPostReservesImmediately() public {
        (uint256 id,,) = _fundAndPost();
        assertEq(id, 1);
        assertEq(pool.outstanding(), 6 ether);
        assertEq(pool.unallocated(), 4 ether);
        INormiesRevenuePool.Epoch memory e = pool.getEpoch(1);
        assertEq(e.amount, 6 ether);
        assertEq(e.claimableAt, block.timestamp);
        assertEq(e.sweepableAt, block.timestamp + 365 days);
        assertEq(uint8(e.status), uint8(INormiesRevenuePool.Status.Posted));
    }

    function testPostGuards() public {
        vm.deal(address(pool), 1 ether);
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        pool.postEpoch(bytes32(uint256(1)), 1, 1, 2, bytes32(0), "");
        vm.expectRevert(NormiesRevenuePool.InvalidEpoch.selector);
        pool.postEpoch(bytes32(0), 1, 1, 2, bytes32(0), "");
        vm.expectRevert(NormiesRevenuePool.InvalidEpoch.selector);
        pool.postEpoch(bytes32(uint256(1)), 0, 1, 2, bytes32(0), "");
        vm.expectRevert(NormiesRevenuePool.InvalidEpoch.selector);
        pool.postEpoch(bytes32(uint256(1)), 1, 1, uint64(block.number), bytes32(0), "");
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.InsufficientUnallocated.selector, 1 ether, 2 ether));
        pool.postEpoch(bytes32(uint256(1)), 2 ether, 1, 2, bytes32(0), "");
    }

    function testContiguousRanges() public {
        _fundAndPost();
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.BlockRangeNotContiguous.selector, 901, 905));
        pool.postEpoch(bytes32(uint256(1)), 1 ether, 905, 950, bytes32(0), "");
        assertEq(pool.postEpoch(bytes32(uint256(1)), 1 ether, 901, 950, bytes32(0), ""), 2);
    }

    function testPauseBlocksPostingNotClaims() public {
        (uint256 id, bytes32[] memory tree,) = _fundAndPost();
        pool.setPaused(true);
        vm.warp(block.timestamp + 48 hours);
        pool.claim(id, 0, alice, 1 ether, MerkleTreeLib.leafProof(tree, 0));
        assertEq(alice.balance, 1 ether);
        vm.expectRevert(NormiesRevenuePool.Paused.selector);
        pool.postEpoch(bytes32(uint256(1)), 1 ether, 901, 950, bytes32(0), "");
    }

    // ──────────────────────────────────────────────
    //  Claims
    // ──────────────────────────────────────────────

    function testClaimPaysTheAccountWhoeverSubmits() public {
        (uint256 id, bytes32[] memory tree,) = _fundAndPost();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(carol);
        pool.claim(id, 1, bob, 2 ether, MerkleTreeLib.leafProof(tree, 1));
        assertEq(bob.balance, 2 ether);
        assertEq(carol.balance, 0);
        assertTrue(pool.isClaimed(id, 1));
        assertEq(pool.outstanding(), 4 ether);
        assertEq(pool.getEpoch(id).claimed, 2 ether);

        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.AlreadyClaimed.selector, id, 1));
        pool.claim(id, 1, bob, 2 ether, MerkleTreeLib.leafProof(tree, 1));
    }

    function testBadProofsRevert() public {
        (uint256 id, bytes32[] memory tree,) = _fundAndPost();
        vm.warp(block.timestamp + 48 hours);
        bytes32[] memory proof = MerkleTreeLib.leafProof(tree, 0);
        vm.expectRevert(NormiesRevenuePool.InvalidProof.selector);
        pool.claim(id, 0, alice, 2 ether, proof); // wrong amount
        vm.expectRevert(NormiesRevenuePool.InvalidProof.selector);
        pool.claim(id, 0, bob, 1 ether, proof); // wrong account
        vm.expectRevert(NormiesRevenuePool.InvalidProof.selector);
        pool.claim(id, 1, alice, 1 ether, proof); // wrong index
    }

    function testClaimMany() public {
        (uint256 id, bytes32[] memory tree, uint256[3] memory amounts) = _fundAndPost();
        vm.warp(block.timestamp + 48 hours);
        INormiesRevenuePool.Claim[] memory claims = new INormiesRevenuePool.Claim[](2);
        claims[0] = INormiesRevenuePool.Claim(id, 0, alice, amounts[0], MerkleTreeLib.leafProof(tree, 0));
        claims[1] = INormiesRevenuePool.Claim(id, 2, carol, amounts[2], MerkleTreeLib.leafProof(tree, 2));
        pool.claimMany(claims);
        assertEq(alice.balance, 1 ether);
        assertEq(carol.balance, 3 ether);
        assertEq(pool.outstanding(), 2 ether);
    }

    function testRootCanNeverPayMoreThanItsEpochReserved() public {
        // A root whose leaves add up to 6 ETH, posted as a 4 ETH epoch, next to another epoch's 5 ETH.
        vm.deal(address(pool), 9 ether);
        uint256[3] memory amounts = [uint256(1 ether), 2 ether, 3 ether];
        bytes32[] memory tree = _tree(1, amounts);
        uint256 id = _post(tree, 4 ether, 100, 900);
        vm.warp(block.timestamp + 48 hours);
        pool.claim(id, 2, carol, 3 ether, MerkleTreeLib.leafProof(tree, 2));
        pool.claim(id, 0, alice, 1 ether, MerkleTreeLib.leafProof(tree, 0));
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.EpochCapExceeded.selector, id));
        pool.claim(id, 1, bob, 2 ether, MerkleTreeLib.leafProof(tree, 1));
        assertEq(pool.unallocated(), 5 ether);
    }

    function testSingleLeafTreeClaimsWithAnEmptyProof() public {
        vm.deal(address(pool), 1 ether);
        bytes32 leaf = _leaf(1, 0, alice, 1 ether);
        uint256 id = pool.postEpoch(leaf, 1 ether, 100, 900, bytes32(0), "");
        vm.warp(block.timestamp + 48 hours);
        pool.claim(id, 0, alice, 1 ether, new bytes32[](0));
        assertEq(alice.balance, 1 ether);
    }

    function testReentrantClaimerIsPaidOnce() public {
        ReentrantClaimer hostile = new ReentrantClaimer(pool);
        vm.deal(address(pool), 4 ether);
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(1, 0, address(hostile), 1 ether);
        leaves[1] = _leaf(1, 1, bob, 1 ether);
        bytes32[] memory tree = MerkleTreeLib.build(leaves);
        uint256 id = _post(tree, 2 ether, 100, 900);
        vm.warp(block.timestamp + 48 hours);
        hostile.arm(id, 0, 1 ether, MerkleTreeLib.leafProof(tree, 0));
        pool.claim(id, 0, address(hostile), 1 ether, MerkleTreeLib.leafProof(tree, 0));
        // The nested claim reverts inside receive(); the forced transfer still delivers the single payout.
        assertEq(address(hostile).balance, 1 ether);
        assertEq(pool.outstanding(), 1 ether);
    }

    // ──────────────────────────────────────────────
    //  Sweep
    // ──────────────────────────────────────────────

    function testSweepReturnsLeftoversToThePoolOnly() public {
        (uint256 id, bytes32[] memory tree,) = _fundAndPost();
        vm.warp(block.timestamp + 48 hours);
        pool.claim(id, 0, alice, 1 ether, MerkleTreeLib.leafProof(tree, 0));

        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimWindowOpen.selector, id));
        pool.sweep(id);

        vm.warp(block.timestamp + 365 days);
        uint256 balanceBefore = address(pool).balance;
        vm.prank(carol); // anyone
        pool.sweep(id);
        assertEq(address(pool).balance, balanceBefore);
        assertEq(pool.outstanding(), 0);
        assertEq(pool.unallocated(), 9 ether);

        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.NotClaimable.selector, id));
        pool.claim(id, 1, bob, 2 ether, MerkleTreeLib.leafProof(tree, 1));
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.NotClaimable.selector, id));
        pool.sweep(id);
    }

    // ──────────────────────────────────────────────
    //  WETH and admin
    // ──────────────────────────────────────────────

    function testUnwrapWorksOnA2300GasStipend() public {
        vm.deal(address(this), 2 ether);
        weth.deposit{ value: 2 ether }();
        weth.transfer(address(pool), 2 ether);
        assertEq(pool.unallocated(), 0);
        pool.unwrap();
        assertEq(pool.unallocated(), 2 ether);
        assertEq(weth.balanceOf(address(pool)), 0);
    }

    function testOwnerTakesOnlyWhatNoEpochReserved() public {
        vm.expectRevert(NormiesRevenuePool.CannotRescueWeth.selector);
        pool.rescueToken(address(weth), address(this));
        _fundAndPost(); // 10 ether in, 6 reserved
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        pool.withdrawUnallocated(alice, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.InsufficientUnallocated.selector, 4 ether, 5 ether));
        pool.withdrawUnallocated(alice, 5 ether);
        pool.withdrawUnallocated(alice, 4 ether);
        assertEq(alice.balance, 4 ether);
        assertEq(pool.unallocated(), 0);
        assertEq(address(pool).balance, pool.outstanding());
    }

    function testClaimsOpenAtOnceAndWindowChangesAffectOnlyFutureEpochs() public {
        (uint256 id, bytes32[] memory tree,) = _fundAndPost();
        uint256 postedAt = block.timestamp;
        pool.claim(id, 0, alice, 1 ether, MerkleTreeLib.leafProof(tree, 0));
        assertEq(alice.balance, 1 ether);

        pool.setClaimWindow(30 days);
        bytes32[] memory laterTree = _tree(2, [uint256(1 ether), 1 ether, 1 ether]);
        uint256 later = _post(laterTree, 3 ether, 901, 950);
        assertEq(pool.getEpoch(id).sweepableAt, postedAt + 365 days);
        assertEq(pool.getEpoch(later).sweepableAt, postedAt + 30 days);

        vm.warp(postedAt + 30 days - 1);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimWindowOpen.selector, later));
        pool.sweep(later);
        vm.warp(postedAt + 30 days);
        pool.sweep(later);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimWindowOpen.selector, id));
        pool.sweep(id);
        pool.claim(id, 1, bob, 2 ether, MerkleTreeLib.leafProof(tree, 1));
        assertEq(bob.balance, 2 ether);
        assertEq(pool.outstanding(), 3 ether);

        vm.warp(postedAt + 365 days);
        pool.sweep(id);
        assertEq(pool.outstanding(), 0);
    }

    function testIncreasingWindowDoesNotExtendExistingEpoch() public {
        uint64 minimum = pool.MIN_CLAIM_WINDOW();
        pool.setClaimWindow(minimum);
        (uint256 id,,) = _fundAndPost();
        uint256 postedAt = block.timestamp;
        pool.setClaimWindow(730 days);
        uint256 later = pool.postEpoch(bytes32(uint256(1)), 1 ether, 901, 950, bytes32(0), "");
        assertEq(pool.getEpoch(id).sweepableAt, postedAt + minimum);
        assertEq(pool.getEpoch(later).sweepableAt, postedAt + 730 days);

        vm.warp(postedAt + minimum);
        pool.sweep(id);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimWindowOpen.selector, later));
        pool.sweep(later);
        assertEq(pool.outstanding(), 1 ether);
    }

    function testClaimWindowMinimumAndOwnership() public {
        uint64 minimum = pool.MIN_CLAIM_WINDOW();
        assertEq(minimum, 1 days);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimWindowTooShort.selector, 0, minimum));
        pool.setClaimWindow(0);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimWindowTooShort.selector, minimum - 1, minimum));
        pool.setClaimWindow(minimum - 1);
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        pool.setClaimWindow(minimum);
        pool.setClaimWindow(minimum);
        assertEq(pool.claimWindow(), minimum);
    }

    function testPostEmitsFixedDeadline() public {
        vm.deal(address(pool), 1 ether);
        uint64 postedAt = uint64(block.timestamp);
        uint64 deadline = postedAt + pool.claimWindow();
        bytes32 root = _leaf(1, 0, alice, 1 ether);
        vm.expectEmit(true, false, false, true, address(pool));
        emit NormiesRevenuePool.EpochPosted(1, root, 1 ether, 100, 900, postedAt, deadline, bytes32(0), "");
        pool.postEpoch(root, 1 ether, 100, 900, bytes32(0), "");
        assertEq(pool.getEpoch(1).sweepableAt, deadline);
    }

    function testFuzzWindowChangesCannotAlterPostedDeadline(uint64 initial, uint64 updated) public {
        uint64 minimum = pool.MIN_CLAIM_WINDOW();
        initial = uint64(bound(initial, minimum, 3650 days));
        updated = uint64(bound(updated, minimum, 3650 days));
        pool.setClaimWindow(initial);
        (uint256 id,,) = _fundAndPost();
        uint256 deadline = block.timestamp + initial;
        pool.setClaimWindow(updated);
        assertEq(pool.getEpoch(id).sweepableAt, deadline);
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimWindowOpen.selector, id));
        pool.sweep(id);
        vm.warp(deadline);
        pool.sweep(id);
        assertEq(pool.outstanding(), 0);
    }
}

contract NormiesRevenuePoolInvariantTest is Test {
    NormiesRevenuePool pool;
    PoolHandler handler;

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_800_000_000);
        pool = new NormiesRevenuePool(IWETH(address(new MockWETH())));
        handler = new PoolHandler(pool);
        pool.transferOwnership(address(handler));

        // Exercise every operation before fuzzing, leaving both live and swept epochs.
        handler.deposit(5 ether);
        handler.post(1 ether, 1 ether, 1 ether);
        handler.claim(0, 1);
        handler.warp(366 days);
        handler.sweep(0);
        handler.withdraw(1 ether);
        handler.post(1 ether, 1 ether, 1 ether);
        handler.claim(1, 0);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    function invariant_poolReservationsAndCashAreConserved() public view {
        uint256 reserved;
        for (uint256 id = 1; id < pool.nextEpochId(); id++) {
            INormiesRevenuePool.Epoch memory e = pool.getEpoch(id);
            assertLe(e.claimed, e.amount);
            if (e.status == INormiesRevenuePool.Status.Posted) reserved += uint256(e.amount) - e.claimed;
        }
        assertEq(pool.owner(), address(handler));
        assertEq(pool.outstanding(), reserved);
        assertGe(address(pool).balance, reserved);
        assertEq(address(pool).balance + handler.paid() + handler.withdrawn(), handler.deposited());
        assertEq(handler.TREASURY().balance, handler.withdrawn());
        uint256 received;
        for (uint256 i; i < 3; i++) {
            received += handler.accounts(i).balance;
        }
        assertEq(received, handler.paid());
        assertEq(pool.nextEpochId(), handler.posts() + 1);
        assertGe(handler.posts(), 2);
        assertGe(handler.claims(), 2);
        assertGe(handler.sweeps(), 1);
        assertGe(handler.withdrawals(), 1);
    }
}
