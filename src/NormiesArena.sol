// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaAccess } from "./arena/ArenaAccess.sol";
import { NormiesArenaStorage } from "./NormiesArenaStorage.sol";

/**
 * @title NormiesArena
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @notice Runs Arena rounds on NormiesArenaStorage: holds the round settings, starts and finishes rounds, admits
 *         Normies from the line, takes results, settles and cancels.
 *
 *         A round's rules are the current settings until it starts, when the storage records them; every
 *         admission, settlement and cancellation of that round uses the recorded rules. Starting a round sets its
 *         ticket cutoff: Normies in line before the start can be admitted, later ones wait for the next round. A
 *         free round charges no entry price, so its pool is its sponsorship alone; it cannot start without one.
 *
 *         Admission takes Normies in line order up to the round's capacity. It skips a stale ticket, takes a burned
 *         Normie out of the line, and takes out a Normie whose balance is below the round's price (marked as short
 *         of funds). Every other Normie is admitted, whoever holds it: the price comes out of its balance and it
 *         gets a new ticket at the back.
 *
 *         Settlement pays the whole pool to n = ceil(players * winnerBps / 10,000) distinct players of the round.
 *         Each winner's balance gets floor(pool / n); the remainder (pool % n) goes 1 pixel each to the first
 *         pool % n winners in the list, which the owner passes ordered by rank, best first. The contract checks that
 *         each winner played and appears once, and the winner count; the results hash is stored as given. A
 *         cancel refunds each player's entry price to its balance and moves the sponsorship to the next round that
 *         has not started. A Normie credited a prize or a refund goes back to the back of the line if it had left
 *         it only for lack of funds and is not burned.
 *
 *         Roles: the owner changes settings, releases sponsorship and settles. The owner or
 *         OPERATOR_ROLE starts and finishes rounds, admits, takes Normies out of the line and posts results. The
 *         owner or GUARDIAN_ROLE pauses and cancels.
 *
 *         Moves no pixels itself and needs no role on the pixel ledger.
 */
