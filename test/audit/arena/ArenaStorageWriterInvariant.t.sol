// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { ArenaAuditBase } from "./ArenaAuditBase.sol";
import { Normies } from "../../../src/Normies.sol";
import { NormiesCanvasStorageV2 } from "../../../src/NormiesCanvasStorageV2.sol";
import { NormiesArenaStorage } from "../../../src/NormiesArenaStorage.sol";

/// @notice An authorized writer that calls the storage's setters with arbitrary arguments and in any order, as a
///         buggy or hostile logic contract could. Holders withdraw and the owner rescues and sweeps in between.
contract RawWriterHandler is Test {
    NormiesArenaStorage public store;
    NormiesCanvasStorageV2 public ledger;
    Normies public normies;
    address public admin;
    uint256 public constant IDS = 6;
    uint256 public constant ROUNDS = 6;
    uint256 public ok;

    constructor(NormiesArenaStorage store_, NormiesCanvasStorageV2 ledger_, Normies normies_, address admin_) {
        store = store_;
        ledger = ledger_;
        normies = normies_;
        admin = admin_;
    }

    function _r(uint256 seed) internal pure returns (uint256) {
        return 1 + seed % ROUNDS;
    }

    function pixelsArrive(uint256 amount) external {
        vm.prank(admin);
        ledger.mintTo(address(store), bound(amount, 1, 50));
    }

    function addBalance(uint256 id, uint256 amount) external {
        try store.addBalance(id % IDS, address(this), bound(amount, 0, 60)) {
            ++ok;
        } catch { }
    }

    function chargeEntry(uint256 round, uint256 id, uint256 amount) external {
        try store.chargeEntry(_r(round), id % IDS, bound(amount, 0, 60)) {
            ++ok;
        } catch { }
    }

    function creditFromPool(uint256 round, uint256 idA, uint256 idB, uint256 a, uint256 b) external {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = idA % IDS;
        ids[1] = idB % IDS;
        amounts[0] = bound(a, 0, 60);
        amounts[1] = bound(b, 0, 60);
        try store.creditFromPool(_r(round), ids, amounts) {
            ++ok;
        } catch { }
    }

    function addSponsorship(uint256 round, uint256 amount) external {
        try store.addSponsorship(_r(round), address(this), bound(amount, 0, 60)) {
            ++ok;
        } catch { }
    }

    function moveSponsorship(uint256 from, uint256 to, uint256 amount) external {
        try store.moveSponsorship(_r(from), _r(to), bound(amount, 0, 60)) {
            ++ok;
        } catch { }
    }

    function releaseSponsorship(uint256 round, uint256 amount) external {
        try store.releaseSponsorship(_r(round), address(0xD00D), bound(amount, 0, 60)) {
            ++ok;
        } catch { }
    }

    function flags(uint256 round, uint256 what) external {
        uint256 r = _r(round);
        what %= 5;
        if (what == 0) {
            try store.setStarted(r) {
                ++ok;
            } catch { }
        }
        if (what == 1) {
            try store.setClosed(r) {
                ++ok;
            } catch { }
        }
        if (what == 2) {
            try store.setFinished(r) {
                ++ok;
            } catch { }
        }
        if (what == 3) {
            try store.setSettled(r) {
                ++ok;
            } catch { }
        }
        if (what == 4) {
            try store.setCancelled(r, r + 1) {
                ++ok;
            } catch { }
        }
    }

    function line(uint256 id, uint256 what, bool flag) external {
        what %= 4;
        if (what == 0) {
            try store.pushTicket(id % IDS) {
                ++ok;
            } catch { }
        }
        if (what == 1) {
            try store.popTicket(_r(id)) {
                ++ok;
            } catch { }
        }
        if (what == 2) {
            try store.deactivate(id % IDS, flag) {
                ++ok;
            } catch { }
        }
        if (what == 3) {
            try store.addPlayer(_r(id / 7), id % IDS) {
                ++ok;
            } catch { }
        }
    }

    function holderWithdraws(uint256 id, uint256 amount) external {
        id %= IDS;
        uint256 bal = store.balanceOf(id);
        if (bal == 0) return;
        try normies.ownerOf(id) returns (address holder) {
            vm.prank(holder);
            store.withdraw(id, bound(amount, 1, bal));
            ++ok;
        } catch { }
    }

    function burnAndRescue(uint256 id) external {
        id %= IDS;
        try normies.ownerOf(id) returns (address holder) {
            if (id != 5) return; // only Normie 5 is ever burned
            vm.prank(holder);
            normies.burn(id);
        } catch { }
        if (store.isBurned(id) && store.balanceOf(id) > 0) {
            vm.prank(admin);
            store.rescue(id, address(0xD00D));
            ++ok;
        }
    }

    function ownerSweeps(uint256 amount) external {
        uint256 s = store.surplus();
        if (s == 0) return;
        vm.prank(admin);
        store.sweep(address(0xD00D), bound(amount, 1, s));
        ++ok;
    }
}

/// forge-config: default.invariant.runs = 300
/// forge-config: default.invariant.depth = 200
/// forge-config: default.invariant.fail-on-revert = true
contract ArenaStorageWriterInvariantTest is ArenaAuditBase {
    RawWriterHandler handler;

    function setUp() public override {
        super.setUp();
        for (uint256 id; id < 6; ++id) {
            normies.mint(alice, id);
        }
        handler = new RawWriterHandler(store, ledger, normies, address(this));
        store.setAuthorizedWriter(address(handler), true);
        targetContract(address(handler));
    }

    /// @notice Whatever a writer does, the storage stays solvent and its totals stay equal to the sums they stand
    ///         for: no sequence of setter calls creates a pixel, and every balance stays withdrawable.
    function invariant_storageBookkeepingHoldsForAnyWriter() public view {
        uint256 balances;
        for (uint256 id; id < handler.IDS(); ++id) {
            balances += store.balanceOf(id);
        }
        uint256 pools;
        for (uint256 round = 1; round <= handler.ROUNDS() + 1; ++round) {
            NormiesArenaStorage.Round memory g = store.roundOf(round);
            pools += g.unpaid;
            if (g.settled || g.cancelled) assertEq(g.unpaid, 0, "a closed round holds pixels");
        }
        assertEq(balances, store.totalAllocated(), "totalAllocated");
        assertEq(pools, store.totalPooled(), "totalPooled");
        assertGe(ledger.balanceOf(address(store)), store.totalAllocated() + store.totalPooled(), "solvency");
    }

    function afterInvariant() public {
        emit log_named_uint("successful writer / holder / owner actions in the last run", handler.ok());
    }
}
