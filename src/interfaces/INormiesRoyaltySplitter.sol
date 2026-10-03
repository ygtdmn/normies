// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { IWETH } from "./IWETH.sol";

interface INormiesRoyaltySplitter {
    function release() external;
    function releaseToken(address token) external;
    function pool() external view returns (address);
    function team() external view returns (address);
    function poolBps() external view returns (uint16);
    function weth() external view returns (IWETH);

    // Owner
    function setPoolBps(uint16 _poolBps) external;
    function setTeam(address _team) external;
}
