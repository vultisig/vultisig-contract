// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IERC1363Spender.sol";

/**
 * @title Stake
 * @dev Contract for staking tokens that supports the ERC1363 approveAndCall standard
 * Users can deposit tokens in one transaction using approveAndCall
 * and withdraw their tokens at any time.
 */
contract Stake is IERC1363Spender, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Token being staked
    IERC20 public token;
    
    // Mapping from user address to staked amount
    mapping(address => uint256) private _balances;
    
    // Total staked amount
    uint256 private _totalStaked;
    
    // Events
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    
    /**
     * @dev Constructor sets the token that can be staked
     * @param _token Address of the ERC20 token that can be staked
     */
    constructor(address _token) {
        require(_token != address(0), "Stake: token is the zero address");
        token = IERC20(_token);
    }
    
    /**
     * @dev Returns the amount of tokens staked by an account
     * @param account The address to query the balance of
     * @return The amount of tokens staked by the account
     */
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }
    
    /**
     * @dev Returns the total amount of tokens staked in the contract
     * @return The total amount of tokens staked
     */
    function totalStaked() external view returns (uint256) {
        return _totalStaked;
    }
    
    /**
     * @dev Allows a user to deposit tokens without using approveAndCall
     * User must approve tokens first
     * @param amount Amount of tokens to deposit
     */
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Stake: amount must be greater than 0");
        
        // Transfer tokens from the user to this contract
        token.safeTransferFrom(msg.sender, address(this), amount);
        
        // Update user balance and total staked amount
        _balances[msg.sender] += amount;
        _totalStaked += amount;
        
        emit Deposited(msg.sender, amount);
    }
    
    /**
     * @dev Allows a user to withdraw their staked tokens
     * @param amount Amount of tokens to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "Stake: amount must be greater than 0");
        require(_balances[msg.sender] >= amount, "Stake: insufficient balance");
        
        // Update user balance and total staked amount
        _balances[msg.sender] -= amount;
        _totalStaked -= amount;
        
        // Transfer tokens back to the user
        token.safeTransfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, amount);
    }
    
    /**
     * @dev Implementation of IERC1363Spender onApprovalReceived to handle approveAndCall
     * This function is called when a user calls approveAndCall on the token contract
     * @param owner The address which called approveAndCall function and approved the tokens
     * @param value The amount of tokens to be spent
     * @param unused Additional data (not used in this implementation)
     * @return bytes4 The function selector to confirm the transaction is accepted
     */
    function onApprovalReceived(
        address owner,
        uint256 value,
        bytes calldata unused
    ) external override returns (bytes4) {
        require(msg.sender == address(token), "Stake: caller is not the token");
        require(value > 0, "Stake: amount must be greater than 0");
        
        // Note: The data parameter is not used in this implementation but could be used
        // to pass additional parameters or instructions in the future
        
        // Transfer tokens from the user to this contract
        token.safeTransferFrom(owner, address(this), value);
        
        // Update user balance and total staked amount
        _balances[owner] += value;
        _totalStaked += value;
        
        emit Deposited(owner, value);
        
        // Return the function selector to confirm transaction was accepted
        return IERC1363Spender.onApprovalReceived.selector;
    }
}
