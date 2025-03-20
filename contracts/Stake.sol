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

    // ================= Events =================
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
    event Reinvested(address indexed user, uint256 rewardAmount, uint256 stakingTokensReceived);
    event MinOutPercentageSet(uint8 percentage);
    event VestingStarted(uint256 amount, uint256 timestamp);

    // ================= State Variables =================
    /// @notice User staking information
    struct UserInfo {
        uint256 amount; // How many tokens the user has staked
        uint256 rewardDebt; // Reward debt as per Masterchef logic
    }

    /// @notice VULT token being staked
    IERC20 public immutable stakingToken;

    /// @notice USDC token for rewards
    IERC20 public immutable rewardToken;

    /// @notice Default Uniswap-like router for sweeping tokens
    address public defaultRouter;

    /// @notice Min amount out percentage for reinvest swaps (1-100)
    uint8 public minOutPercentage = 90; // Default 90% to protect from slippage

    /// @notice Accumulated reward tokens per share, scaled by 1e12
    uint256 public accRewardPerShare;

    /// @notice Last processed reward balance
    uint256 public lastRewardBalance;

    /// @notice Total tokens staked
    uint256 public totalStaked;

    /// @notice Last time rewards were updated
    uint256 public lastRewardUpdateTime;

    /// @notice Mapping of user address to their staking info
    mapping(address => UserInfo) public userInfo;

    // Add new vesting constants and state variables
    uint256 private constant VESTING_PERIOD = 24 hours;

    /// @notice The amount currently being vested
    uint256 private vestingAmount;

    /// @notice The timestamp when the current vesting period started
    uint256 private lastVestingStartTime;

    // Add a new state variable to track distributed rewards
    uint256 private distributedVestedAmount;

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
     * @dev Internal function to handle reward updates based on configured parameters
     * Returns the newly vested amount that was processed
     */
    function _updateRewards() internal returns (uint256) {
        if (totalStaked == 0) {
            lastRewardBalance = rewardToken.balanceOf(address(this));
            lastRewardUpdateTime = block.timestamp;
            return 0;
        }

        uint256 currentRewardBalance = rewardToken.balanceOf(address(this));
        uint256 currentTimestamp = block.timestamp;
        uint256 newlyVestedAmount = 0;

        // First, process any existing vesting
        if (vestingAmount > 0) {
            uint256 timeSinceLastVesting = currentTimestamp - lastVestingStartTime;
            uint256 totalVestedAmount;

            if (timeSinceLastVesting >= VESTING_PERIOD) {
                // Fully vested
                totalVestedAmount = vestingAmount;
                newlyVestedAmount = totalVestedAmount - distributedVestedAmount;

                // Reset vesting state
                vestingAmount = 0;
                lastVestingStartTime = 0;
                distributedVestedAmount = 0;
            } else {
                // Partially vested
                totalVestedAmount = (vestingAmount * timeSinceLastVesting) / VESTING_PERIOD;
                newlyVestedAmount = totalVestedAmount > distributedVestedAmount
                    ? totalVestedAmount - distributedVestedAmount
                    : 0;
                distributedVestedAmount = totalVestedAmount;
            }

            if (newlyVestedAmount > 0) {
                accRewardPerShare += (newlyVestedAmount * 1e12) / totalStaked;
                emit RewardsUpdated(accRewardPerShare, newlyVestedAmount);
            }
        }

        // Check for new rewards
        uint256 newRewards = currentRewardBalance > lastRewardBalance ? currentRewardBalance - lastRewardBalance : 0;

        // Update lastRewardBalance to current balance
        // Start new vesting period for new rewards
        if (newRewards > 0) {
            vestingAmount = newRewards;
            lastVestingStartTime = currentTimestamp;
            distributedVestedAmount = 0;
            emit VestingStarted(newRewards, currentTimestamp);
        }

        return newlyVestedAmount;
    }

    /**
     * @dev Returns pending rewards for a user, taking vesting into account
     * @param _user Address of the user
     * @return Pending reward amount
     */
    function pendingRewards(address _user) public view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        if (user.amount == 0 || totalStaked == 0) {
            return 0;
        }

        uint256 currentRewardBalance = rewardToken.balanceOf(address(this));
        uint256 unvestedAmount = getUnvestedAmount();
        uint256 availableBalance = currentRewardBalance - unvestedAmount;

        uint256 newAccRewardPerShare = accRewardPerShare;
        if (availableBalance > lastRewardBalance) {
            uint256 vestedAmount = getVestedAmount();
            if (vestedAmount > 0) {
                newAccRewardPerShare += (vestedAmount * 1e12) / totalStaked;
            }
        }

        return (user.amount * newAccRewardPerShare) / 1e12 - user.rewardDebt;
    }

    /**
     * @dev Internal function to handle deposits, used by both normal deposits and approveAndCall
     * @param _depositor Address transferring the tokens (may be different from _user in some cases)
     * @param _user Address to attribute the deposit to
     * @param _amount Amount of tokens to deposit
     */
    function _deposit(address _depositor, address _user, uint256 _amount) internal {
        // Update reward variables first
        _updateRewards();

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
    function claim() public nonReentrant returns (uint256) {
        return _claim(msg.sender);
    }

    /**
     * @dev Internal function for claiming rewards
     * This is used by functions that already have nonReentrant modifier
     * @param _recipient Address to receive the claimed rewards
     * @return Amount of rewards claimed
     */
    function _claim(address _recipient) internal returns (uint256) {
        // Update rewards first
        _updateRewards();

        // Claim rewards internally and get the amount
        uint256 rewardAmount = _claimRewards(msg.sender);

        if (rewardAmount > 0) {
            // Transfer the tokens to the recipient
            rewardToken.safeTransfer(_recipient, rewardAmount);
            emit RewardClaimed(msg.sender, rewardAmount);
        }

        return rewardAmount;
    }

    /**
     * @dev Internal function to handle token withdrawals
     * @param _user Address of the user withdrawing tokens
     * @param _amount Amount of tokens to withdraw
     * @param _shouldClaimRewards Whether to claim rewards before withdrawing
     */
    function _withdraw(address _user, uint256 _amount, bool _shouldClaimRewards) internal {
        UserInfo storage user = userInfo[_user];
        require(user.amount >= _amount, "Stake: insufficient balance");

        // Claim rewards if requested
        if (_shouldClaimRewards) {
            _claim(_user);
        } else {
            // If not claiming rewards, still update reward variables
            _updateRewards();
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
     * @dev Allows the owner to withdraw all unclaimed USDC rewards
     * @return Amount of USDC withdrawn
     */
    function withdrawUnclaimedRewards() external onlyOwner nonReentrant returns (uint256) {
        _updateRewards();

        // Calculate unclaimed USDC (current balance - last processed balance - unvested amount)
        uint256 currentBalance = rewardToken.balanceOf(address(this));
        uint256 unvestedAmount = getUnvestedAmount();
        uint256 unclaimedBalance = currentBalance - lastRewardBalance - unvestedAmount;

        if (unclaimedBalance > 0) {
            rewardToken.safeTransfer(owner(), unclaimedBalance);
        }

        emit OwnerWithdrawnRewards(unclaimedBalance);
        return unclaimedBalance;
    }

    /**
     * @dev Allows the owner to withdraw all extra staking tokens that are not part of totalStaked
     * @return Amount of tokens withdrawn
     */
    function withdrawExtraStakingTokens() external onlyOwner nonReentrant returns (uint256) {
        // Calculate extra tokens (current balance - tracked total)
        uint256 currentBalance = stakingToken.balanceOf(address(this));
        require(currentBalance > totalStaked, "Stake: no extra tokens available");

        uint256 extraTokens = currentBalance - totalStaked;

        uint256 withdrawAmount = extraTokens;
        if (withdrawAmount > 0) {
            stakingToken.safeTransfer(owner(), withdrawAmount);
        }

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
        require(
            address(newStakingContract.stakingToken()) == address(stakingToken),
            "Stake: incompatible staking token"
        );

        // Get user's current staked amount
        UserInfo storage user = userInfo[msg.sender];
        uint256 stakedAmount = user.amount;
        require(stakedAmount > 0, "Stake: no tokens to migrate");

        // 1. Claim all pending rewards
        _claim(msg.sender);

        // 2. Withdraw all staked tokens
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
     * @dev Sets the minimum percentage of output tokens expected (slippage protection)
     * @param _percentage The percentage (1-100)
     */
    function setMinOutPercentage(uint8 _percentage) external onlyOwner {
        require(_percentage > 0 && _percentage <= 100, "Stake: percentage must be between 1-100");
        minOutPercentage = _percentage;
        emit MinOutPercentageSet(_percentage);
    }

    /**
     * @dev Returns the staked amount for a user
     * @param _user Address of the user
     * @return The amount of tokens staked
     */
    function userAmount(address _user) external view returns (uint256) {
        return userInfo[_user].amount;
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

        // Execute the swap using our internal swap function
        // For sweep operations, we use minOutPercentage/2 for less strict slippage protection
        uint256 amountOut = _swapTokens(
            _token, // tokenIn
            address(rewardToken), // tokenOut
            balance, // amountIn
            address(this) // recipient
        );

        // Update the lastRewardBalance to account for the new rewards
        _updateRewards();

        // Emit the sweep event
        emit TokenSwept(_token, balance, amountOut);

        return amountOut;
    }

    /**
     * @dev Reinvests a user's rewards back into their stake
     * 1. Claims rewards to this contract
     * 2. Swaps reward tokens for staking tokens using Uniswap
     * 3. Adds the new staking tokens to the user's stake
     * @return stakingTokensReceived The amount of staking tokens received and reinvested
     */
    function reinvest() external nonReentrant returns (uint256) {
        require(defaultRouter != address(0), "Stake: default router not set");

        // Step 1: Update rewards to ensure all pending rewards are accounted for
        _updateRewards();

        // Step 2: Check if user has pending rewards to reinvest
        UserInfo storage user = userInfo[msg.sender];
        uint256 pending = (user.amount * accRewardPerShare) / 1e12 - user.rewardDebt;
        require(pending > 0, "Stake: no rewards to reinvest");

        // Step 3: Claim rewards internally
        uint256 rewardAmount = _claimRewards(msg.sender);

        // Emit RewardClaimed event
        emit RewardClaimed(msg.sender, rewardAmount);

        // Get initial staking token balance before swap
        uint256 stakingTokenBalanceBefore = stakingToken.balanceOf(address(this));

        // Execute swap from reward tokens to staking tokens
        _swapTokens(
            address(rewardToken), // tokenIn
            address(stakingToken), // tokenOut
            rewardAmount, // amountIn
            address(this) // recipient
        );

        // Step 7: Calculate how many staking tokens we received
        uint256 stakingTokenBalanceAfter = stakingToken.balanceOf(address(this));
        uint256 stakingTokensReceived = stakingTokenBalanceAfter - stakingTokenBalanceBefore;

        require(stakingTokensReceived > 0, "Stake: swap did not yield any staking tokens");

        // Step 8: Re-use deposit logic to add tokens to user's stake
        // No need to transfer tokens as they're already in this contract

        // Update user staking amount
        user.amount += stakingTokensReceived;
        totalStaked += stakingTokensReceived;

        // Update user reward debt
        user.rewardDebt = (user.amount * accRewardPerShare) / 1e12;

        emit Deposited(msg.sender, stakingTokensReceived);
        emit Reinvested(msg.sender, rewardAmount, stakingTokensReceived);

        return stakingTokensReceived;
    }

    /**
     * @dev Internal function to claim rewards for a user
     * @param _user Address of the user claiming rewards
     * @return rewardAmount Amount of rewards claimed
     */
    function _claimRewards(address _user) internal returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 pending = (user.amount * accRewardPerShare) / 1e12 - user.rewardDebt;

        if (pending == 0) {
            return 0;
        }

        // Check if we have enough reward token balance
        uint256 currentRewardBalance = rewardToken.balanceOf(address(this));
        uint256 rewardAmount = pending > currentRewardBalance ? currentRewardBalance : pending;

        // Important: Update lastRewardBalance to track that these tokens are being claimed
        lastRewardBalance -= rewardAmount;

        // Update reward debt to reflect that rewards have been claimed
        user.rewardDebt = (user.amount * accRewardPerShare) / 1e12;

        return rewardAmount;
    }

    /**
     * @dev Internal function to swap tokens using Uniswap router
     * @param _tokenIn Address of input token
     * @param _tokenOut Address of output token
     * @param _amountIn Amount of input tokens to swap
     * @param _recipient Address to receive the swapped tokens
     * @return amountOut Amount of output tokens received
     */
    function _swapTokens(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        address _recipient
    ) internal returns (uint256) {
        require(defaultRouter != address(0), "Stake: default router not set");
        require(_amountIn > 0, "Stake: amount to swap must be greater than 0");

        // Setup the swap path
        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;

        // Approve the router to spend tokens
        IERC20(_tokenIn).approve(defaultRouter, _amountIn);

        // Get quote from router for expected output
        uint256[] memory amountsOut;
        uint256 expectedOut = 0;

        try IUniswapRouter(defaultRouter).getAmountsOut(_amountIn, path) returns (uint256[] memory output) {
            amountsOut = output;
            if (amountsOut.length > 1) {
                expectedOut = amountsOut[amountsOut.length - 1];
            }
        } catch {}

        uint256 amountOutMin = expectedOut > 0 ? (expectedOut * minOutPercentage) / 100 : 1; // Fallback to minimal value if quote fails

        // Execute the swap
        IUniswapRouter router = IUniswapRouter(defaultRouter);
        uint256[] memory amounts = router.swapExactTokensForTokens(
            _amountIn,
            amountOutMin,
            path,
            _recipient,
            block.timestamp + 1 hours // deadline
        );

        // Clear the approval
        IERC20(_tokenIn).approve(defaultRouter, 0);

        // Return the amount of output tokens received
        return amounts[amounts.length - 1];
    }

    /**
     * @dev Returns the amount of rewards that are currently unvested
     * @return The amount of unvested rewards
     */
    function getUnvestedAmount() public view returns (uint256) {
        if (vestingAmount == 0) return 0;

        uint256 timeSinceLastVesting = block.timestamp - lastVestingStartTime;

        // If vesting period is complete, nothing is unvested
        if (timeSinceLastVesting >= VESTING_PERIOD) {
            return 0;
        }

        // Calculate unvested amount linearly
        return (vestingAmount * (VESTING_PERIOD - timeSinceLastVesting)) / VESTING_PERIOD;
    }

    /**
     * @dev Returns the amount of rewards that are currently vested and available
     * @return The amount of vested rewards
     */
    function getVestedAmount() public view returns (uint256) {
        if (vestingAmount == 0) return 0;

        uint256 timeSinceLastVesting = block.timestamp - lastVestingStartTime;

        // If vesting period is complete, everything is vested
        if (timeSinceLastVesting >= VESTING_PERIOD) {
            return vestingAmount;
        }

        // Calculate vested amount linearly
        return (vestingAmount * timeSinceLastVesting) / VESTING_PERIOD;
    }

    // Add new getter functions
    function getCurrentVestingInfo() external view returns (uint256 amount, uint256 startTime) {
        return (vestingAmount, lastVestingStartTime);
    }
}
