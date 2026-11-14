// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaAccess } from "./arena/ArenaAccess.sol";

/**
 * @title NormiesArenaSkins
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @notice Sells custom skins for Normies in the Arena. Anyone may buy a skin for any Normie that exists. The price
 *         moves from a wallet straight to the treasury, never from a Normie's Arena balance: from the caller's
 *         wallet, or from a wallet that gave the caller a pixel allowance on the ledger. The purchase is recorded
 *         in the storage against the Normie, so it stays with the Normie when it changes hands. The storage emits
 *         SkinPurchased; the skin itself is made and served off chain from that event.
 *
 *         Needs a mover role on the pixel ledger (which also lets it spend allowances) and to be an authorized
 *         writer of the storage.
 */
contract NormiesArenaSkins is ArenaAccess {
    /// @notice The price changed before the purchase landed.
    error PriceChanged(uint256 expected, uint256 current);

    /// @notice Highest settable price, in pixels.
    uint256 public constant MAX_PRICE = 10_000;

    /// @notice Price of one skin, in pixels.
    uint256 public price = 5;
    /// @notice Receiver of skin payments. Set at deployment and changed with setTreasury.
    address public treasury;

    /// @notice The skin price was set to `price`.
    event PriceSet(uint256 price);
    /// @notice The treasury was set to `treasury`.
    event TreasurySet(address indexed treasury);

    /// @param store_    The NormiesArenaStorage to use.
    /// @param admin     The owner.
    /// @param treasury_ The first receiver of skin payments.
    constructor(address store_, address admin, address treasury_) ArenaAccess(store_, admin) {
        require(treasury_ != address(0), InvalidInput());
        treasury = treasury_;
    }

    /**
     * @notice Buy a skin for Normie `id`. Anyone, while running. Reverts with InvalidInput for a Normie that is
     *         burned or out of range, and with PriceChanged when `expectedPrice` is not the current price.
     * @param expectedPrice The price the caller agreed to.
     * @param payer         The wallet that pays: the caller, or a wallet that gave the caller an allowance of at
     *                      least the price on the pixel ledger, which the purchase spends. The ledger requires the
     *                      payer's pixels to be past their cooldown.
     */
    function purchase(uint256 id, uint256 expectedPrice, address payer) external nonReentrant whenRunning {
        uint256 current = price;
        require(expectedPrice == current, PriceChanged(expectedPrice, current));
        require(id < store.ID_BOUND() && !store.isBurned(id) && payer != address(0), InvalidInput());
        if (payer != msg.sender) pixels.useAllowance(payer, msg.sender, current);
        pixels.moveBalance(payer, treasury, current);
        store.recordPurchase(id, msg.sender, current);
    }

    /// @notice Set the skin price, from 1 to MAX_PRICE pixels. Owner only. Purchases quoting another price revert.
    function setPrice(uint256 value) external onlyOwner {
        require(value > 0 && value <= MAX_PRICE, InvalidInput());
        price = value;
        emit PriceSet(value);
    }

    /// @notice Set the receiver of later skin payments. Owner only. Pixels already paid stay with the old treasury.
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), InvalidInput());
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }
}
