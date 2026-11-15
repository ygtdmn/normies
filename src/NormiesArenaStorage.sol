// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { NormiesAccess } from "./NormiesAccess.sol";
import { IDelegateRegistry } from "./interfaces/IDelegateRegistry.sol";
import { IDelegateRegistryV1 } from "./interfaces/IDelegateRegistryV1.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";

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
 * @notice State and custody for the Normies Arena: every Arena pixel, each Normie's balance, registrations, agent
 *         links, rounds and skin purchases. Authorized writers (the Arena logic contracts) change the records through
 *         the setters below. The game rules live in the logic contracts.
 *
 *         Lazy charging. There is no line and no admission. A paid round is played by every active Normie (registered,
 *         not short) whose balance covers its price when it starts, and charging them writes nothing per Normie. The
 *         storage keeps the running total C of the prices of all started rounds (cumulativeAt) and, for each Normie, a
 *         level L = balance + C at its last change. A registered Normie is active while L >= C: its balance is L - C.
 *         Starting a paid round at price p raises C by p. Active Normies with L < C + p cannot cover it: they sit out
 *         ("short") and keep their leftover L - C, and the round's players are the active Normies left. To count the
 *         Normies that drop out, active Normies are counted per level in 16-bit lanes, sixteen to a slot; only lanes at
 *         or above C are live, since C never decreases and every live level is at or above it. A short Normie plays
 *         again after any top-up or credit. A free round charges nothing and is played by every registered Normie,
 *         short or not.
 *
 *         A Normie that joins or tops up while a round is open is written at the current C, which already includes
 *         that round's price, so it neither pays for nor plays that round.
 *
 *         Normie states: unregistered (may hold a balance credited to it, frozen), active, short (frozen leftover),
 *         cleared (burned and taken out by clear; frozen balance, which only rescue moves). Only the queue registers
 *         a Normie, for its holder or a delegate; nothing registers one on anyone's behalf.
 *
 *         Custody: every Arena pixel sits in this contract's wallet balance on the pixel ledger, either in a
 *         Normie's balance (totalAllocated, always the exact sum of balanceOf) or in a round's unpaid pool
 *         (totalPooled). Pixels leave only from this contract's own address: withdraw (a Normie's holder or a
 *         delegate, paid to the holder), rescue (owner, a burned Normie's balance), sweep (owner, surplus only) and
 *         the writer setter releaseSponsorship.
 *
 *         Holders: a Normie's holder is collection.ownerOf(id). Its delegates are the accounts the holder delegated
 *         to on delegate.xyz (v2 or v1), at wallet, contract or token level. A Normie is burned when ownerOf
 *         reverts for an id below ID_BOUND, or returns DEAD (0x000000000000000000000000000000000000dEaD).
 *
 *         ETH or tokens sent to it by mistake can be recovered with solady's Lifebuoy: by the owner, and by the
 *         deployer until it locks its own access with lockRescue(1). The pixel ledger has no ERC-20 transfer, so
 *         Lifebuoy cannot move the pixels this contract holds.
 */
contract NormiesArenaStorage is NormiesAccess, ReentrancyGuard, Lifebuoy {
    using SafeCastLib for uint256;

    /// @notice The caller is not an authorized writer.
    error NotAuthorized();
    /// @notice A malformed argument: a zero address or amount, an out-of-range id or price, or a bad batch.
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

    /// @notice A Normie's record. One slot.
    struct Normie {
        /// @dev Active: balance + C at the last change. Any other state: the balance itself.
        uint64 level;
        /// @dev currentRound at the last change.
        uint32 checkpoint;
        /// @dev Registered by its holder (join or deposit) and not cleared.
        bool registered;
        /// @dev Burned and taken out by clear. Final.
        bool cleared;
        /// @dev Registered but sat out a paid round it could not cover; `level` is its leftover balance.
        bool short_;
        /// @dev Whether it played round `checkpoint`.
        bool inRound;
        /// @dev Linked to an agent (agentOf).
        bool linked;
    }

    /// @notice A round's record.
    struct Round {
        /// @dev Sponsored pixels, including any rolled in from the previous round.
        uint128 sponsorship;
        /// @dev Entry pixels charged when the round started: players * price.
        uint128 fees;
        /// @dev Pixels of the pool not yet credited, rolled forward or released.
        uint128 unpaid;
        /// @dev Pixels credited from the pool so far.
        uint128 paid;
        /// @dev C after the round started.
        uint64 cumulative;
        /// @dev Players when it started.
        uint32 players;
        /// @dev Entry price; zero for a free round.
        uint16 price;
        bool free;
        bool started;
        bool ended;
        bool cancelled;
    }

    /// @notice The global counters. One slot.
    struct Globals {
        /// @dev C: the sum of the prices of every started round.
        uint64 cumulative;
        /// @dev The latest round started. Zero before round 1.
        uint32 currentRound;
        /// @dev Registered Normies (not cleared).
        uint32 registeredCount;
        /// @dev Active Normies: registered, not short, level >= C.
        uint32 activeCount;
        /// @dev Whether round currentRound is free.
        bool currentFree;
    }

    /// @notice Normie states reported in Leveled.
    uint8 public constant STATE_UNREGISTERED = 0;
    uint8 public constant STATE_ACTIVE = 1;
    uint8 public constant STATE_SHORT = 2;
    uint8 public constant STATE_CLEARED = 3;

    /// @notice Normie ids are below this bound.
    uint256 public constant ID_BOUND = 10_000;
    /// @notice A Normie held by this address counts as burned.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice Highest entry price of a round. Bounds the lanes startRound reads.
    uint256 public constant MAX_PRICE = 10_000;
    /// @notice Most entries in one withdrawBatch or clearBatch. Measured on the real ledger after 520 rounds (half the
    ///         entries lazily short, fresh holders): withdrawBatch 10.3M gas. A short Normie's leftover search grows by
    ///         one storage read each time the number of rounds doubles.
    uint256 public constant MAX_BATCH = 100;

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
    /// @notice Sum of all Normie balances.
    uint128 public totalAllocated;
    /// @notice Sum of every round's unpaid pool.
    uint128 public totalPooled;
    /// @dev The global counters.
    Globals internal _g;
    /// @dev Each Normie's record.
    mapping(uint256 => Normie) internal _normies;
    /// @dev Active Normies per level: level l is the 16-bit lane l % 16 of slot l / 16.
    mapping(uint256 => uint256) internal _lanes;
    /// @dev Each round's record.
    mapping(uint256 => Round) internal _rounds;
    /// @notice The agent each Normie is linked to.
    mapping(uint256 => uint256) public agentOf;
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
    /// @notice Normie `id` was registered during round `round` (it plays from the next round started).
    event Registered(uint256 indexed id, uint256 round);
    /// @notice `amount` pixels from `from` were added to Normie `id`'s balance.
    event Deposited(uint256 indexed id, address indexed from, uint256 amount);
    /// @notice `amount` pixels of Normie `id`'s balance were paid to its holder `to`.
    event Withdrawn(uint256 indexed id, address indexed to, uint256 amount);
    /// @notice `amount` pixels of `round`'s pool were added to Normie `id`'s balance, as a refund or a prize.
    event Credited(uint256 indexed round, uint256 indexed id, uint256 amount, bool refund);
    /// @notice Burned Normie `id` was taken out of the game with `balance` pixels left.
    event Cleared(uint256 indexed id, uint256 balance);
    /// @notice The balance of burned Normie `id`, `amount` pixels, was sent to `to`.
    event Rescued(uint256 indexed id, address indexed to, uint256 amount);
    /// @notice Normie `id`'s record after a change: its balance, its level and its state (STATE_*). An active
    ///         Normie's balance falls by each later paid round's price while level >= C; readers derive charges and
    ///         drop-outs from RoundStarted.
    event Leveled(uint256 indexed id, uint256 balance, uint256 level, uint8 state);
    /// @notice `from` added `amount` pixels of sponsorship to `round`.
    event Sponsored(uint256 indexed round, address indexed from, uint256 amount);
    /// @notice `amount` unpaid pixels moved from round `from` to round `to` as sponsorship.
    event SponsorshipMoved(uint256 indexed from, uint256 indexed to, uint256 amount);
    /// @notice `amount` pixels of `round`'s pool were paid out to `to`.
    event SponsorshipReleased(uint256 indexed round, address indexed to, uint256 amount);
    /// @notice Normie `id` was linked to agent `agentId`.
    event AgentLinked(uint256 indexed id, uint256 indexed agentId);
    /// @notice `round` started at `price` (zero when free) with `players` players, charging `fees` pixels in total.
    ///         C is now `cumulative`. `at` is the block time, recorded for readers only.
    event RoundStarted(
        uint256 indexed round, uint256 price, bool free, uint256 players, uint256 fees, uint256 cumulative, uint256 at
    );
    /// @notice `round` ended: `paid` pixels were credited from its pool and `rolled` moved to the next round.
    event RoundEnded(uint256 indexed round, uint256 paid, uint256 rolled, uint256 at);
    /// @notice `round` was cancelled: `paid` pixels had been credited and `rolled` moved to the next round.
    event RoundCancelled(uint256 indexed round, uint256 paid, uint256 rolled, uint256 at);
    /// @notice Skin purchase `purchaseId` (numbered from 1) for Normie `id`, bought by `buyer` for `price` pixels.
    event SkinPurchased(uint256 indexed purchaseId, uint256 indexed id, address indexed buyer, uint256 price);
    /// @notice Normie `id`'s skin purchase count was imported as `count`.
    event PurchasesImported(uint256 indexed id, uint256 count);

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
    ///         unstarted pools. The owner is not a writer unless it authorizes itself.
    function setAuthorizedWriter(address writer, bool allowed) external onlyOwner {
        require(writer != address(0), InvalidInput());
        authorizedWriters[writer] = allowed;
        emit AuthorizedWriterSet(writer, allowed);
    }

    /// @notice Set the identity adapter. Owner only.
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

    /// @notice Send the whole balance of burned Normie `id` to `to`, clearing it first if needed. Owner only.
    ///         Reverts with NotBurned while the Normie exists and with InvalidInput when its balance is zero. The
    ///         only way a burned Normie's balance leaves.
    function rescue(uint256 id, address to) external onlyOwner nonReentrant {
        require(to != address(0), InvalidInput());
        require(isBurned(id), NotBurned());
        Globals memory g = _g;
        Normie memory n = _sync(id, g);
        if (!n.cleared) _clear(id, n, g);
        uint256 amount = n.level;
        require(amount > 0, InvalidInput());
        n.level = 0;
        totalAllocated -= uint128(amount);
        _save(id, n, g);
        _g = g;
        pixels.moveBalance(address(this), to, amount);
        emit Rescued(id, to, amount);
    }

    // ──────────────────────────────────────────────
    //  Permissionless
    // ──────────────────────────────────────────────

    /// @notice Pay `amount` pixels of Normie `id`'s balance to the Normie's holder. The holder or one of its
    ///         delegates may call it, at any time; it has no pause and needs no logic contract. Reverts with Burned
    ///         for a burned Normie and with InvalidInput for zero or more than the balance. A Normie that withdraws
    ///         below the next price sits out until a top-up or a credit.
    function withdraw(uint256 id, uint256 amount) external nonReentrant {
        _withdraw(id, amount, _g);
    }

    /// @notice withdraw for several Normies, up to MAX_BATCH. Reverts entirely if one entry fails.
    function withdrawBatch(uint256[] calldata ids, uint256[] calldata amounts) external nonReentrant {
        require(ids.length == amounts.length && ids.length > 0 && ids.length <= MAX_BATCH, InvalidInput());
        Globals memory g = _g;
        for (uint256 i; i < ids.length; ++i) {
            _withdraw(ids[i], amounts[i], g);
        }
    }

    /// @notice Take burned Normie `id` out of the game: it stops counting as a player, and its balance stays here
    ///         for rescue. Anyone, at any time. Reverts with NotBurned while it exists and with InvalidState when it
    ///         was already cleared.
    function clear(uint256 id) external {
        Globals memory g = _g;
        _clearOne(id, g);
        _g = g;
    }

    /// @notice clear for several Normies, up to MAX_BATCH. Reverts entirely if one entry fails.
    function clearBatch(uint256[] calldata ids) external {
        require(ids.length > 0 && ids.length <= MAX_BATCH, InvalidInput());
        Globals memory g = _g;
        for (uint256 i; i < ids.length; ++i) {
            _clearOne(ids[i], g);
        }
        _g = g;
    }

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    /// @notice The holder of Normie `id` when `account` is that holder or one of its delegates. Reverts with
    ///         Burned for a burned Normie, with Forbidden for any other account. The delegate.xyz registries are read
    ///         only for an account that is not the holder.
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

    /// @notice Whether Normie `id` is burned: ownerOf reverts or returns DEAD. False for ids at or above ID_BOUND.
    function isBurned(uint256 id) public view returns (bool) {
        return id < ID_BOUND && _holder(id) == address(0);
    }

    /// @notice Ledger pixels here beyond every balance and unpaid pool.
    function surplus() public view returns (uint256) {
        uint256 balance = pixels.balanceOf(address(this));
        uint256 required = uint256(totalAllocated) + totalPooled;
        return balance > required ? balance - required : 0;
    }

    /// @notice Normie `id`'s balance now.
    function balanceOf(uint256 id) external view returns (uint256) {
        Globals memory g = _g;
        Normie memory n = _sync(id, g);
        return _balance(n, g);
    }

    /// @notice Normie `id`'s state now (STATE_*).
    function stateOf(uint256 id) external view returns (uint8) {
        return _state(_sync(id, _g));
    }

    /// @notice Normie `id`'s record as stored. Its level may predate later rounds; use balanceOf and stateOf.
    function normieOf(uint256 id) external view returns (Normie memory) {
        return _normies[id];
    }

    /// @notice Whether Normie `id` is registered (and not cleared).
    function isRegistered(uint256 id) external view returns (bool) {
        return _normies[id].registered;
    }

    /// @notice Whether Normie `id` is linked to an agent.
    function agentBound(uint256 id) external view returns (bool) {
        return _normies[id].linked;
    }

    /// @notice Whether Normie `id` played round currentRound (or is playing it). False before round 1.
    function isPlayer(uint256 id) external view returns (bool) {
        Globals memory g = _g;
        Normie memory n = _normies[id];
        if (g.currentRound == 0) return false;
        if (n.checkpoint == g.currentRound) return n.inRound;
        return n.registered && (g.currentFree || (!n.short_ && n.level >= g.cumulative));
    }

    /// @notice How many Normies would play a paid round started now at `price`.
    function countCovering(uint256 price) external view returns (uint256) {
        require(price <= MAX_PRICE, InvalidInput());
        Globals memory g = _g;
        return g.activeCount - _countRange(g.cumulative, uint256(g.cumulative) + price);
    }

    /// @notice C: the sum of the prices of every started round.
    function cumulative() external view returns (uint256) {
        return _g.cumulative;
    }

    /// @notice C after `round` started; zero for round 0. Only meaningful for started rounds.
    function cumulativeAt(uint256 round) public view returns (uint256) {
        return round == 0 ? 0 : _rounds[round].cumulative;
    }

    /// @notice The latest round started. Zero before round 1.
    function currentRound() external view returns (uint256) {
        return _g.currentRound;
    }

    /// @notice Whether round currentRound is free.
    function currentFree() external view returns (bool) {
        return _g.currentFree;
    }

    /// @notice Registered Normies (not cleared): the players of a free round started now.
    function registeredCount() external view returns (uint256) {
        return _g.registeredCount;
    }

    /// @notice Active Normies: registered, not short, with a balance at least as high as the last paid price left.
    function activeCount() external view returns (uint256) {
        return _g.activeCount;
    }

    /// @notice `round`'s record.
    function roundOf(uint256 round) external view returns (Round memory) {
        return _rounds[round];
    }

    /// @notice `round`'s pool: its sponsorship plus its entry fees.
    function poolOf(uint256 round) external view returns (uint256) {
        return uint256(_rounds[round].sponsorship) + _rounds[round].fees;
    }

    /// @notice Whether `round` has started and is neither ended nor cancelled.
    function isOpen(uint256 round) public view returns (bool) {
        Round storage r = _rounds[round];
        return r.started && !r.ended && !r.cancelled;
    }

    // ──────────────────────────────────────────────
    //  Writers: Normies
    // ──────────────────────────────────────────────

    /// @notice Register Normie `id`: it plays every free round and, while active with a balance that covers the
    ///         price, every paid round, from the next round started. A balance credited to it while unregistered
    ///         comes with it. Writers only (the queue checks holder and agent link). Reverts with InvalidState
    ///         when it is already registered or cleared.
    function register(uint256 id) external onlyWriter {
        require(id < ID_BOUND, InvalidInput());
        Globals memory g = _g;
        Normie memory n = _sync(id, g);
        require(!n.registered && !n.cleared, InvalidState());
        _register(id, n, g, 0);
        _save(id, n, g);
        _g = g;
    }

    /// @notice Add `amount` pixels from `from` to Normie `id`'s balance. Writers only. With `register_`, an
    ///         unregistered Normie is registered too; without it, it keeps the pixels unregistered (migration). A
    ///         short Normie plays again from the next round. The pixels must already be in this contract's ledger
    ///         balance, or the backing check reverts with BackingShortfall. Reverts with InvalidState for a cleared
    ///         Normie.
    function deposit(uint256 id, address from, uint256 amount, bool register_) external onlyWriter {
        require(id < ID_BOUND && amount > 0, InvalidInput());
        Globals memory g = _g;
        Normie memory n = _sync(id, g);
        require(!n.cleared, InvalidState());
        if (!n.registered && register_) _register(id, n, g, amount);
        else _add(n, g, amount);
        totalAllocated += amount.toUint128();
        _checkBacking();
        emit Deposited(id, from, amount);
        _save(id, n, g);
        _g = g;
    }

    /// @notice Link Normie `id` to agent `agentId`. Writers only.
    function linkAgent(uint256 id, uint256 agentId) external onlyWriter {
        require(id < ID_BOUND, InvalidInput());
        agentOf[id] = agentId;
        _normies[id].linked = true;
        emit AgentLinked(id, agentId);
    }

    // ──────────────────────────────────────────────
    //  Writers: pools
    // ──────────────────────────────────────────────

    /// @notice Add `amount` pixels from `from` to `round`'s pool. Writers only, for a round above zero that is
    ///         neither ended nor cancelled. The pixels must already be in this contract's ledger balance.
    function addSponsorship(uint256 round, address from, uint256 amount) external onlyWriter {
        Round storage r = _rounds[round];
        require(round > 0 && !r.ended && !r.cancelled, InvalidState());
        require(amount > 0, InvalidInput());
        uint128 a = amount.toUint128();
        r.sponsorship += a;
        r.unpaid += a;
        totalPooled += a;
        _checkBacking();
        emit Sponsored(round, from, amount);
    }

    /// @notice Pay `amount` pixels of the pool of `round`, which has not started, to `to`. Writers only.
    function releaseSponsorship(uint256 round, address to, uint256 amount) external onlyWriter nonReentrant {
        Round storage r = _rounds[round];
        require(!r.started, InvalidState());
        require(to != address(0) && amount > 0 && amount <= r.unpaid, InvalidInput());
        uint128 a = uint128(amount);
        r.sponsorship -= a;
        r.unpaid -= a;
        totalPooled -= a;
        pixels.moveBalance(address(this), to, amount);
        emit SponsorshipReleased(round, to, amount);
    }

    // ──────────────────────────────────────────────
    //  Writers: rounds
    // ──────────────────────────────────────────────

    /**
     * @notice Start `round` at `price`, or free. Writers only. `round` must be currentRound + 1, and the current
     *         round ended or cancelled. A paid round (price 1 to MAX_PRICE) is played by every active Normie whose
     *         balance covers the price, each charged the price; the others sit out. A free round (price 0) is
     *         played by every registered Normie and charges nothing.
     */
    function startRound(uint256 round, uint256 price, bool free) external onlyWriter {
        Globals memory g = _g;
        uint256 previous = g.currentRound;
        require(round == previous + 1, InvalidState());
        if (previous != 0) require(_rounds[previous].ended || _rounds[previous].cancelled, InvalidState());
        require(free ? price == 0 : price > 0 && price <= MAX_PRICE, InvalidInput());
        Round storage r = _rounds[round];
        uint256 players;
        uint256 fees;
        if (free) {
            players = g.registeredCount;
        } else {
            uint256 next = uint256(g.cumulative) + price;
            players = g.activeCount - _countRange(g.cumulative, next);
            fees = players * price;
            g.cumulative = next.toUint64();
            g.activeCount = uint32(players);
            totalAllocated -= uint128(fees);
            totalPooled += uint128(fees);
            r.fees = uint128(fees);
            r.unpaid += uint128(fees);
        }
        g.currentRound = uint32(round);
        g.currentFree = free;
        r.cumulative = g.cumulative;
        r.players = uint32(players);
        r.price = uint16(price);
        r.free = free;
        r.started = true;
        _g = g;
        emit RoundStarted(round, price, free, players, fees, g.cumulative, block.timestamp);
    }

    /**
     * @notice Credit from the pool of `round`, which must be open: first the round's price to each of `refundees`,
     *         then `amounts[i]` to each of `winners[i]`. Writers only. Reverts with InvalidState when the total
     *         exceeds the unpaid pool. Zero credits are skipped. A credit to a short Normie lets it play again; a
     *         credit to an unregistered Normie stays with it until its holder registers it.
     */
    function payout(
        uint256 round,
        uint256[] calldata refundees,
        uint256[] calldata winners,
        uint256[] calldata amounts
    ) external onlyWriter {
        require(winners.length == amounts.length, InvalidInput());
        Round storage r = _rounds[round];
        Globals memory g = _g;
        require(round == g.currentRound && isOpen(round), InvalidState());
        uint256 price = r.price;
        uint256 total;
        if (price != 0) {
            for (uint256 i; i < refundees.length; ++i) {
                _credit(round, refundees[i], price, true, g);
            }
            total = refundees.length * price;
        }
        for (uint256 i; i < winners.length; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            _credit(round, winners[i], amount, false, g);
            total += amount;
        }
        require(total <= r.unpaid, InvalidState());
        uint128 t = uint128(total);
        r.unpaid -= t;
        r.paid += t;
        totalPooled -= t;
        totalAllocated += t;
        _g = g;
    }

    /// @notice End `round`, which must be open, and roll its unpaid pool into round + 1. Writers only.
    function endRound(uint256 round) external onlyWriter {
        require(round == _g.currentRound && isOpen(round), InvalidState());
        _rounds[round].ended = true;
        uint256 rolled = _roll(round);
        emit RoundEnded(round, _rounds[round].paid, rolled, block.timestamp);
    }

    /// @notice Cancel `round`, which must be open, and roll its unpaid pool into round + 1. Credits already made
    ///         stay; nothing is refunded and C stays as it is. Writers only.
    function cancelRound(uint256 round) external onlyWriter {
        require(round == _g.currentRound && isOpen(round), InvalidState());
        _rounds[round].cancelled = true;
        uint256 rolled = _roll(round);
        emit RoundCancelled(round, _rounds[round].paid, rolled, block.timestamp);
    }

    // ──────────────────────────────────────────────
    //  Writers: skins
    // ──────────────────────────────────────────────

    /// @notice Record a skin purchase for Normie `id`. Writers only.
    function recordPurchase(uint256 id, address buyer, uint256 price) external onlyWriter {
        ++purchased[id];
        emit SkinPurchased(++purchaseCount, id, buyer, price);
    }

    /// @notice Set Normie `id`'s skin purchase count to `count` (migration). Writers only, before round 1.
    function importPurchases(uint256 id, uint256 count) external onlyWriter {
        require(_g.currentRound == 0, InvalidState());
        require(id < ID_BOUND, InvalidInput());
        purchaseCount = purchaseCount - purchased[id] + count;
        purchased[id] = count;
        emit PurchasesImported(id, count);
    }

    // ──────────────────────────────────────────────
    //  Internal: Normies
    // ──────────────────────────────────────────────

    /**
     * @dev Normie `id`'s record brought up to round currentRound, in memory: records whether it played that round,
     *      turns a Normie that dropped out of a paid round since its last change into a short one with its leftover
     *      balance, and moves its checkpoint to currentRound. After this an active Normie has level >= C, and
     *      every other state holds its balance in level.
     */
    function _sync(uint256 id, Globals memory g) internal view returns (Normie memory n) {
        n = _normies[id];
        uint256 checkpoint = n.checkpoint;
        if (checkpoint == g.currentRound) return n;
        // Nothing changed this Normie since before round currentRound started, so its level then is its level now.
        bool coveredNow = !n.short_ && n.level >= g.cumulative;
        n.inRound = n.registered && (g.currentFree || coveredNow);
        if (n.registered && !n.short_ && !coveredNow) {
            n.level = uint64(n.level - _cumulativeBefore(n.level, checkpoint, g.currentRound));
            n.short_ = true;
        }
        n.checkpoint = g.currentRound;
    }

    /// @dev C just before the round the Normie at `level` dropped out of: the highest cumulativeAt(r) <= level for
    ///      r in [low, high). cumulativeAt(low) <= level holds since the Normie was active at round `low`, and
    ///      cumulativeAt(high) > level since it is not active now.
    function _cumulativeBefore(uint256 level, uint256 low, uint256 high) internal view returns (uint256) {
        // Invariant: cumulativeAt(low) <= level < cumulativeAt(high).
        while (high - low > 1) {
            uint256 mid = (low + high) >> 1;
            if (_rounds[mid].cumulative <= level) low = mid;
            else high = mid;
        }
        return cumulativeAt(low);
    }

    /// @dev The balance of a record returned by _sync.
    function _balance(Normie memory n, Globals memory g) internal pure returns (uint256) {
        return n.registered && !n.short_ ? n.level - g.cumulative : n.level;
    }

    /// @dev The state of a record returned by _sync.
    function _state(Normie memory n) internal pure returns (uint8) {
        if (n.cleared) return STATE_CLEARED;
        if (!n.registered) return STATE_UNREGISTERED;
        return n.short_ ? STATE_SHORT : STATE_ACTIVE;
    }

    /// @dev Registers an unregistered record and makes it active with its frozen balance plus `amount`.
    function _register(uint256 id, Normie memory n, Globals memory g, uint256 amount) internal {
        n.registered = true;
        ++g.registeredCount;
        _activate(n, g, uint256(n.level) + amount);
        emit Registered(id, g.currentRound);
    }

    /// @dev Adds `amount` to a synced record's balance. A short Normie becomes active again.
    function _add(Normie memory n, Globals memory g, uint256 amount) internal {
        if (!n.registered) {
            n.level = (uint256(n.level) + amount).toUint64();
        } else if (n.short_) {
            _activate(n, g, uint256(n.level) + amount);
        } else {
            _move(n, uint256(n.level) + amount);
        }
    }

    /// @dev Makes a registered record active with `balance`.
    function _activate(Normie memory n, Globals memory g, uint256 balance) internal {
        n.short_ = false;
        n.level = (balance + g.cumulative).toUint64();
        _laneAdd(n.level);
        ++g.activeCount;
    }

    /// @dev Moves an active record to `level`.
    function _move(Normie memory n, uint256 level) internal {
        _laneSub(n.level);
        n.level = level.toUint64();
        _laneAdd(n.level);
    }

    /// @dev Pays `amount` of Normie `id`'s balance to its holder. Never changes the global counters, so callers
    ///      need not write `g` back.
    function _withdraw(uint256 id, uint256 amount, Globals memory g) internal {
        address holder = holderFor(id, msg.sender);
        Normie memory n = _sync(id, g);
        require(amount > 0 && amount <= _balance(n, g), InvalidInput());
        if (n.registered && !n.short_) _move(n, n.level - amount);
        else n.level -= uint64(amount);
        totalAllocated -= uint128(amount);
        _save(id, n, g);
        pixels.moveBalance(address(this), holder, amount);
        emit Withdrawn(id, holder, amount);
    }

    /// @dev Credits `amount` of `round`'s pool to Normie `id`. The pool totals are the caller's.
    function _credit(uint256 round, uint256 id, uint256 amount, bool refund, Globals memory g) internal {
        require(id < ID_BOUND, InvalidInput());
        Normie memory n = _sync(id, g);
        if (n.cleared) n.level = (uint256(n.level) + amount).toUint64();
        else _add(n, g, amount);
        emit Credited(round, id, amount, refund);
        _save(id, n, g);
    }

    /// @dev Clears burned Normie `id`.
    function _clearOne(uint256 id, Globals memory g) internal {
        require(isBurned(id), NotBurned());
        Normie memory n = _sync(id, g);
        require(!n.cleared, InvalidState());
        _clear(id, n, g);
        _save(id, n, g);
    }

    /// @dev Takes a synced record out of the game, freezing its balance in level.
    function _clear(uint256 id, Normie memory n, Globals memory g) internal {
        if (n.registered) {
            if (!n.short_) {
                _laneSub(n.level);
                --g.activeCount;
                n.level -= g.cumulative;
            }
            --g.registeredCount;
        }
        n.registered = false;
        n.short_ = false;
        n.cleared = true;
        emit Cleared(id, n.level);
    }

    /// @dev Writes a record and reports it.
    function _save(uint256 id, Normie memory n, Globals memory g) internal {
        _normies[id] = n;
        emit Leveled(id, _balance(n, g), n.level, _state(n));
    }

    // ──────────────────────────────────────────────
    //  Internal: lanes, pools
    // ──────────────────────────────────────────────

    /// @dev One more active Normie at `level`. Live lanes never exceed ID_BOUND, so a lane cannot overflow.
    function _laneAdd(uint256 level) internal {
        unchecked {
            _lanes[level >> 4] += uint256(1) << ((level & 15) << 4);
        }
    }

    /// @dev One fewer active Normie at `level`, which holds at least one.
    function _laneSub(uint256 level) internal {
        unchecked {
            _lanes[level >> 4] -= uint256(1) << ((level & 15) << 4);
        }
    }

    /// @dev Active Normies with a level in [from, to), for from >= C (only lanes at or above C are live).
    function _countRange(uint256 from, uint256 to) internal view returns (uint256 total) {
        if (to <= from) return 0;
        unchecked {
            uint256 last = to - 1;
            uint256 firstSlot = from >> 4;
            uint256 lastSlot = last >> 4;
            for (uint256 s = firstSlot; s <= lastSlot; ++s) {
                uint256 w = _lanes[s];
                if (w == 0) continue;
                if (s == firstSlot) w &= type(uint256).max << ((from & 15) << 4);
                if (s == lastSlot) {
                    uint256 top = ((last & 15) + 1) << 4;
                    if (top < 256) w &= (uint256(1) << top) - 1;
                }
                total += _sumLanes(w);
            }
        }
    }

    /// @dev Sum of the sixteen 16-bit lanes of `w`.
    function _sumLanes(uint256 w) internal pure returns (uint256) {
        unchecked {
            w = (w & 0x0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff)
                + ((w >> 16) & 0x0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff);
            w = (w & 0x00000000ffffffff00000000ffffffff00000000ffffffff00000000ffffffff)
                + ((w >> 32) & 0x00000000ffffffff00000000ffffffff00000000ffffffff00000000ffffffff);
            w = (w & 0x0000000000000000ffffffffffffffff0000000000000000ffffffffffffffff)
                + ((w >> 64) & 0x0000000000000000ffffffffffffffff0000000000000000ffffffffffffffff);
            return (w & type(uint128).max) + (w >> 128);
        }
    }

    /// @dev Moves `round`'s unpaid pool to round + 1 as sponsorship.
    function _roll(uint256 round) internal returns (uint256 rolled) {
        Round storage r = _rounds[round];
        rolled = r.unpaid;
        if (rolled == 0) return 0;
        r.unpaid = 0;
        Round storage next = _rounds[round + 1];
        next.sponsorship += uint128(rolled);
        next.unpaid += uint128(rolled);
        emit SponsorshipMoved(round, round + 1, rolled);
    }

    /// @dev The holder of `id`, or zero when it is burned.
    function _holder(uint256 id) internal view returns (address) {
        try collection.ownerOf(id) returns (address holder) {
            return holder == DEAD ? address(0) : holder;
        } catch {
            return address(0);
        }
    }

    /// @dev Reverts with BackingShortfall unless the ledger balance covers every balance and unpaid pool.
    function _checkBacking() internal view {
        uint256 balance = pixels.balanceOf(address(this));
        uint256 required = uint256(totalAllocated) + totalPooled;
        require(balance >= required, BackingShortfall(balance, required));
    }
}