contract NormiesArena is ArenaAccess {
    /// @notice Role that runs rounds (_ROLE_3, value 8).
    uint256 public constant OPERATOR_ROLE = _ROLE_3;
    /// @notice Highest settable capacity. Settling or cancelling a round credits each player in one call.
    uint256 public constant MAX_CAPACITY = 300;
    /// @notice Highest settable maxScan.
    uint256 public constant MAX_SCAN = 80;
    /// @notice Highest settable entry price, in pixels.
    uint256 public constant MAX_ENTRY_PRICE = 10_000;
    /// @dev Basis points in a whole.
    uint256 internal constant BPS = 10_000;

    /// @notice Most Normies admitted to a round.
    uint256 public capacity = 200;
    /// @notice Pixels charged per admission in a paid round.
    uint256 public entryPrice = 1;
    /// @notice Share of players who win, in basis points. 1,000 is the top 10%, rounded up.
    uint256 public winnerBps = 1000;
    /// @notice Most tickets one admit call may take from the line.
    uint256 public maxScan = 50;
    /// @notice Rounds with no entry price. Rounds 1 and 2 are free from deployment.
    mapping(uint256 => bool) public freeRound;

    /// @notice capacity was set.
    event CapacitySet(uint256 capacity);
    /// @notice entryPrice was set.
    event EntryPriceSet(uint256 entryPrice);
    /// @notice winnerBps was set.
    event WinnerBpsSet(uint256 winnerBps);
    /// @notice maxScan was set.
    event MaxScanSet(uint256 maxScan);
    /// @notice `round` was marked free or paid.
    event FreeRoundSet(uint256 indexed round, bool free);

    /// @notice `round` is free and has no sponsorship, so it would start with an empty pool.
    error FreeRoundNotSponsored(uint256 round);

    /// @param store_ The NormiesArenaStorage to use.
    /// @param admin  The owner.
    constructor(address store_, address admin) ArenaAccess(store_, admin) {
        freeRound[1] = true;
        freeRound[2] = true;
    }

    // ──────────────────────────────────────────────
    //  Settings (owner)
    // ──────────────────────────────────────────────

    /// @notice Set capacity, from 1 to MAX_CAPACITY. Owner only. Applies to rounds not yet started.
    function setCapacity(uint256 value) external onlyOwner {
        require(value > 0 && value <= MAX_CAPACITY, InvalidInput());
        capacity = value;
        emit CapacitySet(value);
    }

    /// @notice Set entryPrice, from 1 to MAX_ENTRY_PRICE. Owner only. Applies to rounds not yet started.
    function setEntryPrice(uint256 value) external onlyOwner {
        require(value > 0 && value <= MAX_ENTRY_PRICE, InvalidInput());
        entryPrice = value;
        emit EntryPriceSet(value);
    }

    /// @notice Set winnerBps, from 1 to 10,000. Owner only. Applies to rounds not yet started.
    function setWinnerBps(uint256 value) external onlyOwner {
        require(value > 0 && value <= BPS, InvalidInput());
        winnerBps = value;
        emit WinnerBpsSet(value);
    }

    /// @notice Set maxScan, from 1 to MAX_SCAN. Owner only. Applies to the next admit call.
    function setMaxScan(uint256 value) external onlyOwner {
        require(value > 0 && value <= MAX_SCAN, InvalidInput());
        maxScan = value;
        emit MaxScanSet(value);
    }

    /// @notice Mark `round` free or paid. Owner only, for a round above zero that has not started.
    function setFreeRound(uint256 round, bool free) external onlyOwner {
        require(round > 0 && !store.roundOf(round).started, InvalidState());
        freeRound[round] = free;
        emit FreeRoundSet(round, free);
    }

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    /// @notice `round`'s rules: the recorded ones once it has started, otherwise the current settings, with a
    ///         price of zero for a free round. `fixed_` tells which.
    /// @dev The casts cannot truncate: every setter bounds its value inside the field.
    function rulesOf(uint256 round) public view returns (NormiesArenaStorage.Rules memory r) {
        r = store.rulesOf(round);
        if (r.fixed_) return r;
        bool free = freeRound[round];
        r = NormiesArenaStorage.Rules({
            capacity: uint32(capacity),
            winnerBps: uint16(winnerBps),
            price: free ? 0 : uint64(entryPrice),
            free: free,
            fixed_: false
        });
    }

    /// @notice The latest round started. Zero before round 1.
    function currentRound() external view returns (uint256) {
        return store.currentRound();
    }

    /// @notice How many winners settle must name for `round`: ceil(players * winnerBps / 10,000) under its rules,
    ///         at least one when anyone played.
    function winnerCountOf(uint256 round) public view returns (uint256) {
        uint256 n = store.playerCount(round);
        return (n * rulesOf(round).winnerBps + BPS - 1) / BPS;
    }

    /// @notice `round`'s pool: its sponsorship plus its entry fees.
    function poolOf(uint256 round) external view returns (uint256) {
        return store.poolOf(round);
    }

    /// @notice Normies admitted to `round`, in admission order.
    function players(uint256 round) external view returns (uint256[] memory) {
        return store.players(round);
    }

    // ──────────────────────────────────────────────
    //  Sponsorship (owner)
    // ──────────────────────────────────────────────

    /// @notice Pay `amount` of the sponsorship of `round`, which must not have started, to `to`. Owner only.
    function releaseSponsorship(uint256 round, address to, uint256 amount) external onlyOwner {
        require(!store.roundOf(round).started, InvalidState());
        store.releaseSponsorship(round, to, amount);
    }

    // ──────────────────────────────────────────────
    //  Rounds (owner or operator)
    // ──────────────────────────────────────────────

    /// @notice Start `round` under rulesOf(round). Owner or OPERATOR_ROLE, while running. `round` must be
    ///         currentRound + 1 and the current round finished or cancelled, so a repeated call reverts with
    ///         InvalidState. A free round must have sponsorship, else it reverts with FreeRoundNotSponsored. Every
    ///         ticket issued before this call can be admitted, every later one waits for the next round.
    function startRound(uint256 round) external onlyOwnerOrRoles(OPERATOR_ROLE) whenRunning {
        uint256 previous = store.currentRound();
        NormiesArenaStorage.Round memory p = store.roundOf(previous);
        require(round == previous + 1 && (previous == 0 || p.finished || p.cancelled), InvalidState());
        NormiesArenaStorage.Rules memory r = rulesOf(round);
        require(!r.free || store.roundOf(round).sponsorship > 0, FreeRoundNotSponsored(round));
        store.setRules(round, r);
        store.setStarted(round);
    }

    /**
     * @notice Admit Normies to `round` from the head of the line. Owner or OPERATOR_ROLE, while running, for an open
     *         round with admissions open. Takes up to `scan` tickets and stops at capacity or when the line has no
     *         ticket the round can admit. Every ticket taken is removed from the line. Closes admissions when the
     *         round is full or the line is exhausted.
     * @param scan Most tickets to take, from 1 to maxScan.
     */
    function admit(uint256 round, uint256 scan) external onlyOwnerOrRoles(OPERATOR_ROLE) nonReentrant whenRunning {
        require(scan > 0 && scan <= maxScan, InvalidInput());
        require(store.isOpen(round) && !store.roundOf(round).closed, InvalidState());
        NormiesArenaStorage.Rules memory r = store.rulesOf(round);
        uint256 seated = store.playerCount(round);
        for (uint256 i; i < scan && seated < r.capacity; ++i) {
            (bool found, uint64 ticket, uint256 id) = store.popTicket(round);
            if (!found) break;
            if (_admitOne(round, ticket, id, r.price)) ++seated;
        }
        if (seated == r.capacity || store.lineExhausted(round)) store.setClosed(round);
    }

    /// @dev Admits the Normie behind `ticket` if the ticket is its current one and it is in the line. A burned
    ///      Normie leaves the line; one whose balance is below `price` leaves it marked as short of funds.
    /// @return Whether the Normie was admitted.
    function _admitOne(uint256 round, uint64 ticket, uint256 id, uint256 price) private returns (bool) {
        (uint64 current, bool active,) = store.enrollment(id);
        if (!active || current != ticket) return false;
        if (store.isBurned(id)) {
            store.deactivate(id, false);
            return false;
        }
        if (store.balanceOf(id) < price) {
            store.deactivate(id, true);
            return false;
        }
        if (price != 0) store.chargeEntry(round, id, price);
        store.addPlayer(round, id);
        store.pushTicket(id);
        return true;
    }

    /// @notice Finish `round`, which must be open, closing admissions if they are open. Owner or OPERATOR_ROLE.
    ///         Works while paused. The round can then take results and be settled or cancelled, and the next round
    ///         can start.
    function finishRound(uint256 round) external onlyOwnerOrRoles(OPERATOR_ROLE) {
        require(store.isOpen(round), InvalidState());
        if (!store.roundOf(round).closed) store.setClosed(round);
        store.setFinished(round);
    }

    /// @notice Take Normie `id` out of the line if `observedTicket` is still its current ticket and it is in the
    ///         line. Does nothing otherwise. Owner or OPERATOR_ROLE.
    function invalidateEnrollment(uint256 id, uint64 observedTicket) external onlyOwnerOrRoles(OPERATOR_ROLE) {
        (uint64 ticket, bool active,) = store.enrollment(id);
        if (ticket == observedTicket && active) store.deactivate(id, false);
    }

    /// @notice Post `resultHash`, which must be non-zero, as `round`'s results, replacing any earlier hash. Owner
    ///         or OPERATOR_ROLE, for a finished round that is neither settled nor cancelled. settle must be given
    ///         the hash stored at that moment.
    function postResults(uint256 round, bytes32 resultHash) external onlyOwnerOrRoles(OPERATOR_ROLE) {
        NormiesArenaStorage.Round memory g = store.roundOf(round);
        require(resultHash != bytes32(0), InvalidInput());
        require(g.finished && !g.settled && !g.cancelled, InvalidState());
        store.setResultHash(round, resultHash);
    }

    /**
     * @notice Settle `round`, paying its whole pool to the balances of `winners`. Owner only, while running, any
     *         time after the round is finished. With n winners, each gets floor(pool / n) and the first pool % n
     *         winners in the list get 1 pixel more. A winner credited pixels goes back in the line if it had left it
     *         only for lack of funds and is not burned.
     * @dev Reverts with InvalidState unless the round is finished, neither settled nor cancelled, has players,
     *      `resultHash` is the non-zero hash posted for it, and `winners` holds exactly winnerCountOf(round) ids;
     *      with InvalidInput for a winner that did not play the round or appears twice. Distinct winners are
     *      checked against an in-memory bitmap over ids below ID_BOUND.
     * @param resultHash The posted results hash the winners come from.
     * @param winners    Normie ids of the winners, ordered by rank, best first.
     */
    function settle(
        uint256 round,
        bytes32 resultHash,
        uint256[] calldata winners
    ) external onlyOwner nonReentrant whenRunning {
        NormiesArenaStorage.Round memory g = store.roundOf(round);
        require(
            g.finished && !g.settled && !g.cancelled && resultHash != bytes32(0) && g.resultHash == resultHash
                && store.playerCount(round) > 0 && winners.length == winnerCountOf(round),
            InvalidState()
        );
        uint256 pool = g.sponsorship + g.fees;
        uint256 n = winners.length;
        uint256[40] memory seen;
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 id = winners[i];
            require(id < 10_000 && store.played(round, id) && seen[id >> 8] & (1 << (id & 255)) == 0, InvalidInput());
            seen[id >> 8] |= 1 << (id & 255);
            amounts[i] = pool / n + (i < pool % n ? 1 : 0);
        }
        store.creditFromPool(round, winners, amounts);
        for (uint256 i; i < n; ++i) {
            if (amounts[i] != 0) _returnToLine(winners[i]);
        }
        store.setSettled(round);
    }

    /// @notice Cancel `round`: refund each player's entry price to its balance and move the rest of the pool (its
    ///         sponsorship) to round currentRound + 1, which has not started. Owner or GUARDIAN_ROLE, for a started
    ///         round that is not settled, open or finished, with or without results posted. Works while paused. An
    ///         empty round is cancelled the same way to carry its sponsorship forward. A refunded player goes back in
    ///         the line if it had left it only for lack of funds and is not burned.
    function cancel(uint256 round) external onlyOwnerOrRoles(GUARDIAN_ROLE) nonReentrant {
        NormiesArenaStorage.Round memory g = store.roundOf(round);
        require(g.started && !g.settled && !g.cancelled, InvalidState());
        uint256 price = store.rulesOf(round).price;
        if (price != 0) {
            uint256[] memory ids = store.players(round);
            uint256[] memory amounts = new uint256[](ids.length);
            for (uint256 i; i < ids.length; ++i) {
                amounts[i] = price;
            }
            store.creditFromPool(round, ids, amounts);
            for (uint256 i; i < ids.length; ++i) {
                _returnToLine(ids[i]);
            }
        }
        uint256 carryTo = store.currentRound() + 1;
        store.moveSponsorship(round, carryTo, store.roundOf(round).unpaid);
        store.setCancelled(round, carryTo);
    }

    /// @dev Puts Normie `id` back in the line, at the back, if it left only for lack of funds and is not burned.
    function _returnToLine(uint256 id) private {
        (, bool active, bool needsFunds) = store.enrollment(id);
        if (!active && needsFunds && !store.isBurned(id)) store.pushTicket(id);
    }
}
