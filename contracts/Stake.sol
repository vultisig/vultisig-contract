// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IERC1363Spender.sol";
import "./interfaces/IUniswapRouter.sol";

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
    
    /// @notice Default Uniswap-like router for sweeping tokens
    address public defaultRouter;

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
    event TokenSwept(address indexed token, uint256 amountIn, uint256 amountOut);
    event RouterSet(address indexed router);
    event Migrated(address indexed user, address indexed newContract, uint256 amount);

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
     * @dev Internal function to handle deposits, used by both normal deposits and approveAndCall
     * @param _depositor Address transferring the tokens (may be different from _user in some cases)
     * @param _user Address to attribute the deposit to
     * @param _amount Amount of tokens to deposit
     */
    function _deposit(address _depositor, address _user, uint256 _amount) internal {
        // Update reward variables
        updateRewards();

        // Get user info
        UserInfo storage user = userInfo[_user];

        // Transfer tokens from the depositor to this contract
        stakingToken.safeTransferFrom(_depositor, address(this), _amount);

        // Update user staking amount
        user.amount += _amount;
        totalStaked += _amount;

        // Update user reward debt
        user.rewardDebt = (user.amount * accRewardPerShare) / 1e12;

        emit Deposited(_user, _amount);
    }

    /**
     * @dev Allows an approved sender to deposit tokens on behalf of another user
     * This is particularly useful for migration between staking contracts
     * Sender must approve tokens first
     * @param _user Address of the user to attribute the deposit to
     * @param _amount Amount of tokens to deposit
     * @return Amount of tokens deposited
     */
    function depositForUser(address _user, uint256 _amount) public nonReentrant returns (uint256) {
        require(_amount > 0, "Stake: amount must be greater than 0");
        require(_user != address(0), "Stake: user is the zero address");

        _deposit(msg.sender, _user, _amount);
        return _amount;
    }
    
    /**
     * @dev Allows a user to deposit tokens without using approveAndCall
     * User must approve tokens first
     * @param amount Amount of tokens to deposit
     * @return Amount of tokens deposited
     */
    function deposit(uint256 amount) external returns (uint256) {
        // Simply call depositForUser with msg.sender as the user
        return depositForUser(msg.sender, amount);
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
     * @dev Internal function to handle token withdrawals
     * @param _user Address of the user withdrawing tokens
     * @param _amount Amount of tokens to withdraw
     * @param _claimRewards Whether to claim rewards before withdrawing
     */
    function _withdraw(address _user, uint256 _amount, bool _claimRewards) internal {
        UserInfo storage user = userInfo[_user];
        require(user.amount >= _amount, "Stake: insufficient balance");

        // Claim rewards if requested
        if (_claimRewards) {
            claim();
        } else {
            // If not claiming rewards, still update reward variables
            updateRewards();
        }

        // Update user staking amount
        user.amount -= _amount;
        totalStaked -= _amount;

        // Update reward debt
        user.rewardDebt = (user.amount * accRewardPerShare) / 1e12;

        // Transfer staking tokens back to the user
        stakingToken.safeTransfer(_user, _amount);
    }

    /**
     * @dev Allows a user to withdraw their staked tokens after claiming rewards
     * @param amount Amount of tokens to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "Stake: amount must be greater than 0");

        _withdraw(msg.sender, amount, true);
        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @dev Emergency withdraw without claiming rewards
     * @param amount Amount of tokens to withdraw
     */
    function forceWithdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "Stake: amount must be greater than 0");

        _withdraw(msg.sender, amount, false);
        emit ForceWithdrawn(msg.sender, amount);
    }

    /**
     * @dev Internal function for owner to withdraw tokens
     * @param _token The token to withdraw
     * @param _amount Amount to withdraw (0 for all available)
     * @param _totalAvailable Total amount available for withdrawal
     * @return Amount withdrawn
     */
    function _ownerWithdraw(
        IERC20 _token, 
        uint256 _amount, 
        uint256 _totalAvailable
    ) internal returns (uint256) {
        require(_totalAvailable > 0, "Stake: no tokens available for withdrawal");
        
        // If amount is 0, withdraw all available tokens
        uint256 withdrawAmount = _amount == 0 ? _totalAvailable : _amount;
        require(withdrawAmount <= _totalAvailable, "Stake: amount exceeds available balance");
        
        // Transfer tokens to owner
        _token.safeTransfer(owner(), withdrawAmount);
        
        return withdrawAmount;
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
        
        uint256 withdrawAmount = _ownerWithdraw(rewardToken, amount, unclaimedBalance);
        
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
        
        uint256 withdrawAmount = _ownerWithdraw(stakingToken, amount, extraTokens);
        
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
    function onApprovalReceived(address owner, uint256 value, bytes calldata /* data */ )
        external
        override
        returns (bytes4)
    {
        require(msg.sender == address(stakingToken), "Stake: caller is not the staking token");
        require(value > 0, "Stake: amount must be greater than 0");

        _deposit(owner, owner, value);

        // Return the function selector to confirm transaction was accepted
        return IERC1363Spender.onApprovalReceived.selector;
    }



    /**
     * @dev Migrates user's entire stake to a new staking contract
     * This function will:
     * 1. Claim all pending rewards first
     * 2. Withdraw all staked tokens
     * 3. Approve the new staking contract to spend the tokens
     * 4. Use depositForUser in the new contract to deposit on behalf of the user
     * All in a single transaction
     * @param _newStakingContract Address of the new Stake contract to migrate to
     * @return migratedAmount Amount of tokens migrated to the new contract
     */
    function migrate(address _newStakingContract) external nonReentrant returns (uint256) {
        require(_newStakingContract != address(0), "Stake: new contract is the zero address");
        require(_newStakingContract != address(this), "Stake: cannot migrate to self");
        
        // Ensure the target is a valid Stake contract with the same staking token
        Stake newStakingContract = Stake(_newStakingContract);
        require(address(newStakingContract.stakingToken()) == address(stakingToken), 
                "Stake: incompatible staking token");
        
        // Get user's current staked amount
        UserInfo storage user = userInfo[msg.sender];
        uint256 stakedAmount = user.amount;
        require(stakedAmount > 0, "Stake: no tokens to migrate");
        
        // 1. Claim all pending rewards
        claim();
        
        // 2. Withdraw all staked tokens (without claiming again since we just did)
        // Update user staking amount
        user.amount = 0;
        totalStaked -= stakedAmount;
        
        // Update reward debt
        user.rewardDebt = 0;
        
        // 3. Approve the new contract to spend our tokens (staking tokens are now in this contract)
        stakingToken.approve(_newStakingContract, stakedAmount);
        
        // 4. Call depositForUser on the new contract to deposit directly with proper attribution
        bool migrationSuccess = false;
        try newStakingContract.depositForUser(msg.sender, stakedAmount) {
            migrationSuccess = true;
        } catch {
            // If the depositForUser call fails, we need to transfer tokens back to the user
            migrationSuccess = false;
        }
        
        if (!migrationSuccess) {
            // If migration failed, return tokens to the user's wallet
            stakingToken.safeTransfer(msg.sender, stakedAmount);
        }
        
        // Clear the approval regardless of outcome
        stakingToken.approve(_newStakingContract, 0);
        
        // Emit events for withdrawal and migration
        emit Withdrawn(msg.sender, stakedAmount);
        emit Migrated(msg.sender, _newStakingContract, stakedAmount);
        
        return stakedAmount;
    }
    
    /**
     * @dev Sets the router for sweep operations
     * @param _router The address of the Uniswap-like router to use
     */
    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "Stake: router is the zero address");
        defaultRouter = _router;
        emit RouterSet(_router);
    }

    /**
     * @dev Sweeps a token from the contract and swaps it into the reward token using the default router
     * @param _token Address of the token to sweep (can't be staking or reward token)
     * @return The amount of reward tokens received from the swap
     */
    function sweep(address _token) external nonReentrant returns (uint256) {
        require(defaultRouter != address(0), "Stake: default router not set");
        require(_token != address(stakingToken), "Stake: cannot sweep staking token");
        require(_token != address(rewardToken), "Stake: cannot sweep reward token");
        
        // Get the token balance
        IERC20 token = IERC20(_token);
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "Stake: no tokens to sweep");
        
        // Setup the swap path: token -> reward token
        address[] memory path = new address[](2);
        path[0] = _token;
        path[1] = address(rewardToken);
        
        // Approve the router to spend the token
        token.approve(defaultRouter, balance);
        
        // Set swap parameters
        uint256 amountOutMin = 0; // Accept any amount
        uint256 deadline = block.timestamp + 24 hours;
        
        // Execute the swap
        IUniswapRouter router = IUniswapRouter(defaultRouter);
        uint256[] memory amounts = router.swapExactTokensForTokens(
            balance,
            amountOutMin,
            path,
            address(this),
            deadline
        );
        
        // Clear the approval
        token.approve(defaultRouter, 0);
        
        // Update the lastRewardBalance to account for the new rewards
        updateRewards();
        
        // Emit the sweep event
        emit TokenSwept(_token, balance, amounts[amounts.length - 1]);
        
        return amounts[amounts.length - 1];
    }
}
