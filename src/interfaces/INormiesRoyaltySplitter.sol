// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface INormiesRoyaltySplitter {
    function release() external;
    function releaseToken(address token) external;
    function pool() external view returns (address);
    function team() external view returns (address);
    function poolBps() external view returns (uint16);
}
