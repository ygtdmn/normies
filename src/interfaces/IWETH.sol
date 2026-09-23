// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IWETH {
    function balanceOf(address account) external view returns (uint256);
    function withdraw(uint256 amount) external;
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
}
