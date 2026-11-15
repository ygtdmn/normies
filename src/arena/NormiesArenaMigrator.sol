// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { NormiesAccess } from "../NormiesAccess.sol";
import { NormiesArenaStorage, IArenaPixels } from "../NormiesArenaStorage.sol";

/// @notice The Arena v2 storage functions the migration reads and writes.
interface ILegacyArenaStorage {
    struct Round {
        uint256 sponsorship;
        uint256 fees;
        bytes32 resultHash;
        bool closed;
        bool settled;
        bool cancelled;
        bool started;
        bool finished;
        uint64 ticketCutoff;
        uint256 unpaid;
    }

    function pixels() external view returns (address);
    function collection() external view returns (address);
    function currentRound() external view returns (uint256);
    function totalAllocated() external view returns (uint256);
    function totalPooled() external view returns (uint256);
    function balanceOf(uint256 id) external view returns (uint256);
    function roundOf(uint256 round) external view returns (Round memory);
    function head() external view returns (uint64);
    function tail() external view returns (uint64);
    function tickets(uint64 ticket) external view returns (uint256);
    function agentBound(uint256 id) external view returns (bool);
    function agentOf(uint256 id) external view returns (uint256);
    function purchased(uint256 id) external view returns (uint256);
    function purchaseCount() external view returns (uint256);
    function isBurned(uint256 id) external view returns (bool);
    function setStarted(uint256 round) external;
    function setFinished(uint256 round) external;
    function chargeEntry(uint256 round, uint256 id, uint256 amount) external;
    function moveSponsorship(uint256 from, uint256 to, uint256 amount) external;
    function releaseSponsorship(uint256 round, address to, uint256 amount) external;
}

/**
 * @title NormiesArenaMigrator
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @notice One-off move of the Arena v2 storage (line based, no round played) into the v3 storage. It must be an
 *         authorized writer of both, and the v2 logic contracts must be revoked as writers first so nothing changes
 *         underneath it. Every value it moves is read from the v2 storage; callers pass only which ids and how
 *         many tickets to process.
 *
 *         1. moveFunds: pays every v2 pool and balance into the v3 storage and books them there under the same
 *            rounds and Normie ids. Balances arrive unregistered; registerTickets registers the Normies in line.
 *            v2 can release only sponsorship, so balances go through round 1: charged as its entry fees, moved to
 *            round 2's sponsorship and released from there. v2 is left with round 1 started and finished, every
 *            balance and pool at zero.
 *         2. registerTickets: walks the v2 line from ticket 1 and registers each Normie that holds a ticket (once,
 *            whether it is still waiting or not), copying its agent link. Burned Normies are skipped.
 *         3. copyPurchases: copies skin purchase counts.
 *         4. finish: checks everything moved and locks the contract.
 *
 *         Owner or OPERATOR_ROLE.
 */
