// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { NormiesAccess } from "./NormiesAccess.sol";
import { IDelegateRegistry } from "./interfaces/IDelegateRegistry.sol";
import { IDelegateRegistryV1 } from "./interfaces/IDelegateRegistryV1.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";

/// @notice The pixel ledger functions the Arena uses (NormiesCanvasStorageV2).
interface IArenaPixels {
    /// @notice Move `amount` wallet pixels from `from` to `to`. Callable by holders of a mover role.
    function moveBalance(address from, address to, uint256 amount) external;
    /// @notice Spend `amount` of the allowance `owner` gave `spender`. Callable by holders of a mover role.
    function useAllowance(address owner, address spender, uint256 amount) external;
    /// @notice Wallet pixel balance of `account`.
    function balanceOf(address account) external view returns (uint256);
}

/// @notice The Normies collection.
interface IArenaCollection {
    /// @notice Holder of Normie `id`. Reverts for an id that does not exist.
    function ownerOf(uint256 id) external view returns (address);
}

/// @notice The ERC-8004 identity adapter.
interface IArenaAdapter {
    /// @notice What agent `agentId` is bound to: a token standard (0 for ERC-721), a contract and a token id.
    function bindingOf(uint256 agentId) external view returns (uint8 standard, address boundAddress, uint256 tokenId);
}

/**
 * @title NormiesArenaStorage
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @notice State and custody for the Normies Arena: every Arena pixel, and the records of balances, the line, agent
 *         links, rounds and skin purchases. Authorized writers (the Arena logic contracts) change the records
 *         through the setters below, each one state change with its event. The game rules live in the logic.
 *
 *         Custody: every Arena pixel sits in this contract's wallet balance on the pixel ledger, either in a
 *         Normie's balance (totalAllocated) or in a round's unpaid pool (totalPooled). Balances are keyed by Normie
 *         id, so they follow the NFT. Every setter that brings pixels in checks that the ledger balance covers both
 *         totals.
 *
 *         Pixels leave only from this contract's own address: withdraw (a Normie's holder or a delegate, always
 *         paid to the holder), rescue (owner, a burned Normie's whole balance), sweep (owner, surplus only) and the
 *         writer setter releaseSponsorship. Needs a mover role on the pixel ledger.
 *
 *         Line: a first-in, first-out line of tickets. A Normie has one current ticket; any other ticket for it is
 *         stale and is skipped when taken from the head. Sixteen tickets share a storage slot, each holding a Normie
 *         id in 16 bits, so issuing a ticket mostly writes to a slot already in use.
 *
 *         Holders: a Normie's holder is collection.ownerOf(id). Its delegates are the accounts the holder delegated
 *         to on delegate.xyz (v2 or v1), at wallet, contract or token level. A Normie is burned when ownerOf
 *         reverts for an id below ID_BOUND, or returns DEAD (0x000000000000000000000000000000000000dEaD).
 *
 *         ETH or tokens sent to it by mistake can be recovered with solady's Lifebuoy: by the owner, and by the
 *         deployer until it locks its own access with lockRescue(1). The pixel ledger has no ERC-20 transfer, so
 *         Lifebuoy cannot move the pixels this contract holds; they leave only as described above.
 */
