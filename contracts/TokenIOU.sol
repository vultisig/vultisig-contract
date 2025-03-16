// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1363} from "./interfaces/IERC1363.sol";
import {IERC1363Receiver} from "./interfaces/IERC1363Receiver.sol";
import {IERC1363Spender} from "./interfaces/IERC1363Spender.sol";

/**
 * @title ERC20Burnable with ERC1363 standard functions like approveAndCall, transferAndCall
 */
contract TokenIOU is ERC20Burnable, Ownable, IERC1363 {
    string private _name;
    string private _ticker;
    address public merge;
    bool public locked;

    error InvalidToAddress();
    error TransferLocked();

    constructor(string memory name_, string memory ticker_) ERC20(name_, ticker_) Ownable(_msgSender()) {
        _mint(_msgSender(), 10_000_000 * 1e18);
        _name = name_;
        _ticker = ticker_;
        locked = true;
    }

    function mint(uint256 amount) external onlyOwner {
        _mint(owner(), amount);
    }

    //////////////////////////////
    //  External owner setters  //
    //////////////////////////////
    function setNameAndTicker(string calldata name_, string calldata ticker_) external onlyOwner {
        _name = name_;
        _ticker = ticker_;
    }
    function setMerge(address _merge) external onlyOwner {
        merge = _merge;
    }

    function setLocked(bool newFlag) external onlyOwner {
        locked = newFlag;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _ticker;
    }

    /**
     * @inheritdoc IERC1363
     */
    function transferAndCall(address to, uint256 value) public virtual returns (bool) {
        return transferAndCall(to, value, "");
    }

    /**
     * @inheritdoc IERC1363
     */
    function transferAndCall(address to, uint256 value, bytes memory data) public virtual returns (bool) {
        if (!transfer(to, value)) {
            revert ERC1363TransferFailed(to, value);
        }
        _checkOnTransferReceived(_msgSender(), to, value, data);
        return true;
    }

    /**
     * @inheritdoc IERC1363
     */
    function transferFromAndCall(address from, address to, uint256 value) public virtual returns (bool) {
        return transferFromAndCall(from, to, value, "");
    }

    /**
     * @inheritdoc IERC1363
     */
    function transferFromAndCall(
        address from,
        address to,
        uint256 value,
        bytes memory data
    ) public virtual returns (bool) {
        if (!transferFrom(from, to, value)) {
            revert ERC1363TransferFromFailed(from, to, value);
        }
        _checkOnTransferReceived(from, to, value, data);
        return true;
    }

    /**
     * @inheritdoc IERC1363
     */
    function approveAndCall(address spender, uint256 value) public virtual returns (bool) {
        return approveAndCall(spender, value, "");
    }

    /**
     * @inheritdoc IERC1363
     */
    function approveAndCall(address spender, uint256 value, bytes memory data) public virtual returns (bool) {
        if (!approve(spender, value)) {
            revert ERC1363ApproveFailed(spender, value);
        }
        _checkOnApprovalReceived(spender, value, data);
        return true;
    }

    /// @notice Before token transfer hook
    /// @dev Not allowed to send tokens to the token contract itself, and during locked period, users can't transfer the tokens
    function _update(address from, address to, uint256 amount) internal override {
        if (to == address(this)) {
            revert InvalidToAddress();
        }
        // While locked, only allow transfer from merge contract and owner
        if (locked && from != merge && from != owner()) {
            revert TransferLocked();
        }
        super._update(from, to, amount);
    }

    /**
     * @dev Performs a call to `IERC1363Receiver::onTransferReceived` on a target address.
     * This will revert if the target doesn't implement the `IERC1363Receiver` interface or
     * if the target doesn't accept the token transfer or
     * if the target address is not a contract.
     *
     * @param from Address representing the previous owner of the given token amount.
     * @param to Target address that will receive the tokens.
     * @param value The amount of tokens to be transferred.
     * @param data Optional data to send along with the call.
     */
    function _checkOnTransferReceived(address from, address to, uint256 value, bytes memory data) private {
        if (to.code.length == 0) {
            revert ERC1363EOAReceiver(to);
        }

        try IERC1363Receiver(to).onTransferReceived(_msgSender(), from, value, data) returns (bytes4 retval) {
            if (retval != IERC1363Receiver.onTransferReceived.selector) {
                revert ERC1363InvalidReceiver(to);
            }
        } catch (bytes memory reason) {
            if (reason.length == 0) {
                revert ERC1363InvalidReceiver(to);
            } else {
                assembly {
                    revert(add(32, reason), mload(reason))
                }
            }
        }
    }

    /**
     * @dev Performs a call to `IERC1363Spender::onApprovalReceived` on a target address.
     * This will revert if the target doesn't implement the `IERC1363Spender` interface or
     * if the target doesn't accept the token approval or
     * if the target address is not a contract.
     *
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @param data Optional data to send along with the call.
     */
    function _checkOnApprovalReceived(address spender, uint256 value, bytes memory data) private {
        if (spender.code.length == 0) {
            revert ERC1363EOASpender(spender);
        }

        try IERC1363Spender(spender).onApprovalReceived(_msgSender(), value, data) returns (bytes4 retval) {
            if (retval != IERC1363Spender.onApprovalReceived.selector) {
                revert ERC1363InvalidSpender(spender);
            }
        } catch (bytes memory reason) {
            if (reason.length == 0) {
                revert ERC1363InvalidSpender(spender);
            } else {
                assembly {
                    revert(add(32, reason), mload(reason))
                }
            }
        }
    }
}
