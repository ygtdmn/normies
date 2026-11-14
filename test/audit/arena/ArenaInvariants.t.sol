// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { ArenaAuditBase, AuditAdapter, AuditDelegateRegistryV1, AuditDelegateRegistryV2 } from "./ArenaAuditBase.sol";
import { Normies } from "../../../src/Normies.sol";
import { NormiesCanvasStorageV2 } from "../../../src/NormiesCanvasStorageV2.sol";
import { NormiesArenaStorage } from "../../../src/NormiesArenaStorage.sol";
import { NormiesArenaQueue } from "../../../src/NormiesArenaQueue.sol";
import { NormiesArena } from "../../../src/NormiesArena.sol";
import { NormiesArenaSkins } from "../../../src/NormiesArenaSkins.sol";

/// @notice Drives the whole Arena (real collection, real ledger) through random but valid actions and checks each
///         action's local effect. A failed local check sets `violation` instead of reverting, so the campaign can run
///         with fail_on_revert = false without hiding it.
contract ArenaHandler is Test {
    Normies public normies;
    NormiesCanvasStorageV2 public ledger;
    AuditAdapter public adapter;
    NormiesArenaStorage public store;
    NormiesArenaQueue public queue;
    NormiesArena public arena;
    NormiesArenaSkins public skins;
    address public admin;
    address public operator;
    address public guardian;
    address public sponsorWallet;
    address public hot;
    address public sink = address(0x51CC);

    uint256[] public ids;
    address[] public holders;

    // Ghost accounting.
    uint256 public donated;
    uint256 public swept;
    uint256 public burns;
    string public violation;

    // Coverage counters.
    uint256 public nDeposit;
    uint256 public nWithdraw;
    uint256 public nPause;
    uint256 public nResume;
    uint256 public nTransfer;
    uint256 public nStart;
    uint256 public nStartRefusedFree;
    uint256 public nAdmit;
    uint256 public nSeats;
    uint256 public nShortExit;
    uint256 public nBurnedExit;
    uint256 public nFinish;
    uint256 public nSettle;
    uint256 public nCancel;
    uint256 public nCancelWithRefunds;
    uint256 public nReturnTopUp;
    uint256 public nReturnPrize;
    uint256 public nReturnRefund;
    uint256 public nRescue;
    uint256 public nSkin;
    uint256 public nSponsor;
    uint256 public nRelease;
    uint256 public nSweep;

    // Scratch snapshots, indexed like `ids`.
    uint256[] internal _bal;
    bool[] internal _active;
    bool[] internal _needs;
    bool[] internal _played;
    uint64[] internal _ticket;

    constructor(
        Normies normies_,
        NormiesCanvasStorageV2 ledger_,
        AuditAdapter adapter_,
        NormiesArenaStorage store_,
        NormiesArenaQueue queue_,
        NormiesArena arena_,
        NormiesArenaSkins skins_,
        address[5] memory roles,
        uint256[] memory ids_,
        address[] memory holders_
    ) {
        normies = normies_;
        ledger = ledger_;
        adapter = adapter_;
        store = store_;
        queue = queue_;
        arena = arena_;
        skins = skins_;
        admin = roles[0];
        operator = roles[1];
        guardian = roles[2];
        sponsorWallet = roles[3];
        hot = roles[4];
        ids = ids_;
        holders = holders_;
        _bal = new uint256[](ids_.length);
        _active = new bool[](ids_.length);
        _needs = new bool[](ids_.length);
        _played = new bool[](ids_.length);
        _ticket = new uint64[](ids_.length);
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function _fail(string memory why) internal {
        if (bytes(violation).length == 0) violation = why;
    }

    function _holder(uint256 id) internal view returns (address) {
        try normies.ownerOf(id) returns (address h) {
            return h;
        } catch {
            return address(0);
        }
    }

    function _fund(address who, uint256 amount) internal {
        vm.prank(admin);
        ledger.mintTo(who, amount);
    }

    function _snapshot(uint256 round) internal {
        for (uint256 i; i < ids.length; ++i) {
            _bal[i] = store.balanceOf(ids[i]);
            (_ticket[i], _active[i], _needs[i]) = store.enrollment(ids[i]);
            _played[i] = round == 0 ? false : store.played(round, ids[i]);
        }
    }

    function _callerFor(address holder, bool viaDelegate) internal view returns (address) {
        if (!viaDelegate) return holder;
        // `hot` is a v2 wallet-level delegate of holders[0] and a v1 wallet-level delegate of holders[1].
        if (holder == holders[0] || holder == holders[1]) return hot;
        return holder;
    }

    // ───────────── holders ─────────────

    function deposit(uint256 idSeed, uint256 amount, bool enroll, bool viaDelegate) public {
        uint256 i = idSeed % ids.length;
        uint256 id = ids[i];
        address holder = _holder(id);
        if (holder == address(0)) return;
        address caller = _callerFor(holder, viaDelegate);
        amount = bound(amount, 1, 4);
        _fund(caller, amount);
        _snapshot(0);
        bool awake = _awake(id);
        uint256 callerBefore = ledger.balanceOf(caller);
        vm.prank(caller);
        try queue.deposit(id, amount, enroll) {
            ++nDeposit;
            (uint64 ticket, bool active, bool needs) = store.enrollment(id);
            if (store.balanceOf(id) != _bal[i] + amount) _fail("deposit: balance");
            if (ledger.balanceOf(caller) != callerBefore - amount) _fail("deposit: caller not charged");
            if (_active[i]) {
                if (!active || ticket != _ticket[i]) _fail("deposit: ticket of a Normie in line changed");
            } else if (enroll || _needs[i]) {
                if (!active || needs || ticket != store.tail()) _fail("deposit: not at the end of the line");
                if (_needs[i]) ++nReturnTopUp;
            } else if (active) {
                _fail("deposit: joined without being asked");
            }
        } catch {
            // Joining, or returning a short Normie, needs the agent link to still match its binding (L-04).
            if (!((enroll || _needs[i]) && !_active[i] && !awake)) _fail("deposit: unexpected revert");
        }
    }

    function withdraw(uint256 idSeed, uint256 amount, bool viaDelegate) public {
        uint256 i = idSeed % ids.length;
        uint256 id = ids[i];
        address holder = _holder(id);
        uint256 bal = store.balanceOf(id);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        if (holder == address(0)) {
            vm.prank(holders[0]);
            try store.withdraw(id, amount) {
                _fail("withdraw: burned Normie paid out");
            } catch { }
            return;
        }
        address caller = _callerFor(holder, viaDelegate);
        uint256 holderBefore = ledger.balanceOf(holder);
        uint256 callerBefore = ledger.balanceOf(caller);
        _snapshot(0);
        vm.prank(caller);
        store.withdraw(id, amount);
        ++nWithdraw;
        if (ledger.balanceOf(holder) != holderBefore + amount) _fail("withdraw: holder not paid");
        if (caller != holder && ledger.balanceOf(caller) != callerBefore) _fail("withdraw: delegate paid");
        if (store.balanceOf(id) != bal - amount) _fail("withdraw: balance");
        (uint64 ticket, bool active, bool needs) = store.enrollment(id);
        if (ticket != _ticket[i] || active != _active[i] || needs != _needs[i]) _fail("withdraw: line changed");
        // Let the cooldown pass so withdrawn pixels can be used again.
        vm.warp(block.timestamp + 61);
    }

    /// @dev The holder takes the whole balance out, so the Normie is short at its next paid admission.
    function drain(uint256 idSeed) public {
        uint256 id = ids[idSeed % ids.length];
        address holder = _holder(id);
        uint256 bal = store.balanceOf(id);
        if (holder == address(0) || bal == 0) return;
        vm.prank(holder);
        store.withdraw(id, bal);
        ++nWithdraw;
        vm.warp(block.timestamp + 61);
    }

    function strangerCannotWithdraw(uint256 idSeed) public {
        uint256 id = ids[idSeed % ids.length];
        if (store.balanceOf(id) == 0) return;
        vm.prank(address(0xBAD));
        try store.withdraw(id, 1) {
            _fail("withdraw: stranger succeeded");
        } catch { }
    }

    function pause(uint256 idSeed, bool viaDelegate) public {
        uint256 id = ids[idSeed % ids.length];
        address holder = _holder(id);
        if (holder == address(0)) return;
        vm.prank(_callerFor(holder, viaDelegate));
        queue.pause(id);
        ++nPause;
        (, bool active, bool needs) = store.enrollment(id);
        if (active || needs) _fail("pause: still in line or marked short");
    }

    function resume(uint256 idSeed, bool viaDelegate) public {
        uint256 id = ids[idSeed % ids.length];
        address holder = _holder(id);
        if (holder == address(0)) return;
        (, bool activeBefore,) = store.enrollment(id);
        if (activeBefore || !_awake(id)) return;
        vm.prank(_callerFor(holder, viaDelegate));
        queue.resume(id);
        ++nResume;
        (uint64 ticket, bool active,) = store.enrollment(id);
        if (!active || ticket != store.tail()) _fail("resume: not at the end");
    }

    function transfer(uint256 idSeed, uint256 toSeed) public {
        uint256 i = idSeed % ids.length;
        uint256 id = ids[i];
        address holder = _holder(id);
        if (holder == address(0)) return;
        address to = holders[toSeed % holders.length];
        _snapshot(0);
        vm.prank(holder);
        normies.transferFrom(holder, to, id);
        ++nTransfer;
        (uint64 ticket, bool active, bool needs) = store.enrollment(id);
        if (ticket != _ticket[i] || active != _active[i] || needs != _needs[i]) _fail("transfer: line changed");
        if (store.balanceOf(id) != _bal[i]) _fail("transfer: balance changed");
    }

    function burn(uint256 idSeed) public {
        if (burns >= 3) return;
        uint256 id = ids[idSeed % ids.length];
        address holder = _holder(id);
        if (holder == address(0)) return;
        vm.prank(holder);
        normies.burn(id);
        ++burns;
    }

    function rebind(uint256 idSeed, bool on) public {
        uint256 id = ids[idSeed % ids.length];
        if (on) adapter.bind(id + 1, id);
        else adapter.unbind(id + 1);
    }

    function skin(uint256 idSeed, uint256 buyerSeed) public {
        uint256 id = ids[idSeed % ids.length];
        if (_holder(id) == address(0)) return;
        address buyer = holders[buyerSeed % holders.length];
        uint256 price = skins.price();
        _fund(buyer, price);
        uint256 custody = ledger.balanceOf(address(store));
        vm.prank(buyer);
        skins.purchase(id, price, buyer);
        ++nSkin;
        if (ledger.balanceOf(address(store)) != custody) _fail("skin: Arena custody moved");
    }

    // ───────────── team ─────────────

    function sponsor(uint256 roundSeed, uint256 amount) public {
        uint256 current = store.currentRound();
        uint256 round = current + (roundSeed % 4);
        if (round == 0) round = 1;
        NormiesArenaStorage.Round memory g = store.roundOf(round);
        if (g.settled || g.cancelled) return;
        amount = bound(amount, 1, 40);
        _fund(sponsorWallet, amount);
        vm.prank(sponsorWallet);
        queue.sponsor(round, amount);
        ++nSponsor;
    }

    function release(uint256 roundSeed, uint256 amount) public {
        uint256 round = store.currentRound() + 1 + (roundSeed % 3);
        uint256 s = store.roundOf(round).sponsorship;
        if (s == 0) return;
        amount = bound(amount, 1, s);
        uint256 before = ledger.balanceOf(sink);
        vm.prank(admin);
        arena.releaseSponsorship(round, sink, amount);
        ++nRelease;
        if (ledger.balanceOf(sink) != before + amount) _fail("release: not paid");
    }

    function settings(uint256 seed) public {
        vm.startPrank(admin);
        uint256 what = seed % 5;
        uint256 v = seed >> 8;
        if (what == 0) arena.setEntryPrice(1 + v % 4);
        if (what == 1) arena.setCapacity(1 + v % 8);
        if (what == 2) arena.setWinnerBps(1 + v % 10_000);
        if (what == 3) arena.setMaxScan(1 + v % 6);
        if (what == 4) arena.setFreeRound(store.currentRound() + 1 + v % 3, (v >> 4) & 3 == 3);
        vm.stopPrank();
    }

    function startRound() public {
        uint256 current = store.currentRound();
        NormiesArenaStorage.Round memory p = store.roundOf(current);
        if (!(current == 0 || p.finished || p.cancelled)) return;
        uint256 next = current + 1;
        bool free = arena.rulesOf(next).free;
        uint256 s = store.roundOf(next).sponsorship;
        vm.prank(operator);
        try arena.startRound(next) {
            ++nStart;
            if (free && s == 0) _fail("start: free round started with no sponsorship");
            NormiesArenaStorage.Rules memory r = store.rulesOf(next);
            if (!r.fixed_ || r.free != free || (free && r.price != 0) || (!free && r.price == 0)) {
                _fail("start: rules");
            }
            if (store.roundOf(next).ticketCutoff != store.tail()) _fail("start: cutoff");
        } catch {
            ++nStartRefusedFree;
            if (!(free && s == 0)) _fail("start: unexpected revert");
        }
    }

    function admit(uint256 scan) public {
        uint256 round = store.currentRound();
        if (round == 0 || !store.isOpen(round) || store.roundOf(round).closed) return;
        scan = bound(scan, 1, arena.maxScan());
        NormiesArenaStorage.Rules memory r = store.rulesOf(round);
        uint64 cutoff = store.roundOf(round).ticketCutoff;
        _snapshot(round);
        vm.prank(operator);
        arena.admit(round, scan);
        ++nAdmit;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            (uint64 ticket, bool active, bool needs) = store.enrollment(id);
            if (store.played(round, id) && !_played[i]) {
                ++nSeats;
                if (_bal[i] - store.balanceOf(id) != r.price) _fail("admit: seat not charged exactly the price");
                if (_holder(id) == address(0)) _fail("admit: burned Normie seated");
                if (!_active[i]) _fail("admit: Normie out of the line seated");
                if (!active || ticket <= cutoff || ticket <= _ticket[i]) _fail("admit: no new ticket at the back");
            } else {
                if (store.balanceOf(id) != _bal[i]) _fail("admit: balance moved without a seat");
                if (_active[i] && !active) {
                    if (needs) {
                        ++nShortExit;
                        if (_bal[i] >= r.price) _fail("admit: marked short with enough balance");
                    } else {
                        ++nBurnedExit;
                        if (_holder(id) != address(0)) _fail("admit: live Normie dropped");
                    }
                }
                if (!_active[i] && active) _fail("admit: Normie joined");
            }
        }
        if (store.playerCount(round) > r.capacity) _fail("admit: over capacity");
    }

    function finishRound() public {
        uint256 round = store.currentRound();
        if (round == 0 || !store.isOpen(round)) return;
        vm.prank(operator);
        arena.finishRound(round);
        ++nFinish;
    }

    function invalidate(uint256 idSeed) public {
        uint256 id = ids[idSeed % ids.length];
        (uint64 ticket,,) = store.enrollment(id);
        vm.prank(operator);
        arena.invalidateEnrollment(id, ticket);
    }

    function _pickRound(uint256 seed, bool forSettle) internal view returns (uint256) {
        uint256 current = store.currentRound();
        for (uint256 k; k < current; ++k) {
            uint256 round = 1 + (seed % current + k) % current;
            NormiesArenaStorage.Round memory g = store.roundOf(round);
            if (g.settled || g.cancelled || !g.started) continue;
            if (forSettle && (!g.finished || store.playerCount(round) == 0)) continue;
            return round;
        }
        return 0;
    }

    function _pickPaidRound(uint256 seed) internal view returns (uint256) {
        uint256 current = store.currentRound();
        for (uint256 k; k < current; ++k) {
            uint256 round = 1 + (seed % current + k) % current;
            NormiesArenaStorage.Round memory g = store.roundOf(round);
            if (g.started && !g.settled && !g.cancelled && g.fees != 0) return round;
        }
        return 0;
    }

    function settle(uint256 roundSeed, uint256 shuffleSeed) public {
        uint256 round = _pickRound(roundSeed, true);
        if (round == 0) return;
        uint256[] memory players = store.players(round);
        uint256 n = arena.winnerCountOf(round);
        // Fisher-Yates: a random rank order.
        for (uint256 i; i < n; ++i) {
            uint256 j = i + uint256(keccak256(abi.encode(shuffleSeed, i))) % (players.length - i);
            (players[i], players[j]) = (players[j], players[i]);
        }
        uint256[] memory winners = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            winners[i] = players[i];
        }
        NormiesArenaStorage.Round memory g = store.roundOf(round);
        uint256 pool = g.sponsorship + g.fees;
        if (pool != g.unpaid) _fail("settle: pool differs from unpaid");
        bytes32 h = keccak256(abi.encode(round, shuffleSeed));
        vm.prank(operator);
        arena.postResults(round, h);
        _snapshot(0);
        vm.prank(admin);
        arena.settle(round, h, winners);
        ++nSettle;
        uint256 paid;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            uint256 expected;
            for (uint256 w; w < n; ++w) {
                if (winners[w] == id) expected = pool / n + (w < pool % n ? 1 : 0);
            }
            if (store.balanceOf(id) != _bal[i] + expected) _fail("settle: wrong amount");
            paid += expected;
            _checkReturn(i, expected != 0, true);
        }
        if (paid != pool) _fail("settle: pool not paid in full");
        g = store.roundOf(round);
        if (!g.settled || g.unpaid != 0) _fail("settle: flags");
    }

    function cancel(uint256 roundSeed) public {
        // Two cancels in three are skipped, so most finished rounds are left for settle.
        if (roundSeed % 3 != 0) return;
        uint256 round = _pickRound(roundSeed / 3, false);
        // Half of the time prefer a round that has entry fees to refund.
        if ((roundSeed / 3) & 1 == 1) {
            uint256 paid = _pickPaidRound(roundSeed / 6);
            if (paid != 0) round = paid;
        }
        if (round == 0) return;
        uint256 price = store.rulesOf(round).price;
        NormiesArenaStorage.Round memory g = store.roundOf(round);
        uint256 carryTo = store.currentRound() + 1;
        uint256 carryBefore = store.roundOf(carryTo).sponsorship;
        _snapshot(round);
        vm.prank(guardian);
        arena.cancel(round);
        ++nCancel;
        if (g.fees != 0) ++nCancelWithRefunds;
        uint256 refunded;
        for (uint256 i; i < ids.length; ++i) {
            uint256 expected = _played[i] ? price : 0;
            if (store.balanceOf(ids[i]) != _bal[i] + expected) _fail("cancel: wrong refund");
            refunded += expected;
            _checkReturn(i, expected != 0, false);
        }
        if (refunded != g.fees) _fail("cancel: fees not refunded in full");
        if (store.roundOf(carryTo).sponsorship != carryBefore + g.unpaid - g.fees) _fail("cancel: carry");
        g = store.roundOf(round);
        if (!g.cancelled || g.unpaid != 0) _fail("cancel: flags");
    }

    /// @dev After a credit: a Normie that was out only for lack of funds and is not burned is back at the end; every
    ///      other Normie's place in the line is unchanged.
    function _checkReturn(uint256 i, bool credited, bool prize) internal {
        uint256 id = ids[i];
        (uint64 ticket, bool active, bool needs) = store.enrollment(id);
        bool shouldReturn = credited && !_active[i] && _needs[i] && _holder(id) != address(0);
        if (shouldReturn) {
            if (!active || needs || ticket <= _ticket[i]) _fail("credit: short Normie not returned to the line");
            if (prize) ++nReturnPrize;
            else ++nReturnRefund;
        } else if (ticket != _ticket[i] || active != _active[i] || needs != _needs[i]) {
            _fail("credit: line changed for a Normie that should not move");
        }
    }

    function rescue(uint256 idSeed) public {
        uint256 id = ids[idSeed % ids.length];
        uint256 bal = store.balanceOf(id);
        if (_holder(id) != address(0)) {
            vm.prank(admin);
            try store.rescue(id, sink) {
                _fail("rescue: live Normie rescued");
            } catch { }
            return;
        }
        if (bal == 0) return;
        uint256 before = ledger.balanceOf(sink);
        vm.prank(admin);
        store.rescue(id, sink);
        ++nRescue;
        if (ledger.balanceOf(sink) != before + bal || store.balanceOf(id) != 0) _fail("rescue: amount");
    }

    function donate(uint256 amount) public {
        amount = bound(amount, 1, 9);
        _fund(address(store), amount);
        donated += amount;
    }

    function sweep(uint256 amount) public {
        uint256 s = store.surplus();
        if (s == 0) return;
        amount = bound(amount, 1, s);
        vm.prank(admin);
        store.sweep(sink, amount);
        swept += amount;
        ++nSweep;
        vm.prank(admin);
        try store.sweep(sink, store.surplus() + 1) {
            _fail("sweep: took more than the surplus");
        } catch { }
    }

    function _awake(uint256 id) internal view returns (bool) {
        if (!store.agentBound(id)) return false;
        try adapter.bindingOf(store.agentOf(id)) returns (uint8 standard, address bound_, uint256 tokenId) {
            return standard == 0 && bound_ == address(normies) && tokenId == id;
        } catch {
            return false;
        }
    }

    /// @dev One pseudo-random action, for the deterministic coverage run.
    function step(uint256 seed) external {
        uint256 a = uint256(keccak256(abi.encode(seed, "a")));
        uint256 b = uint256(keccak256(abi.encode(seed, "b")));
        uint256 what = seed % 40;
        if (what < 6) deposit(a, b, b & 12 != 0, b & 2 == 2);
        else if (what < 12) withdraw(a, b, b & 1 == 1);
        else if (what < 13) pause(a, b & 1 == 1);
        else if (what < 15) resume(a, b & 1 == 1);
        else if (what < 17) transfer(a, b);
        else if (what < 18 && a % 5 == 0) burn(a >> 8);
        else if (what < 19) rebind(a, b % 4 != 0);
        else if (what < 20) skin(a, b);
        else if (what < 22) sponsor(a, b);
        else if (what < 23) release(a, b);
        else if (what < 25) settings(a);
        else if (what < 28) startRound();
        else if (what < 33) admit(a);
        else if (what < 35) finishRound();
        else if (what < 36) settle(a, b);
        else if (what < 37) drain(a);
        else if (what < 38) cancel(a);
        else if (what < 39) rescue(a);
        else if (a & 1 == 1) donate(a >> 8);
        else sweep(a >> 8);
    }
}

