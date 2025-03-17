pragma solidity ^0.8.28;

interface IWhitelistV2 {
    function isTransactionAllowed(address from, address to, uint256 amount) external returns (bool);
}
