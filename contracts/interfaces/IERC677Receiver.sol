// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IERC1363Receiver
 * @dev Interface for any contract that wants to support `transferAndCall` or `transferFromAndCall` from ERC-1363 token contracts.
 */
interface IERC677Receiver {
   
    function onTokenTransfer(address sender, uint value, bytes calldata data) external;
}