/// forge-config: default.invariant.runs = 300
/// forge-config: default.invariant.depth = 250
/// forge-config: default.invariant.fail-on-revert = true
contract ArenaInvariantTest is ArenaAuditBase {
    ArenaHandler handler;
    address dave = address(0xDA7E);

    function setUp() public override {
        super.setUp();
        sponsorFreeRounds();
        uint256[] memory ids = new uint256[](12);
        address[] memory holders = new address[](4);
        holders[0] = alice;
        holders[1] = bob;
        holders[2] = carol;
        holders[3] = dave;
        for (uint256 i; i < 12; ++i) {
            // Both ends of the id range, and Normie #0.
            ids[i] = i < 6 ? i : 9988 + i;
            normies.mint(holders[i % 4], ids[i]);
            // Agent id + 1 so that agent 0 is not used.
            adapter.bind(ids[i] + 1, ids[i]);
            vm.prank(holders[i % 4]);
            queue.bindAgent(ids[i], ids[i] + 1);
        }
        regV2.delegateAll(hot, alice, true);
        regV1.delegateForAll(hot, bob, true);
        handler = new ArenaHandler(
            normies,
            ledger,
            adapter,
            store,
            queue,
            arena,
            skins,
            [address(this), operator, guardian, sponsorWallet, hot],
            ids,
            holders
        );
        targetContract(address(handler));
        bytes4[] memory skip = new bytes4[](1);
        skip[0] = handler.step.selector;
        excludeSelector(FuzzSelector({ addr: address(handler), selectors: skip }));
    }

    function _check() internal view {
        assertEq(handler.violation(), "", "a handler check failed");
        // Custody: ledger balance = Normie balances + open pools + (pixels sent directly - swept).
        uint256 surplus = handler.donated() - handler.swept();
        assertEq(ledger.balanceOf(address(store)), store.totalAllocated() + store.totalPooled() + surplus, "custody");
        assertEq(store.surplus(), surplus, "surplus view");
        // totalAllocated = sum of balances.
        uint256 n = handler.idCount();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            sum += store.balanceOf(id);
            (uint64 ticket, bool active, bool needs) = store.enrollment(id);
            assertFalse(active && needs, "in line and marked short");
            if (active) {
                // The Normie's current ticket is alive in the line and is its own.
                assertGe(ticket, store.head(), "active ticket behind the head");
                assertLe(ticket, store.tail(), "active ticket past the tail");
                assertEq(store.tickets(ticket), id, "ticket points at another Normie");
            }
        }
        assertEq(sum, store.totalAllocated(), "totalAllocated");
        assertLe(store.head(), uint256(store.tail()) + 1, "head past tail");
        // Rounds.
        uint256 current = store.currentRound();
        uint256 pooled;
        uint256 open;
        for (uint256 round = 1; round <= current + 4; ++round) {
            NormiesArenaStorage.Round memory g = store.roundOf(round);
            NormiesArenaStorage.Rules memory r = store.rulesOf(round);
            pooled += g.unpaid;
            if (round > current) {
                assertFalse(g.started || g.closed || g.finished || g.settled || g.cancelled, "future round flags");
                assertEq(g.fees, 0, "future round fees");
                assertEq(g.unpaid, g.sponsorship, "future round unpaid");
                assertFalse(r.fixed_, "future round rules fixed");
                continue;
            }
            assertTrue(g.started && r.fixed_, "past round not started");
            assertFalse(g.settled && g.cancelled, "settled and cancelled");
            if (store.isOpen(round)) ++open;
            if (round < current) assertTrue(g.finished || g.cancelled, "earlier round still open");
            uint256 count = store.playerCount(round);
            assertLe(count, r.capacity, "capacity");
            assertEq(g.fees, count * r.price, "fees = seats x recorded price");
            if (r.free) assertTrue(r.price == 0 && g.sponsorship > 0, "free round without a pool");
            if (g.settled || g.cancelled) assertEq(g.unpaid, 0, "closed round still holds pixels");
            else assertEq(g.unpaid, g.sponsorship + g.fees, "open pool = sponsorship + fees");
            if (g.settled) assertTrue(g.finished && count > 0, "settled without players");
        }
        assertEq(pooled, store.totalPooled(), "totalPooled");
        assertLe(open, 1, "more than one round open");
    }

    function invariant_arena() public view {
        _check();
    }

    /// @dev After each run: every round's player list has no repeats, and the line from head to tail holds each
    ///      Normie that is in line exactly once as its current ticket.
    function afterInvariant() public view {
        _deepCheck();
    }

    function _deepCheck() internal view {
        uint256 current = store.currentRound();
        for (uint256 round = 1; round <= current; ++round) {
            uint256[] memory p = store.players(round);
            for (uint256 i; i < p.length; ++i) {
                assertTrue(store.played(round, p[i]));
                for (uint256 j = i + 1; j < p.length; ++j) {
                    assertTrue(p[i] != p[j], "a Normie seated twice in a round");
                }
            }
        }
        uint256 live;
        for (uint64 t = store.head(); t <= store.tail(); ++t) {
            uint256 id = store.tickets(t);
            (uint64 ticket, bool active,) = store.enrollment(id);
            if (active && ticket == t) ++live;
        }
        uint256 inLineCount;
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            (, bool active,) = store.enrollment(handler.ids(i));
            if (active) ++inLineCount;
        }
        assertEq(live, inLineCount, "live current tickets != Normies in line");
    }

    /// @notice Deterministic run of 4,500 actions through the same handler, to show the campaign's actions really
    ///         complete whole rounds (so the invariants are not passing on an idle system), with the invariants
    ///         checked every 50 actions and at the end.
    function test_handlerCoverage() public {
        for (uint256 s; s < 4500; ++s) {
            handler.step(uint256(keccak256(abi.encode("arena-audit", s))));
            if (s % 50 == 0) _check();
        }
        _check();
        _deepCheck();
        emit log_named_uint("rounds started", handler.nStart());
        emit log_named_uint("free round starts refused (no sponsorship)", handler.nStartRefusedFree());
        emit log_named_uint("admit calls", handler.nAdmit());
        emit log_named_uint("seats", handler.nSeats());
        emit log_named_uint("left the line short of funds", handler.nShortExit());
        emit log_named_uint("left the line burned", handler.nBurnedExit());
        emit log_named_uint("rounds finished", handler.nFinish());
        emit log_named_uint("rounds settled", handler.nSettle());
        emit log_named_uint("rounds cancelled", handler.nCancel());
        emit log_named_uint("rounds cancelled with fees to refund", handler.nCancelWithRefunds());
        emit log_named_uint("returned by top-up", handler.nReturnTopUp());
        emit log_named_uint("returned by prize", handler.nReturnPrize());
        emit log_named_uint("returned by refund", handler.nReturnRefund());
        emit log_named_uint("deposits", handler.nDeposit());
        emit log_named_uint("withdrawals", handler.nWithdraw());
        emit log_named_uint("pauses", handler.nPause());
        emit log_named_uint("resumes", handler.nResume());
        emit log_named_uint("transfers", handler.nTransfer());
        emit log_named_uint("burns", handler.burns());
        emit log_named_uint("rescues", handler.nRescue());
        emit log_named_uint("skin purchases", handler.nSkin());
        emit log_named_uint("sponsorships", handler.nSponsor());
        emit log_named_uint("releases", handler.nRelease());
        emit log_named_uint("sweeps", handler.nSweep());
        emit log_named_uint("line head", store.head());
        emit log_named_uint("line tail", store.tail());
        assertGt(handler.nSettle(), 20);
        assertGt(handler.nCancel(), 5);
        assertGt(handler.nSeats(), 200);
        assertGt(handler.nShortExit(), 5);
        assertGt(handler.nReturnTopUp(), 0);
        assertGt(handler.nReturnPrize(), 0);
        assertGt(handler.nReturnRefund(), 0);
        assertGt(handler.nBurnedExit(), 0);
    }
}
