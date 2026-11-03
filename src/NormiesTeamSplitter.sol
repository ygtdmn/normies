// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/**
 * @title NormiesTeamSplitter
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @notice The team's wallet for its half of royalties (the royalty splitter's `team`). It splits whatever arrives
 *         between two fixed payees. Nothing happens on receipt, so the payers (the royalty splitter, the market) pay
 *         no extra gas: anyone can call release() or releaseToken() to pay both payees out.
 *
 *         There is no owner and nothing can be changed. To change the payees or the split, deploy a new one and point
 *         the royalty splitter at it with `setTeam`.
 */
contract NormiesTeamSplitter {
    error ZeroAddress();
    error SamePayee();
    error InvalidBps();

    event Released(uint256 toPrimary, uint256 toSecondary);
    event TokenReleased(address indexed token, uint256 toPrimary, uint256 toSecondary);

    uint256 internal constant BPS = 10_000;

    /// @notice Receives `primaryBps` of everything.
    address public immutable primary;
    /// @notice Receives the rest, including rounding dust.
    address public immutable secondary;
    /// @notice The primary payee's share, in basis points.
    uint256 public immutable primaryBps;

    constructor(address _primary, address _secondary, uint256 _primaryBps) {
        require(_primary != address(0) && _secondary != address(0), ZeroAddress());
        require(_primary != _secondary, SamePayee());
        require(_primaryBps > 0 && _primaryBps < BPS, InvalidBps());
        primary = _primary;
        secondary = _secondary;
        primaryBps = _primaryBps;
    }

    /// @dev Empty on purpose, see the contract notice.
    receive() external payable { }

    /// @notice Splits the whole ETH balance. Both transfers are forced, so a payee that rejects ETH can never hold the
    ///         other payee's share back.
    function release() external {
        uint256 balance = address(this).balance;
        if (balance == 0) return;
        uint256 toPrimary = (balance * primaryBps) / BPS;
        uint256 toSecondary = balance - toPrimary;
        if (toPrimary > 0) SafeTransferLib.forceSafeTransferETH(primary, toPrimary);
        if (toSecondary > 0) SafeTransferLib.forceSafeTransferETH(secondary, toSecondary);
        emit Released(toPrimary, toSecondary);
    }

    /// @notice Splits the whole balance of an ERC20 (WETH included) the same way.
    function releaseToken(address token) external {
        uint256 balance = SafeTransferLib.balanceOf(token, address(this));
        if (balance == 0) return;
        uint256 toPrimary = (balance * primaryBps) / BPS;
        uint256 toSecondary = balance - toPrimary;
        if (toPrimary > 0) SafeTransferLib.safeTransfer(token, primary, toPrimary);
        if (toSecondary > 0) SafeTransferLib.safeTransfer(token, secondary, toSecondary);
        emit TokenReleased(token, toPrimary, toSecondary);
    }
}
