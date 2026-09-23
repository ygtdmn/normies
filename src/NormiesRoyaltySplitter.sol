// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesRoyaltySplitter } from "./interfaces/INormiesRoyaltySplitter.sol";
import { IWETH } from "./interfaces/IWETH.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/**
 * @title NormiesRoyaltySplitter
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @notice The collection's royalty receiver. Sales pay ETH here in the middle of the trade and accepted offers pay
 *         WETH with no callback, so nothing happens on receipt: anyone can call release() to unwrap and split what
 *         has arrived between the holders' revenue pool and the team.
 */
contract NormiesRoyaltySplitter is INormiesRoyaltySplitter, Ownable {
    error ZeroAddress();
    error InvalidBps();
    error UseRelease();

    event Released(uint256 toPool, uint256 toTeam);
    event TokenReleased(address indexed token, uint256 poolShare, uint256 teamShare);
    event PoolBpsSet(uint16 poolBps);
    event TeamSet(address indexed team);

    uint256 internal constant BPS = 10_000;

    IWETH public immutable weth;
    address public immutable pool;
    address public team;
    /// @notice The holders' share of every royalty, in basis points.
    uint16 public poolBps = 5000;

    constructor(IWETH _weth, address _pool, address _team) Ownable() {
        require(_pool != address(0) && _team != address(0), ZeroAddress());
        weth = _weth;
        pool = _pool;
        team = _team;
    }

    /// @dev Empty on purpose, see the contract notice.
    receive() external payable { }

    /// @notice Unwraps any WETH, then splits the whole ETH balance. The pool is paid first and both transfers are
    ///         forced, so a team address that rejects ETH can never hold the holders' share back.
    function release() external {
        uint256 wrapped = weth.balanceOf(address(this));
        if (wrapped > 0) weth.withdraw(wrapped);

        uint256 balance = address(this).balance;
        if (balance == 0) return;
        uint256 toPool = (balance * poolBps) / BPS;
        uint256 toTeam = balance - toPool;
        if (toPool > 0) SafeTransferLib.forceSafeTransferETH(pool, toPool);
        if (toTeam > 0) SafeTransferLib.forceSafeTransferETH(team, toTeam);
        emit Released(toPool, toTeam);
    }

    /// @notice Royalties in any other token are rare. The pool only pays ETH, so the whole balance goes to the team
    ///         and the event records the holders' share of it, which the team converts and sends to the pool.
    function releaseToken(address token) external {
        require(token != address(weth), UseRelease());
        uint256 balance = SafeTransferLib.balanceOf(token, address(this));
        if (balance == 0) return;
        uint256 poolShare = (balance * poolBps) / BPS;
        SafeTransferLib.safeTransfer(token, team, balance);
        emit TokenReleased(token, poolShare, balance - poolShare);
    }

    function setPoolBps(uint16 _poolBps) external onlyOwner {
        require(_poolBps <= BPS, InvalidBps());
        poolBps = _poolBps;
        emit PoolBpsSet(_poolBps);
    }

    function setTeam(address _team) external onlyOwner {
        require(_team != address(0), ZeroAddress());
        team = _team;
        emit TeamSet(_team);
    }
}
