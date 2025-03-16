// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title The contract handles whitelist for WEWE-VULT merge
 * @notice The main functionalities are:
 * - Allow transfers from owner and merge contract
 * - Ownable: Set merge contract address
 * - Token contract `_beforeTokenTransfer` hook will call `checkWhitelist` function and this function will check if from address is owner or merge contract
 */
contract WhitelistMerge is Ownable {
    error TransferLocked();
    error NotToken();

    /// @notice Token contract address
    address public token;
    /// @notice Merge contract address
    address public merge;

    constructor(address _token, address _merge) Ownable(_msgSender()) {
        token = _token;
        merge = _merge;
    }

    /// @notice Check if called from token contract.
    modifier onlyToken() {
        if (_msgSender() != token) {
            revert NotToken();
        }
        _;
    }

    /// @notice Setter for token
    /// @param newToken New token address
    function setToken(address newToken) external onlyOwner {
        token = newToken;
    }

    /// @notice Setter for merge
    /// @param newMerge New merge address
    function setMerge(address newMerge) external onlyOwner {
        merge = newMerge;
    }

    /// @notice Check if address to owner or merge contract
    /// @param from sender address
    /// @param to recipient address
    /// @param amount Number of tokens to be transferred
    /// @dev Check if from address is owner or merge contract
    function checkWhitelist(address from, address to, uint256 amount) external onlyToken {
        if (from != merge && from != owner()) {
            revert TransferLocked();
        }
    }
}
