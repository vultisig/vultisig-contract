// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Token} from "../Token.sol";
import {IWhitelistV2} from "../interfaces/IWhitelistV2.sol";

/**
 * @title Extended token contract with whitelist contract interactions
 * @notice During whitelist period, `_beforeTokenTransfer` function will call `checkWhitelist` function of whitelist contract
 * @notice If whitelist period is ended, owner will set whitelist contract address back to address(0) and tokens will be transferred freely
 */
contract TokenWhitelisted is Token {
    /// @notice whitelist contract address
    address public _whitelistContract;
    bool private _whitelistRevoked = false;

    constructor(string memory name_, string memory ticker_) Token(name_, ticker_) {}

    /// @notice Returns current whitelist contract address
    function whitelistContract() external view returns (address) {
        return _whitelistContract;
    }

    /// @notice Ownable function to revoke setting Whitelist
    function revokeSettingWhitelist() external onlyOwner {
        _whitelistRevoked = true;
        _whitelistContract = address(0);
    }

    /// @notice Ownable function to set new whitelist contract address
    function setWhitelistContract(address newWhitelistContract) external onlyOwner {
        // Allow setting the whitelist contract only if not revoked
        if (!_whitelistRevoked) {
            _whitelistContract = newWhitelistContract;
        }
    }

    /// @notice Before token transfer hook
    /// @dev It will call `checkWhitelist` function and if it's succsessful, it will transfer tokens, unless revert
    function _update(address from, address to, uint256 amount) internal override {
        require(to != address(this), "Cannot transfer to the token contract address");
        if (_whitelistContract != address(0)) {
            require(
                IWhitelistV2(_whitelistContract).isTransactionAllowed(from, to, amount),
                "Transaction not allowed by whitelist"
            );
        }
        super._update(from, to, amount);
    }
}
