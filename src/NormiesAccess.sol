// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { OwnableRoles } from "solady/auth/OwnableRoles.sol";

/**
 * @title NormiesAccess
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @notice Who may do what on the Pixel Market contracts. No single key can do everything:
 *
 *           owner     ADMIN, held by a Safe multisig. Role grants, mover roles, overlay writers, fee recipients,
 *                     withdrawals, pointers to other contracts, ownership. Two-step handover
 *                     (requestOwnershipHandover / completeOwnershipHandover) for later moves.
 *           GUARDIAN  operations, with no delay: pause and unpause, the allowance kill switch, cancelling an epoch
 *                     before its claims open. It can never grant anything or move value.
 *           CONFIG    operating parameters: prices, burn tiers, fees (capped), the listing floor, the claim window
 *                     (with a floor).
 *           POSTER    revenue pool only: postEpoch. A posted epoch opens for claims POST_DELAY later, so a guardian
 *                     can cancel a bad root before it pays anything.
 */
abstract contract NormiesAccess is OwnableRoles {
    uint256 internal constant GUARDIAN_ROLE = _ROLE_0;
    uint256 internal constant CONFIG_ROLE = _ROLE_1;
    uint256 internal constant POSTER_ROLE = _ROLE_2;
}
