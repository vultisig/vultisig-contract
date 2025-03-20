// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IERC1363Spender.sol";
import "./interfaces/IUniswapRouter.sol";
import "./StakeSweeper.sol";

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
    event SweeperSet(address indexed newSweeper);

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

    // Update state variables
    uint256 private constant VESTING_PERIOD = 24 hours;
    uint256 private vestingAmount;
    uint256 private lastDistributionTimestamp;

    StakeSweeper public sweeper;

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
            return 0;
        }

        uint256 currentRewardBalance = rewardToken.balanceOf(address(this));
        uint256 newRewards = currentRewardBalance > lastRewardBalance ? currentRewardBalance - lastRewardBalance : 0;

        // If there are new rewards, add them to vesting
        if (newRewards > 0) {
            // If there's still unvested amount, add it to the new rewards
            uint256 unvestedAmount = getUnvestedAmount();
            vestingAmount = unvestedAmount + newRewards;
            lastDistributionTimestamp = block.timestamp;
            emit VestingStarted(vestingAmount, lastDistributionTimestamp);
        }

        // Calculate newly vested amount
        uint256 totalVested = totalAssets();
        uint256 newlyVested = totalVested > lastRewardBalance ? totalVested - lastRewardBalance : 0;

        if (newlyVested > 0) {
            accRewardPerShare += (newlyVested * 1e12) / totalStaked;
            lastRewardBalance = totalVested;
            emit RewardsUpdated(accRewardPerShare, newlyVested);
        }

        return newlyVested;
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

        // 1. Update rewards and claim them
        _updateRewards();
        uint256 rewardAmount = _claimRewards(msg.sender);

        // Transfer rewards to user if any
        if (rewardAmount > 0) {
            rewardToken.safeTransfer(msg.sender, rewardAmount);
            emit RewardClaimed(msg.sender, rewardAmount);
        }

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
     * @dev Sets the sweeper contract address
     * @param _sweeper Address of the new sweeper contract
     */
    function setSweeper(address _sweeper) external onlyOwner {
        require(_sweeper != address(0), "Stake: sweeper is zero address");
        sweeper = StakeSweeper(_sweeper);
        emit SweeperSet(_sweeper);
    }

    /**
     * @dev Sweeps a token from the contract into reward tokens using the sweeper
     * @param _token Address of the token to sweep (can't be staking or reward token)
     * @return The amount of reward tokens received from the swap
     */
    function sweepTokenIntoRewards(address _token) external nonReentrant returns (uint256) {
        require(address(sweeper) != address(0), "Stake: sweeper not set");
        require(_token != address(stakingToken), "Stake: cannot sweep staking token");
        require(_token != address(rewardToken), "Stake: cannot sweep reward token");

        // Get the token balance
        IERC20 token = IERC20(_token);
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "Stake: no tokens to sweep");

        // Approve sweeper to spend tokens
        token.safeTransfer(address(sweeper), balance);

        // Execute sweep and get reward tokens back
        uint256 amountOut = sweeper.sweep(_token, address(this));

        // Update rewards
        _updateRewards();

        emit TokenSwept(_token, balance, amountOut);
        return amountOut;
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
     * @dev Returns the amount of rewards that are currently unvested
     * @return The amount of unvested rewards
     */
    function getUnvestedAmount() public view returns (uint256) {
        uint256 timeSinceLastDistribution = block.timestamp - lastDistributionTimestamp;

        if (timeSinceLastDistribution >= VESTING_PERIOD) {
            return 0;
        }

        return (vestingAmount * (VESTING_PERIOD - timeSinceLastDistribution)) / VESTING_PERIOD;
    }

    /**
     * @dev Returns the amount of rewards that are currently vested and available
     * @return The amount of vested rewards
     */
    function getVestedAmount() public view returns (uint256) {
        if (vestingAmount == 0) return 0;

        uint256 timeSinceLastVesting = block.timestamp - lastDistributionTimestamp;

        // If vesting period is complete, everything is vested
        if (timeSinceLastVesting >= VESTING_PERIOD) {
            return vestingAmount;
        }

        // Calculate vested amount linearly
        return (vestingAmount * timeSinceLastVesting) / VESTING_PERIOD;
    }

    function totalAssets() public view returns (uint256) {
        return rewardToken.balanceOf(address(this)) - getUnvestedAmount();
    }

    // Add new getter functions
    function getCurrentVestingInfo() external view returns (uint256 amount, uint256 startTime) {
        return (vestingAmount, lastDistributionTimestamp);
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

        // Only allow claiming up to the vested amount
        uint256 vested = totalAssets();
        uint256 rewardAmount = pending > vested ? vested : pending;

        // Update reward debt
        user.rewardDebt = (user.amount * accRewardPerShare) / 1e12;

        return rewardAmount;
    }

    /**
     * @dev Reinvests a user's rewards back into their stake
     * 1. Claims rewards to this contract
     * 2. Swaps reward tokens for staking tokens using the sweeper
     * 3. Adds the new staking tokens to the user's stake
     * @return stakingTokensReceived The amount of staking tokens received and reinvested
     */
    function reinvest() external nonReentrant returns (uint256) {
        require(address(sweeper) != address(0), "Stake: sweeper not set");

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

        // Approve sweeper to spend reward tokens
        rewardToken.approve(address(sweeper), rewardAmount);

        // Execute sweep from reward tokens to staking tokens
        uint256 amountOut = sweeper.sweep(address(rewardToken), address(this));

        // Clear approval
        rewardToken.approve(address(sweeper), 0);

        // Calculate how many staking tokens we received
        uint256 stakingTokenBalanceAfter = stakingToken.balanceOf(address(this));
        uint256 stakingTokensReceived = stakingTokenBalanceAfter - stakingTokenBalanceBefore;

        require(stakingTokensReceived > 0, "Stake: swap did not yield any staking tokens");

        // Update user staking amount
        user.amount += stakingTokensReceived;
        totalStaked += stakingTokensReceived;

        // Update user reward debt
        user.rewardDebt = (user.amount * accRewardPerShare) / 1e12;

        emit Deposited(msg.sender, stakingTokensReceived);
        emit Reinvested(msg.sender, rewardAmount, stakingTokensReceived);

        return stakingTokensReceived;
    }
}
