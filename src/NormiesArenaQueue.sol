// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaAccess } from "./arena/ArenaAccess.sol";

/**
 * @title NormiesArenaQueue
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @notice Brings pixels into the Arena and manages the line on NormiesArenaStorage: top-ups to a Normie's balance,
 *         joining and leaving the line, and round sponsorship.
 *
 *         A Normie's holder or one of its delegates (see NormiesArenaStorage.holderFor) tops it up, puts it in the
 *         line and takes it out. A top-up moves pixels from the caller's own wallet into the Normie's balance,
 *         which follows the NFT. Joining the line needs the Normie linked to an agent whose adapter binding points
 *         at it. Withdrawals are on the storage.
 *
 *         Line: a Normie in the line keeps its ticket through top-ups and sales. Pausing drops the ticket; joining
 *         again takes a new one at the back. A Normie that left only for lack of funds goes back at the back when
 *         it is topped up.
 *
 *         Pixels move only from msg.sender. Needs a mover role on the pixel ledger and to be an authorized writer
 *         of the storage.
 */
contract NormiesArenaQueue is ArenaAccess {
    /// @notice Role that may sponsor rounds from its own wallet (_ROLE_4, value 16). Only the owner and this role
    ///         can add sponsorship.
    uint256 public constant SPONSOR_ROLE = _ROLE_4;
    /// @notice Highest settable maxBatch.
    uint256 public constant MAX_BATCH = 50;

    /// @notice Most Normies in one batch call. Single-entry calls have no limit.
    uint256 public maxBatch = 50;

    /// @notice maxBatch was set.
    event MaxBatchSet(uint256 maxBatch);

    /// @param store_ The NormiesArenaStorage to use.
    /// @param admin  The owner.
    constructor(address store_, address admin) ArenaAccess(store_, admin) { }

    /// @dev Reverts with InvalidInput unless the batch has 1 to maxBatch entries.
    modifier batch(uint256 n) {
        require(n > 0 && n <= maxBatch, InvalidInput());
        _;
    }

    /// @notice Set maxBatch, from 1 to MAX_BATCH. Owner only.
    function setMaxBatch(uint256 value) external onlyOwner {
        require(value > 0 && value <= MAX_BATCH, InvalidInput());
        maxBatch = value;
        emit MaxBatchSet(value);
    }

    // ──────────────────────────────────────────────
    //  Sponsorship
    // ──────────────────────────────────────────────

    /// @notice Add `amount` pixels from the caller's wallet to `round`'s pool. Owner or SPONSOR_ROLE, for a round
    ///         above zero that is neither settled nor cancelled, including rounds not yet started. Works while
    ///         paused.
    function sponsor(uint256 round, uint256 amount) external onlyOwnerOrRoles(SPONSOR_ROLE) nonReentrant {
        require(round > 0 && amount > 0, InvalidInput());
        pixels.moveBalance(msg.sender, address(store), amount);
        store.addSponsorship(round, msg.sender, amount);
    }

    // ──────────────────────────────────────────────
    //  Top-ups
    // ──────────────────────────────────────────────

    /**
     * @notice Top up Normie `id` with `amount` pixels from the caller's wallet. The holder or a delegate, while
     *         running. A Normie that left the line only for lack of funds goes back in at the back.
     * @param enroll True to also put the Normie in the line at the back if it is not in it (see join). A Normie
     *               already in the line keeps its ticket either way.
     */
    function deposit(uint256 id, uint256 amount, bool enroll) external nonReentrant whenRunning {
        _deposit(id, amount, enroll);
    }

    /// @notice deposit for several Normies, with one `enroll` choice for all. While running. A single failure
    ///         reverts the batch.
    function depositBatch(
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bool enroll
    ) external nonReentrant whenRunning batch(ids.length) {
        require(ids.length == amounts.length, InvalidInput());
        for (uint256 i; i < ids.length; ++i) {
            _deposit(ids[i], amounts[i], enroll);
        }
    }

    /// @notice Link each Normie to its agent (see bindAgent), then deposit with `enroll`. While running. A single
    ///         failure reverts the batch.
    function depositRegisteredBatch(
        uint256[] calldata ids,
        uint256[] calldata amounts,
        uint256[] calldata agentIds
    ) external nonReentrant whenRunning batch(ids.length) {
        require(ids.length == amounts.length && ids.length == agentIds.length, InvalidInput());
        for (uint256 i; i < ids.length; ++i) {
            // _deposit checks the caller with holderFor; a refusal reverts the whole call, the link included.
            _bindAgent(ids[i], agentIds[i]);
            _deposit(ids[i], amounts[i], true);
        }
    }

    /// @dev Checks the caller, moves the pixels in, then joins or returns the Normie to the line. Both need the agent
    ///      link to still match its adapter binding (see _join).
    function _deposit(uint256 id, uint256 amount, bool enroll) private {
        store.holderFor(id, msg.sender);
        require(amount > 0, InvalidInput());
        pixels.moveBalance(msg.sender, address(store), amount);
        store.addBalance(id, msg.sender, amount);
        (, bool active, bool needsFunds) = store.enrollment(id);
        if (active) return;
        if (enroll || needsFunds) _join(id);
    }

    // ──────────────────────────────────────────────
    //  Line
    // ──────────────────────────────────────────────

    /// @notice Put Normie `id` in the line at the back. The holder or a delegate, while running. Moves no pixels:
    ///         the entry price is charged from the Normie's balance when a round admits it. Reverts with
    ///         InvalidState when it is already in the line.
    function resume(uint256 id) external whenRunning {
        store.holderFor(id, msg.sender);
        require(!_active(id), InvalidState());
        _join(id);
    }

    /// @notice resume for several Normies. While running. A single failure reverts the batch.
    function resumeBatch(uint256[] calldata ids) external whenRunning batch(ids.length) {
        for (uint256 i; i < ids.length; ++i) {
            store.holderFor(ids[i], msg.sender);
            require(!_active(ids[i]), InvalidState());
            _join(ids[i]);
        }
    }

    /// @notice Link each Normie to its agent (see bindAgent), then resume it. While running. A single failure
    ///         reverts the batch.
    function resumeRegisteredBatch(
        uint256[] calldata ids,
        uint256[] calldata agentIds
    ) external whenRunning batch(ids.length) {
        require(ids.length == agentIds.length, InvalidInput());
        for (uint256 i; i < ids.length; ++i) {
            store.holderFor(ids[i], msg.sender);
            _bindAgent(ids[i], agentIds[i]);
            require(!_active(ids[i]), InvalidState());
            _join(ids[i]);
        }
    }

    /// @notice Take Normie `id` out of the line. The holder or a delegate. Works while paused. Its ticket is dropped,
    ///         so joining again puts it at the back. Its balance stays.
    function pause(uint256 id) public {
        store.holderFor(id, msg.sender);
        store.deactivate(id, false);
    }

    /// @notice pause for several Normies. Reverts entirely if one fails.
    function pauseBatch(uint256[] calldata ids) external batch(ids.length) {
        for (uint256 i; i < ids.length; ++i) {
            pause(ids[i]);
        }
    }

    /// @dev Gives the Normie a ticket at the back. Reverts with InvalidState unless it is linked to an agent whose
    ///      binding still points at it.
    function _join(uint256 id) private {
        require(_awake(id), InvalidState());
        store.pushTicket(id);
    }

    /// @dev Whether the Normie is in the line.
    function _active(uint256 id) private view returns (bool active) {
        (, active,) = store.enrollment(id);
    }
}