contract NormiesArenaMigrator is NormiesAccess {
    /// @notice Role that may run the migration (_ROLE_3, value 8).
    uint256 public constant OPERATOR_ROLE = _ROLE_3;

    /// @notice A malformed argument.
    error InvalidInput();
    /// @notice The call is not allowed in the current state.
    error InvalidState();
    /// @notice A check of the moved values failed.
    error Mismatch();

    /// @notice The v2 storage.
    ILegacyArenaStorage public immutable legacy;
    /// @notice The v3 storage.
    NormiesArenaStorage public immutable store;
    /// @notice The pixel ledger both use.
    IArenaPixels public immutable pixels;

    /// @notice Whether moveFunds ran.
    bool public fundsMoved;
    /// @notice Next v2 ticket registerTickets reads; zero before the first call.
    uint256 public nextTicket;
    /// @notice Whether finish ran. Every step reverts afterwards.
    bool public finished;

    /// @notice moveFunds moved `balances` pixels of Normie balances and `pools` pixels of round pools.
    event FundsMoved(uint256 balances, uint256 pools);
    /// @notice registerTickets read tickets up to `lastTicket` and registered `registered` Normies.
    event TicketsRegistered(uint256 lastTicket, uint256 registered);
    /// @notice The migration was finished.
    event Finished();

    /// @param legacy_ The v2 storage.
    /// @param store_  The v3 storage.
    /// @param admin   The owner.
    constructor(address legacy_, address store_, address admin) {
        require(legacy_ != address(0) && store_ != address(0) && admin != address(0), InvalidInput());
        legacy = ILegacyArenaStorage(legacy_);
        store = NormiesArenaStorage(store_);
        pixels = NormiesArenaStorage(store_).pixels();
        require(
            ILegacyArenaStorage(legacy_).pixels() == address(pixels)
                && ILegacyArenaStorage(legacy_).collection() == address(NormiesArenaStorage(store_).collection()),
            InvalidInput()
        );
        _initializeOwner(admin);
    }

    /// @dev Reverts once finished.
    modifier open() {
        require(!finished, InvalidState());
        _;
    }

    /**
     * @notice Move every v2 balance and pool into the v3 storage. Runs once. `ids` must be strictly increasing and
     *         hold every Normie with a v2 balance (their sum must equal v2 totalAllocated); `lastRound` must cover
     *         every v2 round with a pool (their sum must equal v2 totalPooled). v2 must not have started a round.
     */
    function moveFunds(uint256[] calldata ids, uint256 lastRound) external onlyOwnerOrRoles(OPERATOR_ROLE) open {
        require(!fundsMoved && legacy.currentRound() == 0 && lastRound > 0, InvalidState());
        uint256[] memory balances = new uint256[](ids.length);
        uint256 totalBalances;
        for (uint256 i; i < ids.length; ++i) {
            require(i == 0 || ids[i] > ids[i - 1], InvalidInput());
            balances[i] = legacy.balanceOf(ids[i]);
            totalBalances += balances[i];
        }
        require(totalBalances == legacy.totalAllocated(), Mismatch());
        uint256[] memory pools = new uint256[](lastRound + 1);
        uint256 totalPools;
        for (uint256 r = 1; r <= lastRound; ++r) {
            ILegacyArenaStorage.Round memory g = legacy.roundOf(r);
            require(!g.started && g.unpaid == g.sponsorship, Mismatch());
            pools[r] = g.unpaid;
            totalPools += g.unpaid;
        }
        require(totalPools == legacy.totalPooled(), Mismatch());

        uint256 before = pixels.balanceOf(address(store));
        for (uint256 r = 1; r <= lastRound; ++r) {
            if (pools[r] != 0) legacy.releaseSponsorship(r, address(store), pools[r]);
        }
        if (totalBalances != 0) {
            legacy.setStarted(1);
            for (uint256 i; i < ids.length; ++i) {
                if (balances[i] != 0) legacy.chargeEntry(1, ids[i], balances[i]);
            }
            legacy.moveSponsorship(1, 2, totalBalances);
            legacy.releaseSponsorship(2, address(store), totalBalances);
            legacy.setFinished(1);
        }
        require(legacy.totalAllocated() == 0 && legacy.totalPooled() == 0, Mismatch());
        require(pixels.balanceOf(address(store)) == before + totalBalances + totalPools, Mismatch());

        for (uint256 r = 1; r <= lastRound; ++r) {
            if (pools[r] != 0) store.addSponsorship(r, address(legacy), pools[r]);
        }
        for (uint256 i; i < ids.length; ++i) {
            if (balances[i] == 0) continue;
            store.deposit(ids[i], address(legacy), balances[i], false);
            _copyLink(ids[i]);
        }
        fundsMoved = true;
        emit FundsMoved(totalBalances, totalPools);
    }

    /// @notice Register the Normies behind the next `count` v2 tickets, from ticket 1 to tail, each once. The v2
    ///         line must never have been taken from (head 1).
    function registerTickets(uint256 count) external onlyOwnerOrRoles(OPERATOR_ROLE) open {
        require(count > 0, InvalidInput());
        uint256 t = nextTicket;
        if (t == 0) {
            require(legacy.head() == 1, InvalidState());
            t = 1;
        }
        uint256 tail = legacy.tail();
        uint256 end = t + count;
        if (end > tail + 1) end = tail + 1;
        uint256 registered;
        for (; t < end; ++t) {
            uint256 id = legacy.tickets(uint64(t));
            if (store.isRegistered(id) || store.isBurned(id)) continue;
            store.register(id);
            _copyLink(id);
            ++registered;
        }
        nextTicket = t;
        emit TicketsRegistered(t - 1, registered);
    }

    /// @notice Copy the v2 skin purchase counts of `ids`.
    function copyPurchases(uint256[] calldata ids) external onlyOwnerOrRoles(OPERATOR_ROLE) open {
        for (uint256 i; i < ids.length; ++i) {
            store.importPurchases(ids[i], legacy.purchased(ids[i]));
        }
    }

    /// @notice Check that every pool, balance, ticket and purchase moved, then lock the contract.
    function finish() external onlyOwnerOrRoles(OPERATOR_ROLE) open {
        require(fundsMoved && nextTicket > legacy.tail(), InvalidState());
        require(
            store.purchaseCount() == legacy.purchaseCount() && legacy.totalAllocated() == 0
                && legacy.totalPooled() == 0,
            Mismatch()
        );
        finished = true;
        emit Finished();
    }

    /// @dev Copies Normie `id`'s v2 agent link, if it has one and v3 has none.
    function _copyLink(uint256 id) private {
        if (legacy.agentBound(id) && !store.agentBound(id)) store.linkAgent(id, legacy.agentOf(id));
    }
}
