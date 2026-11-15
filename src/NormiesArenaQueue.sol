// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaAccess } from "./arena/ArenaAccess.sol";

/**
 * @title NormiesArenaQueue
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @notice Registers Normies in the Arena, brings pixels into their balances, and takes round sponsorship.
 *
 *         A Normie's holder or one of its delegates (see NormiesArenaStorage.holderFor) joins it, with no pixels,
 *         or tops it up from the caller's own wallet, which also joins it. Both need the Normie linked to an agent
 *         whose adapter binding points at it. A registered Normie plays every free round and, while active, every paid
 *         round its balance covers, from the next round started; there is no line and no leaving, only withdrawing the
 *         balance. The balance follows the NFT. Withdrawals are on the storage.
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
    ///         above zero that is neither ended nor cancelled, including rounds not yet started. Works while paused.
    function sponsor(uint256 round, uint256 amount) external onlyOwnerOrRoles(SPONSOR_ROLE) nonReentrant {
        require(round > 0 && amount > 0, InvalidInput());
        pixels.moveBalance(msg.sender, address(store), amount);
        store.addSponsorship(round, msg.sender, amount);
    }

    // ──────────────────────────────────────────────
    //  Joining
    // ──────────────────────────────────────────────

    /// @notice Register Normie `id` with no pixels: it plays free rounds, and paid rounds once its balance covers
    ///         the price. The holder or a delegate, while running. Reverts with InvalidState when it is already
    ///         registered or its agent link no longer matches.
    function join(uint256 id) external whenRunning {
        _join(id);
    }

    /// @notice join for several Normies. While running. A single failure reverts the batch.
    function joinBatch(uint256[] calldata ids) external whenRunning batch(ids.length) {
        for (uint256 i; i < ids.length; ++i) {
            _join(ids[i]);
        }
    }

    /// @notice Link each Normie to its agent (see bindAgent), then join it. While running. A single failure reverts
    ///         the batch.
    function joinRegisteredBatch(
        uint256[] calldata ids,
        uint256[] calldata agentIds
    ) external whenRunning batch(ids.length) {
        require(ids.length == agentIds.length, InvalidInput());
        for (uint256 i; i < ids.length; ++i) {
            store.holderFor(ids[i], msg.sender);
            _bindAgent(ids[i], agentIds[i]);
            store.register(ids[i]);
        }
    }

    /// @dev Checks the caller and the agent link, then registers.
    function _join(uint256 id) private {
        store.holderFor(id, msg.sender);
        require(_awake(id), InvalidState());
        store.register(id);
    }

    // ──────────────────────────────────────────────
    //  Top-ups
    // ──────────────────────────────────────────────

    /// @notice Top up Normie `id` with `amount` pixels from the caller's wallet, registering it if it is not yet.
    ///         The holder or a delegate, while running. A Normie that sat out for lack of funds plays again from the
    ///         next round its balance covers.
    function deposit(uint256 id, uint256 amount) external nonReentrant whenRunning {
        _deposit(id, amount);
    }

    /// @notice deposit for several Normies. While running. A single failure reverts the batch.
    function depositBatch(
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external nonReentrant whenRunning batch(ids.length) {
        require(ids.length == amounts.length, InvalidInput());
        for (uint256 i; i < ids.length; ++i) {
            _deposit(ids[i], amounts[i]);
        }
    }

    /// @notice Link each Normie to its agent (see bindAgent), then deposit. While running. A single failure reverts
    ///         the batch.
    function depositRegisteredBatch(
        uint256[] calldata ids,
        uint256[] calldata amounts,
        uint256[] calldata agentIds
    ) external nonReentrant whenRunning batch(ids.length) {
        require(ids.length == amounts.length && ids.length == agentIds.length, InvalidInput());
        for (uint256 i; i < ids.length; ++i) {
            // _deposit checks the caller with holderFor; a refusal reverts the whole call, the link included.
            _bindAgent(ids[i], agentIds[i]);
            _deposit(ids[i], amounts[i]);
        }
    }

    /// @dev Checks the caller and the agent link, moves the pixels in and credits them, registering the Normie.
    function _deposit(uint256 id, uint256 amount) private {
        store.holderFor(id, msg.sender);
        require(amount > 0, InvalidInput());
        require(_awake(id), InvalidState());
        pixels.moveBalance(msg.sender, address(store), amount);
        store.deposit(id, msg.sender, amount, true);
    }
}
