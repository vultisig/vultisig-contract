// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/Stake.sol";
import "../contracts/StakeSweeper.sol";
import {Token as VultToken} from "../contracts/Token.sol";
import "../contracts/mocks/MockUniswapRouter.sol";

contract StakeReinvestTest is Test {
    // Contracts
    Stake public stake;
    StakeSweeper public sweeper;
    VultToken public stakingToken;
    VultToken public rewardToken;
    MockUniswapRouter public router;

    // Actors
    address public owner = address(1);
    address public user = address(2);

    // Constants for testing
    uint256 public constant STAKE_AMOUNT = 1000 * 1e18;
    uint256 public constant REWARD_AMOUNT = 100 * 1e18;

    function setUp() public {
        vm.startPrank(owner);

        // Deploy tokens
        stakingToken = new VultToken("Staking Token", "STK");
        rewardToken = new VultToken("Reward Token", "RWD");

        // Mint tokens
        stakingToken.mint(10000 * 1e18);
        rewardToken.mint(10000 * 1e18);

        // Deploy mock router
        router = new MockUniswapRouter();

        // Deploy sweeper first
        sweeper = new StakeSweeper(address(rewardToken), address(router));

        // Deploy stake contract
        stake = new Stake(address(stakingToken), address(rewardToken));

        // Set sweeper for the stake contract
        stake.setSweeper(address(sweeper));

        // Transfer tokens to user
        stakingToken.transfer(user, STAKE_AMOUNT * 2);

        // Set up the mock router
        router.setExchangeRate(address(rewardToken), address(stakingToken), 9, 10);

        // Pre-fund the router with staking tokens
        stakingToken.transfer(address(router), 1000 * 1e18);
        rewardToken.transfer(address(router), 1000 * 1e18);

        vm.stopPrank();
    }

    function test_BasicReinvest() public {
        // User stakes tokens
        vm.startPrank(user);
        stakingToken.approve(address(stake), STAKE_AMOUNT);
        stake.deposit(STAKE_AMOUNT);
        vm.stopPrank();

        // Owner sends rewards
        vm.prank(owner);
        rewardToken.transfer(address(stake), REWARD_AMOUNT);

        // Initial interaction to detect rewards
        stake.claim();

        // Wait for full vesting period
        vm.warp(block.timestamp + 24 hours);

        // Get user stake amount before reinvesting
        uint256 userStakeBefore = stake.userAmount(user);

        // Execute reinvestment
        vm.prank(user);
        uint256 reinvestedAmount = stake.reinvest();

        // Verify results
        assertGt(reinvestedAmount, 0, "Should have reinvested some tokens");
        assertEq(
            stake.userAmount(user),
            userStakeBefore + reinvestedAmount,
            "Stake should have increased by reinvested amount"
        );
    }

    function test_SlippageProtection() public {
        // Test sweeper's minOutPercentage validation
        vm.startPrank(owner);

        vm.expectRevert("StakeSweeper: percentage must be between 1-100");
        sweeper.setMinOutPercentage(101);

        vm.expectRevert("StakeSweeper: percentage must be between 1-100");
        sweeper.setMinOutPercentage(0);

        sweeper.setMinOutPercentage(95);
        assertEq(sweeper.minOutPercentage(), 95);

        vm.stopPrank();
    }

    function test_RevertNoSweeper() public {
        // Deploy new stake contract with no sweeper set
        vm.startPrank(owner);
        Stake noSweeperStake = new Stake(address(stakingToken), address(rewardToken));

        // Transfer some tokens to the new stake contract for testing
        rewardToken.transfer(address(noSweeperStake), REWARD_AMOUNT);
        stakingToken.transfer(user, STAKE_AMOUNT);
        vm.stopPrank();

        // Set up user stake
        vm.startPrank(user);
        stakingToken.approve(address(noSweeperStake), STAKE_AMOUNT);
        noSweeperStake.deposit(STAKE_AMOUNT);

        // Try to reinvest with no sweeper set
        vm.expectRevert("Stake: sweeper not set");
        noSweeperStake.reinvest();

        vm.stopPrank();
    }

    // Test with no rewards
    function test_RevertNoRewards() public {
        // User stakes tokens but has no rewards
        vm.startPrank(user);
        stakingToken.approve(address(stake), STAKE_AMOUNT);
        stake.deposit(STAKE_AMOUNT);

        // Try to reinvest with no rewards
        vm.expectRevert("Stake: no rewards to reinvest");
        stake.reinvest();

        vm.stopPrank();
    }

    // Test with rewards already claimed (no pending rewards)
    function test_RevertRewardsAlreadyClaimed() public {
        // User stakes tokens
        vm.startPrank(user);
        stakingToken.approve(address(stake), STAKE_AMOUNT);
        stake.deposit(STAKE_AMOUNT);
        vm.stopPrank();

        // Owner sends rewards
        vm.prank(owner);
        rewardToken.transfer(address(stake), REWARD_AMOUNT);

        // Initial interaction to detect rewards
        stake.claim();

        // Wait for full vesting
        vm.warp(block.timestamp + 24 hours);

        // Claim rewards
        vm.prank(user);
        stake.claim();

        // Try reinvest after already claiming rewards
        vm.startPrank(user);
        vm.expectRevert("Stake: no rewards to reinvest");
        stake.reinvest();
        vm.stopPrank();
    }

    // Test reinvest after partial reward claim
    function test_ReinvestAfterPartialClaim() public {
        // User stakes tokens
        vm.startPrank(user);
        stakingToken.approve(address(stake), STAKE_AMOUNT);
        stake.deposit(STAKE_AMOUNT);
        vm.stopPrank();

        // Owner sends first batch of rewards
        vm.prank(owner);
        rewardToken.transfer(address(stake), REWARD_AMOUNT * 2);

        // Initial interaction to detect rewards
        stake.claim();

        // Wait for full vesting period
        vm.warp(block.timestamp + 24 hours);

        // User claims half the rewards
        vm.prank(user);
        stake.claim();

        // Send more rewards
        vm.prank(owner);
        rewardToken.transfer(address(stake), REWARD_AMOUNT);

        // Initial interaction to detect new rewards
        stake.claim();

        // Wait for new rewards to vest
        vm.warp(block.timestamp + 24 hours);

        // Get user stake amount before reinvesting
        uint256 userStakeBefore = stake.userAmount(user);

        // Now reinvest the remaining rewards
        vm.prank(user);
        uint256 reinvestedAmount = stake.reinvest();

        // Verify results
        assertGt(reinvestedAmount, 0, "Should have reinvested some tokens");
        assertEq(stake.userAmount(user), userStakeBefore + reinvestedAmount, "Stake should have increased");
    }

    // Test that reinvest emits correct events
    function test_ReinvestEvents() public {
        // User stakes tokens
        vm.startPrank(user);
        stakingToken.approve(address(stake), STAKE_AMOUNT);
        stake.deposit(STAKE_AMOUNT);
        vm.stopPrank();

        // Owner sends rewards
        vm.prank(owner);
        rewardToken.transfer(address(stake), REWARD_AMOUNT);

        // Initial interaction to detect rewards
        stake.claim();

        // Wait for full vesting period
        vm.warp(block.timestamp + 24 hours);

        // Record logs and execute reinvestment
        vm.recordLogs();
        vm.prank(user);
        stake.reinvest();

        // Verify logs
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool foundRewardClaimed = false;
        bool foundDeposited = false;
        bool foundReinvested = false;

        for (uint256 i = 0; i < entries.length; i++) {
            // Check for RewardClaimed event
            if (entries[i].topics[0] == keccak256("RewardClaimed(address,uint256)")) {
                address eventUser = address(uint160(uint256(entries[i].topics[1])));
                assertEq(eventUser, user, "RewardClaimed event has wrong user");
                foundRewardClaimed = true;
            }
            // Check for Deposited event
            if (entries[i].topics[0] == keccak256("Deposited(address,uint256)")) {
                address eventUser = address(uint160(uint256(entries[i].topics[1])));
                assertEq(eventUser, user, "Deposited event has wrong user");
                foundDeposited = true;
            }
            // Check for Reinvested event
            if (entries[i].topics[0] == keccak256("Reinvested(address,uint256,uint256)")) {
                address eventUser = address(uint160(uint256(entries[i].topics[1])));
                assertEq(eventUser, user, "Reinvested event has wrong user");
                foundReinvested = true;
            }
        }

        assertTrue(foundRewardClaimed, "RewardClaimed event not emitted");
        assertTrue(foundDeposited, "Deposited event not emitted");
        assertTrue(foundReinvested, "Reinvested event not emitted");
    }

    function test_SweepTokens() public {
        // Deploy some other token to sweep
        vm.startPrank(owner);
        VultToken extraToken = new VultToken("Extra Token", "EXTRA");
        extraToken.mint(1000 * 1e18);
        extraToken.transfer(address(stake), 100 * 1e18);
        vm.stopPrank();

        // Setup router for the extra token
        router.setExchangeRate(address(extraToken), address(rewardToken), 1, 1);

        // Record initial balances
        uint256 initialRewardBalance = rewardToken.balanceOf(address(stake));

        // Sweep the extra tokens
        vm.prank(user); // Anyone can call sweep
        uint256 sweptAmount = stake.sweepTokenIntoRewards(address(extraToken));

        // Verify results
        assertGt(sweptAmount, 0, "Should have received reward tokens");
        assertGt(
            rewardToken.balanceOf(address(stake)),
            initialRewardBalance,
            "Reward token balance should have increased"
        );
        assertEq(extraToken.balanceOf(address(stake)), 0, "Extra tokens should have been fully swept");
    }

    function test_RevertSweepProtectedTokens() public {
        vm.startPrank(user);

        // Cannot sweep staking token
        vm.expectRevert("Stake: cannot sweep staking token");
        stake.sweepTokenIntoRewards(address(stakingToken));

        // Cannot sweep reward token
        vm.expectRevert("Stake: cannot sweep reward token");
        stake.sweepTokenIntoRewards(address(rewardToken));

        vm.stopPrank();
    }
}