contract NormiesArenaStorage is NormiesAccess, ReentrancyGuard, Lifebuoy {
    /// @notice The caller is not an authorized writer.
    error NotAuthorized();
    /// @notice A malformed argument: a zero address or amount, an out-of-range id, or a bad batch.
    error InvalidInput();
    /// @notice The call is not allowed in the current state.
    error InvalidState();
    /// @notice The caller is neither the Normie's holder nor one of its delegates.
    error Forbidden();
    /// @notice The Normie is burned.
    error Burned();
    /// @notice The Normie is not burned.
    error NotBurned();
    /// @notice The ledger balance `balance` does not cover the `required` allocated and pooled pixels.
    error BackingShortfall(uint256 balance, uint256 required);

    /// @notice A Normie's place in the line.
    struct Enrollment {
        /// @dev The Normie's current ticket.
        uint64 ticket;
        /// @dev Whether the Normie is waiting in the line.
        bool active;
        /// @dev Whether it left the line only because its balance was below a round's price.
        bool needsFunds;
    }

    /// @notice A round's record.
    struct Round {
        /// @dev Sponsored pixels added to the round, including any moved in from a cancelled round.
        uint256 sponsorship;
        /// @dev Entry pixels charged to the round's players.
        uint256 fees;
        /// @dev The latest results hash posted for the round.
        bytes32 resultHash;
        /// @dev Admissions are closed.
        bool closed;
        bool settled;
        bool cancelled;
        bool started;
        bool finished;
        /// @dev The newest ticket when the round started. Higher tickets cannot be admitted to it.
        uint64 ticketCutoff;
        /// @dev Pixels of the pool not yet credited, moved or released.
        uint256 unpaid;
    }

    /// @notice A round's rules, recorded when it starts.
    struct Rules {
        /// @dev Most Normies admitted.
        uint32 capacity;
        /// @dev Share of players who win, in basis points.
        uint16 winnerBps;
        /// @dev Pixels charged per admission. Zero in a free round.
        uint64 price;
        /// @dev Whether the round is free.
        bool free;
        /// @dev Whether the rules have been recorded.
        bool fixed_;
    }

    /// @notice Normie ids are below this bound.
    uint256 public constant ID_BOUND = 10_000;
    /// @notice A Normie held by this address counts as burned.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice Most entries in one withdrawBatch.
    uint256 public constant MAX_WITHDRAW_BATCH = 100;

    /// @notice The pixel ledger holding this contract's pixels.
    IArenaPixels public immutable pixels;
    /// @notice The Normies collection.
    IArenaCollection public immutable collection;
    /// @notice delegate.xyz v2 registry.
    IDelegateRegistry public immutable delegateRegistry;
    /// @notice delegate.xyz v1 registry.
    IDelegateRegistryV1 public immutable delegateRegistryV1;
    /// @notice The ERC-8004 identity adapter that agent links are checked against. Set by the owner.
    IArenaAdapter public adapter;

    /// @notice Logic contracts allowed to call the writer setters.
    mapping(address => bool) public authorizedWriters;

    /// @notice Each Normie's balance.
    mapping(uint256 => uint256) public balanceOf;
    /// @notice Sum of all Normie balances.
    uint256 public totalAllocated;
    /// @notice Sum of every round's unpaid pool.
    uint256 public totalPooled;

    /// @notice Each Normie's place in the line.
    mapping(uint256 => Enrollment) public enrollment;
    /// @dev The line: ticket t's Normie id sits in bits [16 * (t % 16), 16 * (t % 16) + 16) of slot t / 16. A
    ///      taken ticket is left in place; tickets(t) reads only the tickets from head to tail.
    mapping(uint256 => uint256) private _line;
    /// @notice The oldest ticket not yet taken.
    uint64 public head = 1;
    /// @notice The newest ticket issued. Tickets are numbered from 1 in the order issued.
    uint64 public tail;

    /// @notice The agent each Normie is linked to.
    mapping(uint256 => uint256) public agentOf;
    /// @notice Whether a Normie has been linked to an agent.
    mapping(uint256 => bool) public agentBound;

    /// @notice The latest round started. Zero before round 1.
    uint256 public currentRound;

    /// @notice Each round's record, field by field (roundOf returns it as a struct).
    mapping(uint256 => Round) public games;
    /// @dev Each round's rules.
    mapping(uint256 => Rules) internal _rules;
    /// @dev Normies admitted to each round, in admission order.
    mapping(uint256 => uint256[]) internal _players;
    /// @notice Whether a Normie was admitted to a round.
    mapping(uint256 => mapping(uint256 => bool)) public played;

    /// @notice Skin purchases per Normie.
    mapping(uint256 => uint256) public purchased;
    /// @notice Skin purchases in total.
    uint256 public purchaseCount;

    /// @notice `writer` was authorized (`allowed`) or revoked.
    event AuthorizedWriterSet(address indexed writer, bool allowed);
    /// @notice The identity adapter was set to `adapter`.
    event AdapterSet(address indexed adapter);
    /// @notice `amount` surplus pixels were sent to `to`.
    event Swept(address indexed to, uint256 amount);
    /// @notice `amount` pixels from `from` were added to Normie `id`'s balance.
    event Deposited(uint256 indexed id, address indexed from, uint256 amount);
    /// @notice `amount` pixels of Normie `id`'s balance were paid to its holder `to`.
    event Withdrawn(uint256 indexed id, address indexed to, uint256 amount);
    /// @notice The whole balance of burned Normie `id`, `amount` pixels, was sent to `to`.
    event Rescued(uint256 indexed id, address indexed to, uint256 amount);
    /// @notice `amount` pixels of Normie `id`'s balance went into `round`'s pool as its entry price.
    event Charged(uint256 indexed round, uint256 indexed id, uint256 amount);
    /// @notice `amount` pixels of `round`'s pool were added to Normie `id`'s balance, as a prize or a refund.
    event Credited(uint256 indexed round, uint256 indexed id, uint256 amount);
    /// @notice `from` added `amount` pixels of sponsorship to `round`.
    event Sponsored(uint256 indexed round, address indexed from, uint256 amount);
    /// @notice `amount` unpaid pixels moved from round `from` to round `to` as sponsorship.
    event SponsorshipMoved(uint256 indexed from, uint256 indexed to, uint256 amount);
    /// @notice `amount` pixels of `round`'s sponsorship were paid out to `to`.
    event SponsorshipReleased(uint256 indexed round, address indexed to, uint256 amount);
    /// @notice Normie `id` took ticket `ticket` at the back of the line.
    event Enrolled(uint256 indexed id, uint64 ticket);
    /// @notice Normie `id` left the line; `needsFunds` is set when it left only for lack of funds.
    event EnrollmentPaused(uint256 indexed id, bool needsFunds);
    /// @notice Normie `id` was linked to agent `agentId`.
    event AgentLinked(uint256 indexed id, uint256 indexed agentId);
    /// @notice `round`'s rules were recorded.
    event RulesFixed(uint256 indexed round, uint256 capacity, uint256 price, uint256 winnerBps, bool free);
    /// @notice `round` started. Tickets up to `ticketCutoff` can be admitted to it. `at` is the block time, recorded
    ///         for readers only.
    event RoundStarted(uint256 indexed round, uint64 ticketCutoff, uint256 at);
    /// @notice Normie `id` was admitted to `round`.
    event Admitted(uint256 indexed round, uint256 indexed id);
    /// @notice Admissions to `round` closed with `participants` admitted.
    event AdmissionsClosed(uint256 indexed round, uint256 participants);
    /// @notice `round` finished with `players` admitted. `at` is the block time, recorded for readers only.
    event RoundFinished(uint256 indexed round, uint256 players, uint256 at);
    /// @notice `resultHash` was posted as `round`'s results.
    event ResultsPosted(uint256 indexed round, bytes32 indexed resultHash);
    /// @notice `round` was settled for results `resultHash`; its `pool` pixels went to the winners' balances.
    event Settled(uint256 indexed round, bytes32 indexed resultHash, uint256 pool);
    /// @notice `round` was cancelled: `refunded` entry pixels went back to the players' balances and its
    ///         sponsorship moved to round `carriedTo`.
    event Cancelled(uint256 indexed round, uint256 refunded, uint256 carriedTo);
    /// @notice Skin purchase `purchaseId` (numbered from 1) for Normie `id`, bought by `buyer` for `price` pixels.
    event SkinPurchased(uint256 indexed purchaseId, uint256 indexed id, address indexed buyer, uint256 price);

    /// @param pixels_     The pixel ledger.
    /// @param collection_ The Normies collection.
    /// @param adapter_    The ERC-8004 identity adapter.
    /// @param registry_   The delegate.xyz v2 registry.
    /// @param registryV1_ The delegate.xyz v1 registry.
    /// @param admin       The owner.
    constructor(
        address pixels_,
        address collection_,
        address adapter_,
        address registry_,
        address registryV1_,
        address admin
    ) {
        require(
            pixels_ != address(0) && collection_ != address(0) && adapter_ != address(0) && registry_ != address(0)
                && registryV1_ != address(0) && admin != address(0),
            InvalidInput()
        );
        pixels = IArenaPixels(pixels_);
        collection = IArenaCollection(collection_);
        adapter = IArenaAdapter(adapter_);
        delegateRegistry = IDelegateRegistry(registry_);
        delegateRegistryV1 = IDelegateRegistryV1(registryV1_);
        _initializeOwner(admin);
    }

    /// @dev Reverts with NotAuthorized unless the caller is an authorized writer.
    modifier onlyWriter() {
        require(authorizedWriters[msg.sender], NotAuthorized());
        _;
    }

    // ──────────────────────────────────────────────
    //  Owner
    // ──────────────────────────────────────────────

    /// @notice Authorize or revoke a writer. Owner only. A writer can change every record and pool here and pay out
    ///         sponsorship. The owner is not a writer unless it authorizes itself.
    function setAuthorizedWriter(address writer, bool allowed) external onlyOwner {
        require(writer != address(0), InvalidInput());
        authorizedWriters[writer] = allowed;
        emit AuthorizedWriterSet(writer, allowed);
    }

    /// @notice Set the identity adapter. Owner only. Existing agent links stay recorded.
    function setAdapter(address value) external onlyOwner {
        require(value != address(0), InvalidInput());
        adapter = IArenaAdapter(value);
        emit AdapterSet(value);
    }

    /// @notice Send `amount` surplus pixels to `to`, such as pixels sent here by mistake. Owner only. `amount` must
    ///         not exceed surplus(), so a sweep cannot reach a balance or a pool.
    function sweep(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0) && amount > 0 && amount <= surplus(), InvalidInput());
        pixels.moveBalance(address(this), to, amount);
        emit Swept(to, amount);
    }

    /// @notice Send the whole balance of burned Normie `id` to `to`. Owner only. Reverts with NotBurned while the
    ///         Normie exists and with InvalidInput when its balance is zero. The only way a burned Normie's balance
    ///         leaves.
    function rescue(uint256 id, address to) external onlyOwner nonReentrant {
        require(isBurned(id), NotBurned());
        uint256 amount = balanceOf[id];
        require(to != address(0) && amount > 0, InvalidInput());
        balanceOf[id] = 0;
        totalAllocated -= amount;
        pixels.moveBalance(address(this), to, amount);
        emit Rescued(id, to, amount);
    }

    // ──────────────────────────────────────────────
    //  Withdrawals
    // ──────────────────────────────────────────────

    /// @notice Pay `amount` pixels of Normie `id`'s balance to the Normie's holder. The holder or one of its
    ///         delegates may call it, at any time; it has no pause and needs no logic contract. Reverts with Burned
    ///         for a burned Normie and with InvalidInput for zero or more than the balance. The ledger's cooldown
    ///         applies to the pixels arriving in the holder's wallet.
    function withdraw(uint256 id, uint256 amount) external nonReentrant {
        _withdraw(id, amount);
    }

    /// @notice withdraw for several Normies, up to MAX_WITHDRAW_BATCH. Reverts entirely if one entry fails.
    function withdrawBatch(uint256[] calldata ids, uint256[] calldata amounts) external nonReentrant {
        require(ids.length == amounts.length && ids.length > 0 && ids.length <= MAX_WITHDRAW_BATCH, InvalidInput());
        for (uint256 i; i < ids.length; ++i) {
            _withdraw(ids[i], amounts[i]);
        }
    }

    /// @dev Debits Normie `id` and pays its holder.
    function _withdraw(uint256 id, uint256 amount) private {
        address holder = holderFor(id, msg.sender);
        require(amount > 0 && balanceOf[id] >= amount, InvalidInput());
        balanceOf[id] -= amount;
        totalAllocated -= amount;
        pixels.moveBalance(address(this), holder, amount);
        emit Withdrawn(id, holder, amount);
    }

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    /**
     * @notice The holder of Normie `id`, if `account` is the holder or one of its delegates.
     * @dev Reverts with InvalidInput for an id at or above ID_BOUND, Burned for a burned Normie, and Forbidden for
     *      any other account. The delegate.xyz registries are read only for an account that is not the holder.
     */
    function holderFor(uint256 id, address account) public view returns (address holder) {
        require(id < ID_BOUND, InvalidInput());
        holder = _holder(id);
        require(holder != address(0), Burned());
        require(
            account == holder || delegateRegistry.checkDelegateForERC721(account, holder, address(collection), id, "")
                || delegateRegistryV1.checkDelegateForToken(account, holder, address(collection), id),
            Forbidden()
        );
    }

    /// @notice Whether Normie `id` is burned: an id below ID_BOUND for which collection.ownerOf reverts or returns
    ///         DEAD.
    function isBurned(uint256 id) public view returns (bool) {
        return id < ID_BOUND && _holder(id) == address(0);
    }

    /// @dev collection.ownerOf(id), or zero when it reverts or returns DEAD.
    function _holder(uint256 id) private view returns (address) {
        try collection.ownerOf(id) returns (address holder) {
            return holder == DEAD ? address(0) : holder;
        } catch {
            return address(0);
        }
    }

    /// @notice Pixels held beyond totalAllocated and totalPooled. Zero when there are none.
    function surplus() public view returns (uint256) {
        uint256 balance = pixels.balanceOf(address(this));
        uint256 required = totalAllocated + totalPooled;
        return balance > required ? balance - required : 0;
    }

    /// @notice `round`'s record.
    function roundOf(uint256 round) external view returns (Round memory) {
        return games[round];
    }

    /// @notice `round`'s recorded rules. All zero, with `fixed_` false, before the round starts.
    function rulesOf(uint256 round) external view returns (Rules memory) {
        return _rules[round];
    }

    /// @notice Normies admitted to `round`, in admission order.
    function players(uint256 round) external view returns (uint256[] memory) {
        return _players[round];
    }

    /// @notice Number of Normies admitted to `round`.
    function playerCount(uint256 round) external view returns (uint256) {
        return _players[round].length;
    }

    /// @notice `round`'s pool: its sponsorship plus its entry fees.
    function poolOf(uint256 round) external view returns (uint256) {
        return games[round].sponsorship + games[round].fees;
    }

    /// @notice Whether `round` has started and is neither finished nor cancelled.
    function isOpen(uint256 round) public view returns (bool) {
        Round storage r = games[round];
        return r.started && !r.finished && !r.cancelled;
    }

    /// @notice The Normie `ticket` is for while it is in the line (from head to tail). Zero for a ticket already
    ///         taken or not yet issued, which is also Normie #0's id: check head and tail to tell them apart.
    function tickets(uint64 ticket) public view returns (uint256) {
        if (ticket < head || ticket > tail) return 0;
        return _ticketAt(ticket);
    }

    /// @dev The id stored for `ticket`.
    function _ticketAt(uint64 ticket) private view returns (uint256) {
        return (_line[ticket >> 4] >> ((ticket & 15) << 4)) & 0xffff;
    }

    /// @notice Whether the line has no ticket `round` can admit: the line is empty or its head is past the round's
    ///         ticket cutoff. True for a round that has not started.
    function lineExhausted(uint256 round) public view returns (bool) {
        return head > tail || head > games[round].ticketCutoff;
    }

    // ──────────────────────────────────────────────
    //  Writers: balances and pools
    // ──────────────────────────────────────────────

    /// @notice Add `amount` pixels from `from` to Normie `id`'s balance. Writers only. The pixels must already be in
    ///         this contract's ledger balance, or the backing check reverts with BackingShortfall.
    function addBalance(uint256 id, address from, uint256 amount) external onlyWriter {
        require(id < ID_BOUND && amount > 0, InvalidInput());
        balanceOf[id] += amount;
        totalAllocated += amount;
        _checkBacking();
        emit Deposited(id, from, amount);
    }

    /// @notice Move `amount` pixels from Normie `id`'s balance into `round`'s pool as entry fees. Writers only, for
    ///         a started round that is neither settled nor cancelled. Reverts with InvalidState when the balance is
    ///         short.
    function chargeEntry(uint256 round, uint256 id, uint256 amount) external onlyWriter {
        Round storage r = games[round];
        require(r.started && !r.settled && !r.cancelled && balanceOf[id] >= amount, InvalidState());
        balanceOf[id] -= amount;
        totalAllocated -= amount;
        totalPooled += amount;
        r.fees += amount;
        r.unpaid += amount;
        emit Charged(round, id, amount);
    }

    /// @notice Move pixels from `round`'s unpaid pool into Normie balances, `amounts[i]` to `ids[i]`. Writers only,
    ///         for a round that is neither settled nor cancelled. Reverts with InvalidState when the amounts add up to
    ///         more than the unpaid pool.
    function creditFromPool(uint256 round, uint256[] calldata ids, uint256[] calldata amounts) external onlyWriter {
        Round storage r = games[round];
        require(!r.settled && !r.cancelled, InvalidState());
        require(ids.length == amounts.length, InvalidInput());
        uint256 total;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            require(id < ID_BOUND, InvalidInput());
            balanceOf[id] += amounts[i];
            total += amounts[i];
            emit Credited(round, id, amounts[i]);
        }
        require(total <= r.unpaid, InvalidState());
        r.unpaid -= total;
        totalPooled -= total;
        totalAllocated += total;
    }

    /// @notice Add `amount` pixels of sponsorship from `from` to `round`. Writers only, for a round above zero that
    ///         is neither settled nor cancelled. The pixels must already be in this contract's ledger balance.
    function addSponsorship(uint256 round, address from, uint256 amount) external onlyWriter {
        Round storage r = games[round];
        require(round > 0 && !r.settled && !r.cancelled, InvalidState());
        require(amount > 0, InvalidInput());
        r.sponsorship += amount;
        r.unpaid += amount;
        totalPooled += amount;
        _checkBacking();
        emit Sponsored(round, from, amount);
    }

    /// @notice Move `amount` unpaid pixels of round `from` to round `to` as sponsorship. Writers only. Neither round
    ///         may be settled or cancelled, and `to` must not have started.
    function moveSponsorship(uint256 from, uint256 to, uint256 amount) external onlyWriter {
        Round storage a = games[from];
        Round storage b = games[to];
        require(
            to > 0 && from != to && !a.settled && !a.cancelled && !b.started && !b.settled && !b.cancelled
                && amount <= a.unpaid,
            InvalidState()
        );
        a.unpaid -= amount;
        b.sponsorship += amount;
        b.unpaid += amount;
        emit SponsorshipMoved(from, to, amount);
    }

    /// @notice Pay `amount` of `round`'s sponsorship to `to`. Writers only, for a round that is neither settled nor
    ///         cancelled, up to both its sponsorship and its unpaid pool.
    function releaseSponsorship(uint256 round, address to, uint256 amount) external onlyWriter nonReentrant {
        Round storage r = games[round];
        require(!r.settled && !r.cancelled, InvalidState());
        require(to != address(0) && amount > 0 && amount <= r.sponsorship && amount <= r.unpaid, InvalidInput());
        r.sponsorship -= amount;
        r.unpaid -= amount;
        totalPooled -= amount;
        pixels.moveBalance(address(this), to, amount);
        emit SponsorshipReleased(round, to, amount);
    }

    // ──────────────────────────────────────────────
    //  Writers: rounds
    // ──────────────────────────────────────────────

    /// @notice Record `round`'s rules and mark them fixed. Writers only, before the round starts.
    function setRules(uint256 round, Rules calldata r) external onlyWriter {
        require(!games[round].started, InvalidState());
        _rules[round] =
            Rules({ capacity: r.capacity, winnerBps: r.winnerBps, price: r.price, free: r.free, fixed_: true });
        emit RulesFixed(round, r.capacity, r.price, r.winnerBps, r.free);
    }

    /// @notice Mark `round` started, make it currentRound and set its ticket cutoff to the newest ticket. Writers
    ///         only, once per round.
    function setStarted(uint256 round) external onlyWriter {
        Round storage r = games[round];
        require(round > 0 && !r.started, InvalidState());
        r.started = true;
        r.ticketCutoff = tail;
        currentRound = round;
        emit RoundStarted(round, tail, block.timestamp);
    }

    /// @notice Record Normie `id` as a player of `round`. Writers only, for a started round, once per Normie.
    function addPlayer(uint256 round, uint256 id) external onlyWriter {
        require(games[round].started && !played[round][id], InvalidState());
        played[round][id] = true;
        _players[round].push(id);
        emit Admitted(round, id);
    }

    /// @notice Close admissions to `round`. Writers only, once, for a started round.
    function setClosed(uint256 round) external onlyWriter {
        Round storage r = games[round];
        require(r.started && !r.closed, InvalidState());
        r.closed = true;
        emit AdmissionsClosed(round, _players[round].length);
    }

    /// @notice Mark `round` finished. Writers only, once, for a started round that is not cancelled.
    function setFinished(uint256 round) external onlyWriter {
        Round storage r = games[round];
        require(r.started && !r.finished && !r.cancelled, InvalidState());
        r.finished = true;
        emit RoundFinished(round, _players[round].length, block.timestamp);
    }

    /// @notice Record `resultHash` as `round`'s results, replacing any earlier hash. Writers only.
    function setResultHash(uint256 round, bytes32 resultHash) external onlyWriter {
        games[round].resultHash = resultHash;
        emit ResultsPosted(round, resultHash);
    }

    /// @notice Mark `round` settled. Writers only, once, for a started round whose whole pool has been credited
    ///         (unpaid is zero).
    function setSettled(uint256 round) external onlyWriter {
        Round storage r = games[round];
        require(r.started && !r.settled && !r.cancelled && r.unpaid == 0, InvalidState());
        r.settled = true;
        emit Settled(round, r.resultHash, r.sponsorship + r.fees);
    }

    /// @notice Mark `round` cancelled and closed, its sponsorship having moved to round `carriedTo`. Writers only,
    ///         once, for a started round whose whole pool has been refunded or moved (unpaid is zero).
    function setCancelled(uint256 round, uint256 carriedTo) external onlyWriter {
        Round storage r = games[round];
        require(r.started && !r.settled && !r.cancelled && r.unpaid == 0, InvalidState());
        r.cancelled = true;
        r.closed = true;
        emit Cancelled(round, r.fees, carriedTo);
    }

    // ──────────────────────────────────────────────
    //  Writers: line, links, skins
    // ──────────────────────────────────────────────

    /// @notice Give Normie `id` a new ticket at the back of the line and mark it active, clearing needsFunds. Its
    ///         earlier ticket, if any, stays in the line and is skipped when taken. Writers only.
    function pushTicket(uint256 id) external onlyWriter {
        require(id < ID_BOUND, InvalidInput());
        uint64 ticket = ++tail;
        uint256 shift = uint256(ticket & 15) << 4;
        uint256 key = ticket >> 4;
        // Ticket numbers only grow, so this ticket's 16 bits have never been written.
        _line[key] |= id << shift;
        enrollment[id] = Enrollment({ ticket: ticket, active: true, needsFunds: false });
        emit Enrolled(id, ticket);
    }

    /**
     * @notice Take the ticket at the head of the line, if `round` can admit it. Writers only.
     * @return found  False when the line is empty or its head was issued after `round` started; nothing is taken.
     * @return ticket The ticket taken.
     * @return id     The Normie the ticket is for.
     */
    function popTicket(uint256 round) external onlyWriter returns (bool found, uint64 ticket, uint256 id) {
        if (lineExhausted(round)) return (false, 0, 0);
        ticket = head++;
        id = _ticketAt(ticket);
        found = true;
    }

    /// @notice Take Normie `id` out of the line, recording whether it left only for lack of funds. Its ticket stays
    ///         in the line and is skipped when taken. Writers only.
    function deactivate(uint256 id, bool needsFunds_) external onlyWriter {
        Enrollment storage e = enrollment[id];
        e.active = false;
        e.needsFunds = needsFunds_;
        emit EnrollmentPaused(id, needsFunds_);
    }

    /// @notice Link Normie `id` to agent `agentId`, replacing any earlier link. Writers only.
    function linkAgent(uint256 id, uint256 agentId) external onlyWriter {
        require(id < ID_BOUND, InvalidInput());
        agentOf[id] = agentId;
        agentBound[id] = true;
        emit AgentLinked(id, agentId);
    }

    /// @notice Count a skin purchase of `price` pixels for Normie `id` by `buyer`. Writers only.
    function recordPurchase(uint256 id, address buyer, uint256 price) external onlyWriter {
        ++purchased[id];
        emit SkinPurchased(++purchaseCount, id, buyer, price);
    }

    // ──────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────

    /// @dev Reverts with BackingShortfall unless the ledger balance covers totalAllocated plus totalPooled.
    function _checkBacking() private view {
        uint256 balance = pixels.balanceOf(address(this));
        uint256 required = totalAllocated + totalPooled;
        require(balance >= required, BackingShortfall(balance, required));
    }
}
