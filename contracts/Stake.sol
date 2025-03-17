// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IERC1363Spender.sol";

/**
 * @title Stake
 * @dev Contract for staking VULT tokens that distributes USDC rewards
 * Adapted from Sushiswap's Masterchef rewardDebt methodology
 * Users can deposit tokens in one transaction using approveAndCall
 * and claim their USDC rewards pro-rata to their stake.
 * Owner can withdraw unclaimed USDC and extra staking tokens.
 */
contract Stake is IERC1363Spender, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /// @notice VULT token being staked
    IERC20 public immutable stakingToken;

    /// @notice USDC token for rewards
    IERC20 public immutable rewardToken;

    /// @notice Accumulated reward tokens per share, scaled by 1e12
    uint256 public accRewardPerShare;

    /// @notice Last processed reward balance
    uint256 public lastRewardBalance;

    /// @notice Total tokens staked
    uint256 public totalStaked;

    /// @notice User staking information
    struct UserInfo {
        uint256 amount; // How many tokens the user has staked
        uint256 rewardDebt; // Reward debt as per Masterchef logic
        // rewards = user.amount * accRewardPerShare - user.rewardDebt
    }

    /// @notice Mapping of user address to their staking info
    mapping(address => UserInfo) public userInfo;

    /// @notice Events
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event ForceWithdrawn(address indexed user, uint256 amount);
    event RewardsUpdated(uint256 newAccRewardPerShare, uint256 rewardAmount);
    event OwnerWithdrawnRewards(uint256 amount);
    event OwnerWithdrawnExtraTokens(uint256 amount);

    /**
     * @dev Constructor sets the staking and reward tokens
     * @param _stakingToken Address of the ERC20 token that can be staked (VULT)
     * @param _rewardToken Address of the ERC20 token used for rewards (USDC)
     */
    constructor(address _stakingToken, address _rewardToken) Ownable(msg.sender) {
        require(_stakingToken != address(0), "Stake: staking token is the zero address");
        require(_rewardToken != address(0), "Stake: reward token is the zero address");

        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
    }

    /**
     * @dev Update reward variables with current token balances
     * Must be called before any deposit or withdrawal
     */
    function updateRewards() public {
        if (totalStaked == 0) {
            lastRewardBalance = rewardToken.balanceOf(address(this));
            return;
        }

        uint256 currentRewardBalance = rewardToken.balanceOf(address(this));

        // If there are new rewards
        if (currentRewardBalance > lastRewardBalance) {
            uint256 newRewards = currentRewardBalance - lastRewardBalance;

            // Update accRewardPerShare based on new rewards
            // Scaled by 1e12 to avoid precision loss when dividing small numbers
            accRewardPerShare += (newRewards * 1e12) / totalStaked;

            // Update the last reward balance
            lastRewardBalance = currentRewardBalance;

            emit RewardsUpdated(accRewardPerShare, newRewards);
        }
    }

    /**
     * @dev Returns pending rewards for a user
     * @param _user Address of the user
     * @return Pending reward amount
     */
    function pendingRewards(address _user) public view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        if (user.amount == 0 || totalStaked == 0) {
            return 0;
        }

        uint256 currentRewardBalance = rewardToken.balanceOf(address(this));
        uint256 additionalRewards = 0;
        uint256 newAccRewardPerShare = accRewardPerShare;

        // Calculate additional rewards since last update
        if (currentRewardBalance > lastRewardBalance && totalStaked > 0) {
            additionalRewards = currentRewardBalance - lastRewardBalance;
            newAccRewardPerShare += (additionalRewards * 1e12) / totalStaked;
        }

        // Calculate pending rewards using the formula:
        // pending = (user.amount * accRewardPerShare) - user.rewardDebt
        return (user.amount * newAccRewardPerShare) / 1e12 - user.rewardDebt;
    }

    /**
     * @dev Allows a user to deposit tokens without using approveAndCall
     * User must approve tokens first
     * @param amount Amount of tokens to deposit
     */
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Stake: amount must be greater than 0");

        // Update reward variables
        updateRewards();

        // Get user info
        UserInfo storage user = userInfo[msg.sender];

        // Transfer tokens from the user to this contract
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        // Update user staking amount
        user.amount += amount;
        totalStaked += amount;

        // Update user reward debt
        user.rewardDebt = (user.amount * accRewardPerShare) / 1e12;

        emit Deposited(msg.sender, amount);
    }

    /**
     * @dev Claims USDC rewards for the caller
     * @return Amount of rewards claimed
     */
    function claim() public returns (uint256) {
        updateRewards();

        UserInfo storage user = userInfo[msg.sender];
        uint256 pending = (user.amount * accRewardPerShare) / 1e12 - user.rewardDebt;

        if (pending > 0) {
            // Transfer reward tokens to the user
            uint256 rewardBalance = rewardToken.balanceOf(address(this));
            uint256 rewardAmount = pending > rewardBalance ? rewardBalance : pending;

            lastRewardBalance -= rewardAmount;
            rewardToken.safeTransfer(msg.sender, rewardAmount);

            // Update reward debt
            user.rewardDebt = (user.amount * accRewardPerShare) / 1e12;

            emit RewardClaimed(msg.sender, rewardAmount);
            return rewardAmount;
        }

        return 0;
    }

    /**
     * @dev Allows a user to withdraw their staked tokens after claiming rewards
     * @param amount Amount of tokens to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "Stake: amount must be greater than 0");

        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= amount, "Stake: insufficient balance");

        // Claim rewards first
        claim();

        // Update user staking amount
        user.amount -= amount;
        totalStaked -= amount;

        // Update reward debt after withdrawal
        user.rewardDebt = (user.amount * accRewardPerShare) / 1e12;

        // Transfer staking tokens back to the user
        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @dev Emergency withdraw without claiming rewards
     * @param amount Amount of tokens to withdraw
     */
    function forceWithdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "Stake: amount must be greater than 0");

        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= amount, "Stake: insufficient balance");

        // Update reward variables
        updateRewards();

        // Update user staking amount
        user.amount -= amount;
        totalStaked -= amount;

        // Update reward debt to effectively skip rewards for this period
        user.rewardDebt = (user.amount * accRewardPerShare) / 1e12;

        // Transfer staking tokens back to the user
        stakingToken.safeTransfer(msg.sender, amount);

        emit ForceWithdrawn(msg.sender, amount);
    }

    /**
     * @dev Allows the owner to withdraw unclaimed USDC rewards
     * @param amount Amount of USDC to withdraw, or 0 for all unclaimed balance
     * @return Amount of USDC withdrawn
     */
    function withdrawUnclaimedRewards(uint256 amount) external onlyOwner nonReentrant returns (uint256) {
        // Update rewards to ensure all accounting is current
        updateRewards();

        // Calculate unclaimed USDC (current balance - last processed balance)
        uint256 currentBalance = rewardToken.balanceOf(address(this));
        uint256 unclaimedBalance = currentBalance - lastRewardBalance;
        require(unclaimedBalance > 0, "Stake: no unclaimed rewards");

        // If amount is 0, withdraw all unclaimed rewards
        uint256 withdrawAmount = amount == 0 ? unclaimedBalance : amount;
        require(withdrawAmount <= unclaimedBalance, "Stake: amount exceeds unclaimed balance");

        // Transfer rewards to owner
        rewardToken.safeTransfer(owner(), withdrawAmount);

        emit OwnerWithdrawnRewards(withdrawAmount);
        return withdrawAmount;
    }

    /**
     * @dev Allows the owner to withdraw extra staking tokens that are not part of totalStaked
     * @param amount Amount of tokens to withdraw, or 0 for all extra tokens
     * @return Amount of tokens withdrawn
     */
    function withdrawExtraStakingTokens(uint256 amount) external onlyOwner nonReentrant returns (uint256) {
        // Calculate extra tokens (current balance - tracked total)
        uint256 currentBalance = stakingToken.balanceOf(address(this));
        require(currentBalance > totalStaked, "Stake: no extra tokens available");

        uint256 extraTokens = currentBalance - totalStaked;

        // If amount is 0, withdraw all extra tokens
        uint256 withdrawAmount = amount == 0 ? extraTokens : amount;
        require(withdrawAmount <= extraTokens, "Stake: amount exceeds extra token balance");

        // Transfer tokens to owner
        stakingToken.safeTransfer(owner(), withdrawAmount);

        emit OwnerWithdrawnExtraTokens(withdrawAmount);
        return withdrawAmount;
    }

    /**
     * @dev Implementation of IERC1363Spender onApprovalReceived to handle approveAndCall
     * This function is called when a user calls approveAndCall on the token contract
     * @param owner The address which called approveAndCall function and approved the tokens
     * @param value The amount of tokens to be spent
     * @return bytes4 The function selector to confirm the transaction is accepted
     */
    function onApprovalReceived(
        address owner,
        uint256 value,
        bytes calldata /* data */
    ) external override returns (bytes4) {
        require(msg.sender == address(stakingToken), "Stake: caller is not the staking token");
        require(value > 0, "Stake: amount must be greater than 0");

        // Update reward variables
        updateRewards();

        // Get user info
        UserInfo storage user = userInfo[owner];

        // Transfer tokens from the user to this contract
        stakingToken.safeTransferFrom(owner, address(this), value);

        // Update user staking amount
        user.amount += value;
        totalStaked += value;

        // Update user reward debt
        user.rewardDebt = (user.amount * accRewardPerShare) / 1e12;

        emit Deposited(owner, value);

        // Return the function selector to confirm transaction was accepted
        return IERC1363Spender.onApprovalReceived.selector;
    }
}
