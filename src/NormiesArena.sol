// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaAccess } from "./arena/ArenaAccess.sol";

/**
 * @title NormiesArena
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @notice Runs Arena rounds on NormiesArenaStorage: holds the price settings, starts rounds, pays out their pools,
 *         ends and cancels them.
 *
 *         Starting a round charges nobody one by one: the storage counts who plays (see NormiesArenaStorage). A paid
 *         round is played by every active Normie (registered, not short) whose balance covers the price; a free
 *         round by every registered Normie. Which of them get a seat, and when, is decided off chain. A free round
 *         cannot start with an empty pool.
 *
 *         Paying out takes three lists, decided off chain: refundees, each credited the round's entry price, then
 *         winners with the amount each gets. Every credit goes to the Normie's Arena balance. The contract checks
 *         only that the total fits the unpaid pool. Ending a round rolls whatever is left of its pool into the next
 *         round. endRound alone pays out and ends a round of up to MAX_PAYOUT_ENTRIES entries; a bigger round takes
 *         payout calls first. The next round can start only after the current one is ended or cancelled.
 *         Cancelling rolls the unpaid pool into the next round; credits already made stay.
 *
 *         Roles: the owner changes settings and releases unstarted pools. The owner or OPERATOR_ROLE starts rounds,
 *         pays out and ends them. The owner or GUARDIAN_ROLE pauses and cancels.
 *
 *         Moves no pixels itself and needs no role on the pixel ledger.
 */
contract NormiesArena is ArenaAccess {
    /// @notice Role that runs rounds (_ROLE_3, value 8).
    uint256 public constant OPERATOR_ROLE = _ROLE_3;
    /// @notice Highest settable entry price, in pixels.
    uint256 public constant MAX_ENTRY_PRICE = 10_000;
    /// @notice Most entries (refundees plus winners) in one payout or endRound call.
    uint256 public constant MAX_PAYOUT_ENTRIES = 300;

    /// @notice Pixels charged per player in a paid round.
    uint256 public entryPrice = 1;
    /// @notice Rounds with no entry price. Rounds 1 and 2 are free from deployment.
    mapping(uint256 => bool) public freeRound;

    /// @notice entryPrice was set.
    event EntryPriceSet(uint256 entryPrice);
    /// @notice `round` was marked free or paid.
    event FreeRoundSet(uint256 indexed round, bool free);

    /// @notice `round` is free and its pool is empty.
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

    /// @notice Set entryPrice, from 1 to MAX_ENTRY_PRICE. Owner only. Applies to rounds not yet started.
    function setEntryPrice(uint256 value) external onlyOwner {
        require(value > 0 && value <= MAX_ENTRY_PRICE, InvalidInput());
        entryPrice = value;
        emit EntryPriceSet(value);
    }

    /// @notice Mark `round` free or paid. Owner only, for a round above zero that has not started.
    function setFreeRound(uint256 round, bool free) external onlyOwner {
        require(round > 0 && !store.roundOf(round).started, InvalidState());
        freeRound[round] = free;
        emit FreeRoundSet(round, free);
    }

    /// @notice Release `amount` of the pool of `round`, which must not have started, to `to`. Owner only.
    function releaseSponsorship(uint256 round, address to, uint256 amount) external onlyOwner {
        store.releaseSponsorship(round, to, amount);
    }

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    /// @notice `round`'s entry price: the recorded one once it has started, otherwise zero when it is marked free
    ///         and entryPrice when not.
    function priceOf(uint256 round) public view returns (uint256) {
        if (store.roundOf(round).started) return store.roundOf(round).price;
        return freeRound[round] ? 0 : entryPrice;
    }

    /// @notice How many Normies would play round currentRound + 1 if it started now.
    function previewPlayers() external view returns (uint256) {
        uint256 round = store.currentRound() + 1;
        return freeRound[round] ? store.registeredCount() : store.countCovering(entryPrice);
    }

    /// @notice The latest round started. Zero before round 1.
    function currentRound() external view returns (uint256) {
        return store.currentRound();
    }

    /// @notice `round`'s pool: its sponsorship plus its entry fees.
    function poolOf(uint256 round) external view returns (uint256) {
        return store.poolOf(round);
    }

    // ──────────────────────────────────────────────
    //  Rounds (owner or operator)
    // ──────────────────────────────────────────────

    /// @notice Start `round` at priceOf(round). Owner or OPERATOR_ROLE, while running. `round` must be
    ///         currentRound + 1 and the current round ended or cancelled. A free round needs a pool, else it reverts
    ///         with FreeRoundNotSponsored.
    function startRound(uint256 round) external onlyOwnerOrRoles(OPERATOR_ROLE) whenRunning {
        bool free = freeRound[round];
        require(!free || store.poolOf(round) > 0, FreeRoundNotSponsored(round));
        store.startRound(round, free ? 0 : entryPrice, free);
    }

    /**
     * @notice Pay out part of the pool of open `round`: the round's price to each of `refundees`, then `amounts[i]`
     *         to each of `winners[i]`, all to Normie balances. Owner or OPERATOR_ROLE, while running. 1 to
     *         MAX_PAYOUT_ENTRIES entries. Reverts when the total exceeds the unpaid pool.
     */
    function payout(
        uint256 round,
        uint256[] calldata winners,
        uint256[] calldata amounts,
        uint256[] calldata refundees
    ) external onlyOwnerOrRoles(OPERATOR_ROLE) nonReentrant whenRunning {
        uint256 entries = _entries(winners, amounts, refundees);
        require(entries > 0, InvalidInput());
        store.payout(round, refundees, winners, amounts);
    }

    /// @notice Pay out the given lists like payout (they may be empty), then end open `round`, rolling what is left
    ///         of its pool into round + 1. Owner or OPERATOR_ROLE, while running.
    function endRound(
        uint256 round,
        uint256[] calldata winners,
        uint256[] calldata amounts,
        uint256[] calldata refundees
    ) external onlyOwnerOrRoles(OPERATOR_ROLE) nonReentrant whenRunning {
        if (_entries(winners, amounts, refundees) > 0) {
            store.payout(round, refundees, winners, amounts);
        }
        store.endRound(round);
    }

    /// @notice Cancel open `round`, rolling its unpaid pool into round + 1. Credits already made stay. Owner or
    ///         GUARDIAN_ROLE. Works while paused.
    function cancel(uint256 round) external onlyOwnerOrRoles(GUARDIAN_ROLE) nonReentrant {
        store.cancelRound(round);
    }

    /// @dev Checks the lists line up and fit MAX_PAYOUT_ENTRIES; returns the entry count.
    function _entries(
        uint256[] calldata winners,
        uint256[] calldata amounts,
        uint256[] calldata refundees
    ) private pure returns (uint256 entries) {
        entries = winners.length + refundees.length;
        require(winners.length == amounts.length && entries <= MAX_PAYOUT_ENTRIES, InvalidInput());
    }
}
