// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Whitelist} from "../Whitelist.sol";

/**
 * @title TokenMock
 * @dev Mock implementation of a token for testing the Whitelist contract
 */
contract TokenMock is Ownable {
    Whitelist public whitelist;

    /**
     * @notice Set the whitelist contract
     * @param newWhitelist New whitelist contract address
     */
    function setWhitelist(address newWhitelist) external onlyOwner {
        whitelist = Whitelist(newWhitelist);
    }

    /**
     * @notice Helper function to check whitelist
     * @param from Sender address
     * @param to Receiver address
     * @param amount Amount being transferred
     */
    function checkWhitelistFrom(address from, address to, uint256 amount) external {
        whitelist.checkWhitelist(from, to, amount);
    }
}
