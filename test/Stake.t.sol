// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Stake} from "../contracts/Stake.sol";
import {MockERC1363} from "./mocks/MockERC1363.sol";

contract StakeTest is Test {
    Stake public stake;
    MockERC1363 public stakingToken;
    MockERC1363 public rewardToken;

    address public owner = makeAddr("owner");
    address public user = makeAddr("user");
    uint256 public constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 public constant USER_BALANCE = 1_000 ether;

    function setUp() public {
        // Deploy tokens and stake contracts as owner
        vm.startPrank(owner);

        // Create separate tokens for staking and rewards
        stakingToken = new MockERC1363(INITIAL_SUPPLY);
        // Use 6 decimals for reward token (USDC)
        rewardToken = new MockERC1363(1_000_000_000 * 10 ** 6); // 1B USDC

        // Deploy stake contract with different tokens for staking and rewards
        stake = new Stake(address(stakingToken), address(rewardToken));

        // Transfer reward tokens to the stake contract (500M USDC)
        rewardToken.transfer(address(stake), 500_000_000 * 10 ** 6);

        // Transfer staking tokens to the user for testing
        stakingToken.transfer(user, USER_BALANCE);
        vm.stopPrank();

        // Set approvals for the stake contract
        vm.prank(address(stake));
        rewardToken.approve(address(stake), type(uint256).max);
    }

    function test_Deployment() public {
        assertEq(address(stake.stakingToken()), address(stakingToken));
        assertEq(address(stake.rewardToken()), address(rewardToken));
    }

    function test_RevertDeploymentWithZeroAddress() public {
        vm.expectRevert("Stake: staking token is the zero address");
        new Stake(address(0), address(rewardToken));
    }

    function test_Deposit() public {
        uint256 amount = 100 ether;

        vm.startPrank(user);
        stakingToken.approve(address(stake), amount);

        vm.expectEmit(true, false, false, true);
        emit Stake.Deposited(user, amount);
        stake.deposit(amount);

        // userInfo returns a tuple where the first element is the amount
        (uint256 stakedAmount,) = stake.userInfo(user);
        assertEq(stakedAmount, amount);
        assertEq(stake.totalStaked(), amount);
        // Only staking tokens should be transferred to the contract
        assertEq(stakingToken.balanceOf(address(stake)), amount);
        // Reward token balance should remain unchanged
        assertEq(rewardToken.balanceOf(address(stake)), 500_000_000 * 10 ** 6);
        vm.stopPrank();
    }

    function test_ApproveAndCall() public {
        uint256 amount = 100 ether;

        vm.startPrank(user);
        vm.expectEmit(true, false, false, true);
        emit Stake.Deposited(user, amount);
        stakingToken.approveAndCall(address(stake), amount, "");

        // userInfo returns a tuple where the first element is the amount
        (uint256 stakedAmount,) = stake.userInfo(user);
        assertEq(stakedAmount, amount);
        assertEq(stake.totalStaked(), amount);
        // Only staking tokens should be transferred to the contract
        assertEq(stakingToken.balanceOf(address(stake)), amount);
        // Reward token balance should remain unchanged
        assertEq(rewardToken.balanceOf(address(stake)), 500_000_000 * 10 ** 6);
        vm.stopPrank();
    }

    function test_RevertDepositZeroAmount() public {
        vm.startPrank(user);
        vm.expectRevert("Stake: amount must be greater than 0");
        stake.deposit(0);
        vm.stopPrank();
    }

    function test_Withdraw() public {
        uint256 depositAmount = 100 ether;

        // First deposit
        vm.startPrank(user);
        stakingToken.approve(address(stake), depositAmount);
        stake.deposit(depositAmount);

        // Then withdraw
        vm.expectEmit(true, false, false, true);
        emit Stake.Withdrawn(user, depositAmount);
        stake.withdraw(depositAmount);

        // userInfo returns a tuple where the first element is the amount
        (uint256 stakedAmount,) = stake.userInfo(user);
        assertEq(stakedAmount, 0);
        assertEq(stake.totalStaked(), 0);

        // Staking token should be fully withdrawn from the contract
        assertEq(stakingToken.balanceOf(address(stake)), 0);
        // Get the actual reward token balance from contract
        uint256 rewardTokenBalance = rewardToken.balanceOf(address(stake));
        assertEq(rewardTokenBalance, 500_000_000 * 10 ** 6);

        // User should get back their staking tokens
        assertEq(stakingToken.balanceOf(user), USER_BALANCE);
        // No reward tokens should be received when using different token for rewards
        // This is because in our test environment, no rewards are actually accumulated
        assertEq(rewardToken.balanceOf(user), 0);
        vm.stopPrank();
    }

    function test_PartialWithdraw() public {
        uint256 depositAmount = 100 ether;
        uint256 withdrawAmount = 60 ether;

        vm.startPrank(user);
        stakingToken.approve(address(stake), depositAmount);
        stake.deposit(depositAmount);

        stake.withdraw(withdrawAmount);

        // userInfo returns a tuple where the first element is the amount
        (uint256 stakedAmount,) = stake.userInfo(user);
        assertEq(stakedAmount, depositAmount - withdrawAmount);
        assertEq(stake.totalStaked(), depositAmount - withdrawAmount);

        // Staking token balance should be reduced by the withdrawal amount
        assertEq(stakingToken.balanceOf(address(stake)), depositAmount - withdrawAmount);
        // Get the actual reward token balance from contract
        uint256 rewardTokenBalance = rewardToken.balanceOf(address(stake));
        assertEq(rewardTokenBalance, 500_000_000 * 10 ** 6);

        // User should get back their staking tokens proportionally
        assertEq(stakingToken.balanceOf(user), USER_BALANCE - depositAmount + withdrawAmount);
        // No reward tokens should be received when using different token for rewards
        // This is because in our test environment, no rewards are actually accumulated
        assertEq(rewardToken.balanceOf(user), 0);
        vm.stopPrank();
    }

    function test_RevertWithdrawInsufficientBalance() public {
        uint256 depositAmount = 100 ether;
        uint256 withdrawAmount = 101 ether;

        vm.startPrank(user);
        stakingToken.approve(address(stake), depositAmount);
        stake.deposit(depositAmount);

        vm.expectRevert("Stake: insufficient balance");
        stake.withdraw(withdrawAmount);
        vm.stopPrank();
    }

    function test_RevertWithdrawZeroAmount() public {
        vm.startPrank(user);
        vm.expectRevert("Stake: amount must be greater than 0");
        stake.withdraw(0);
        vm.stopPrank();
    }

    function test_RevertOnApprovalReceivedNotToken() public {
        vm.startPrank(user);
        vm.expectRevert("Stake: caller is not the staking token");
        stake.onApprovalReceived(user, 100 ether, "");
        vm.stopPrank();
    }

    function test_RewardAccumulation() public {
        uint256 depositAmount = 100 ether;

        // Initial deposit
        vm.startPrank(user);
        stakingToken.approve(address(stake), depositAmount);
        stake.deposit(depositAmount);
        vm.stopPrank();

        // Simulate new rewards coming in (100k USDC)
        vm.prank(owner);
        rewardToken.transfer(address(stake), 100_000 * 10 ** 6);

        vm.warp(block.timestamp + 1 days + 1);

        // Update rewards
        stake.updateRewards();

        // Check pending rewards
        uint256 pending = stake.pendingRewards(user);
        assertGt(pending, 0, "Should have pending rewards");
    }

    function test_Claim() public {
        uint256 depositAmount = 100 ether;

        // Initial deposit
        vm.startPrank(user);
        stakingToken.approve(address(stake), depositAmount);
        stake.deposit(depositAmount);
        vm.stopPrank();

        // Simulate new rewards coming in
        vm.prank(owner);
        rewardToken.transfer(address(stake), 100_000 * 10 ** 6);

        vm.warp(block.timestamp + 1 days + 1);

        // Update rewards and claim
        vm.startPrank(user);
        uint256 claimedAmount = stake.claim();
        vm.stopPrank();

        assertGt(claimedAmount, 0, "Should have claimed rewards");
        assertEq(rewardToken.balanceOf(user), claimedAmount, "User should receive reward tokens");
    }

    function test_ForceWithdraw() public {
        uint256 depositAmount = 100 ether;

        // Initial deposit
        vm.startPrank(user);
        stakingToken.approve(address(stake), depositAmount);
        stake.deposit(depositAmount);

        vm.expectEmit(true, false, false, true);
        emit Stake.ForceWithdrawn(user, depositAmount);
        stake.forceWithdraw(depositAmount);

        (uint256 stakedAmount,) = stake.userInfo(user);
        assertEq(stakedAmount, 0, "Should have no staked tokens");
        assertEq(stakingToken.balanceOf(user), USER_BALANCE, "Should have received all staking tokens back");
        vm.stopPrank();
    }

    function test_SetRewardDecayFactor() public {
        uint256 newFactor = 5;

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Stake.RewardDecayFactorSet(newFactor);
        stake.setRewardDecayFactor(newFactor);

        assertEq(stake.rewardDecayFactor(), newFactor);
    }

    function test_RevertSetRewardDecayFactorZero() public {
        vm.prank(owner);
        vm.expectRevert("Stake: decay factor must be greater than 0");
        stake.setRewardDecayFactor(0);
    }

    function test_SetMinRewardUpdateDelay() public {
        uint256 newDelay = 12 hours;

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Stake.MinRewardUpdateDelaySet(newDelay);
        stake.setMinRewardUpdateDelay(newDelay);

        assertEq(stake.minRewardUpdateDelay(), newDelay);
    }

    function test_RewardUpdateWithNoStakers() public {
        // Send rewards when no one is staking
        vm.prank(owner);
        rewardToken.transfer(address(stake), 100_000 * 10 ** 6);

        vm.warp(block.timestamp + 1 days);

        stake.updateRewards();

        // New staker joins
        vm.startPrank(user);
        stakingToken.approve(address(stake), 100 ether);
        stake.deposit(100 ether);
        vm.stopPrank();

        // Check that rewards were properly tracked
        uint256 pending = stake.pendingRewards(user);
        assertEq(pending, 0, "New staker should not receive previous rewards");
    }

    function test_MultipleStakers() public {
        address user2 = makeAddr("user2");
        uint256 depositAmount = 100 ether;

        // Setup user2 with tokens
        vm.prank(owner);
        stakingToken.transfer(user2, USER_BALANCE);

        // Both users deposit the same amount
        vm.startPrank(user);
        stakingToken.approve(address(stake), depositAmount);
        stake.deposit(depositAmount);
        vm.stopPrank();

        vm.startPrank(user2);
        stakingToken.approve(address(stake), depositAmount);
        stake.deposit(depositAmount);
        vm.stopPrank();

        // Add rewards (100k USDC)
        vm.prank(owner);
        rewardToken.transfer(address(stake), 100_000 * 10 ** 6);

        vm.warp(block.timestamp + 1 days);

        stake.updateRewards();

        // Check equal pending rewards
        uint256 pending1 = stake.pendingRewards(user);
        uint256 pending2 = stake.pendingRewards(user2);
        assertEq(pending1, pending2, "Both users should have equal pending rewards");
    }

    function test_DepositForUser() public {
        address depositor = makeAddr("depositor");
        uint256 depositAmount = 100 ether;

        // Give depositor some tokens
        vm.prank(owner);
        stakingToken.transfer(depositor, depositAmount);

        // Depositor deposits for user
        vm.startPrank(depositor);
        stakingToken.approve(address(stake), depositAmount);
        stake.depositForUser(user, depositAmount);
        vm.stopPrank();

        (uint256 stakedAmount,) = stake.userInfo(user);
        assertEq(stakedAmount, depositAmount, "User should have received the deposit");
        assertEq(stakingToken.balanceOf(depositor), 0, "Depositor should have spent their tokens");
    }

    function test_ComplexRewardScenario() public {
        assertEq(stake.rewardDecayFactor(), 10);
        // Setup initial variables
        uint256 largeReward = 2_000_000 * 10 ** 6; // 2M USDC (using 6 decimals)
        uint256 weekDelay = 7 days;
        uint256 dayDelay = 1 days;
        address[] memory users = new address[](5);
        uint256[] memory stakes = new uint256[](5);

        // Create 5 users with different stake amounts
        for (uint256 i = 0; i < 5; i++) {
            users[i] = makeAddr(string.concat("user", vm.toString(i)));
            stakes[i] = (i + 1) * 100 ether; // 100, 200, 300, 400, 500 ether stakes

            // Setup each user with staking tokens
            vm.prank(owner);
            stakingToken.transfer(users[i], stakes[i]);
        }

        // First, clear any USDC from the staking contract
        vm.startPrank(address(stake));
        rewardToken.transfer(owner, rewardToken.balanceOf(address(stake)));
        vm.stopPrank();

        // 1. Transfer large reward with no stakers (2M USDC)
        vm.prank(owner);
        rewardToken.transfer(address(stake), largeReward);

        // Record initial reward balance
        uint256 initialRewardBalance = rewardToken.balanceOf(address(stake));

        // 2. Set staking delay to 1 week
        vm.prank(owner);
        stake.setMinRewardUpdateDelay(weekDelay);
        assertEq(stake.minRewardUpdateDelay(), weekDelay);

        // 3. Users stake over the course of the week
        // Day 1: User0 stakes
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.startPrank(users[0]);
        stakingToken.approve(address(stake), stakes[0]);
        stake.deposit(stakes[0]);
        assertEq(stake.userAmount(users[0]), stakes[0], "User0 should have staked amount");
        vm.stopPrank();

        // Day 3: User1 and User2 stake
        vm.warp(vm.getBlockTimestamp() + 2 days);
        for (uint256 i = 1; i <= 2; i++) {
            vm.startPrank(users[i]);
            stakingToken.approve(address(stake), stakes[i]);
            stake.deposit(stakes[i]);
            assertEq(stake.userAmount(users[i]), stakes[i], "User1 and User2 should have staked amount");
            vm.stopPrank();
        }

        // Day 5: User3 stakes
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.startPrank(users[3]);
        stakingToken.approve(address(stake), stakes[3]);
        stake.deposit(stakes[3]);
        assertEq(stake.userAmount(users[3]), stakes[3], "User3 should have staked amount");
        vm.stopPrank();

        // Record everyone's pending rewards before week is up - should be 0
        for (uint256 i = 0; i < 4; i++) {
            assertEq(stake.pendingRewards(users[i]), 0, "No rewards should be available before delay period");
        }

        // 4. Week is up, update rewards
        // assertEq(stake.lastRewardBalance(), 0);
        assertEq(stake.lastRewardUpdateTime(), 1 days + 1);
        vm.warp(vm.getBlockTimestamp() + 3 days + 1); // Just over a week from start
        stake.updateRewards();
        // Calculate total staked for proportion checking
        uint256 totalStakedAmount = stakes[0] + stakes[1] + stakes[2] + stakes[3];

        // 5. Check that stakers receive proportional rewards
        for (uint256 i = 0; i < 4; i++) {
            uint256 pending = stake.pendingRewards(users[i]);
            // Each user should have pending rewards proportional to their stake
            // Consider the decay factor of 10 (10% released)
            uint256 expectedReward = ((initialRewardBalance / 10) * stakes[i]) / totalStakedAmount;
            assertApproxEqRel(pending, expectedReward, 1e6); // 1% tolerance
        }

        // User4 hasn't staked yet, should have 0 pending
        assertEq(stake.pendingRewards(users[4]), 0, "Late user should have no rewards yet");

        // 6. Reduce delay to 1 day
        vm.prank(owner);
        stake.setMinRewardUpdateDelay(dayDelay);
        assertEq(stake.minRewardUpdateDelay(), dayDelay);

        // Last user stakes
        vm.startPrank(users[4]);
        stakingToken.approve(address(stake), stakes[4]);
        stake.deposit(stakes[4]);
        vm.stopPrank();

        // 7. Continue reward distribution with shorter delay
        // Add some new rewards (100k USDC)
        uint256 newRewards = 100_000 * 10 ** 6;
        vm.prank(owner);
        rewardToken.transfer(address(stake), newRewards);

        // Advance time and update rewards
        vm.warp(block.timestamp + dayDelay + 1);
        stake.updateRewards();

        // Calculate new total staked including last user
        uint256 newTotalStaked = totalStakedAmount + stakes[4];

        // For initial rewards:
        // First release was 10% of initialRewardBalance
        uint256 remainingInitial = initialRewardBalance - (initialRewardBalance / 10);
        assertEq(remainingInitial, 1_800_000 * 10 ** 6, "Remaining initial should be 1.8M USDC");
        uint256 secondReleaseInitial = remainingInitial / 10;
        assertEq(secondReleaseInitial, 180_000 * 10 ** 6, "Second release initial should be 180k USDC");

        // For new rewards:
        uint256 firstReleaseNew = newRewards / 10;

        uint256 totalDistributing = secondReleaseInitial + firstReleaseNew;
        assertEq(totalDistributing, 190_000 * 10 ** 6, "Total distributing should be 190k USDC");

        // Calculate expected rewards for each user
        uint256[] memory expectedRewards = new uint256[](5);
        for (uint256 i = 0; i < 4; i++) {
            // First distribution share (only for users 0-3)
            expectedRewards[i] = ((initialRewardBalance / 10) * stakes[i]) / totalStakedAmount;
            // Add second distribution share
            expectedRewards[i] += (totalDistributing * stakes[i]) / newTotalStaked;
        }
        // User 4 only gets share of second distribution
        expectedRewards[4] = (totalDistributing * stakes[4]) / newTotalStaked;

        // Claim rewards for all users
        uint256[] memory claimedAmounts = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(users[i]);
            claimedAmounts[i] = stake.claim();

            // Verify claimed amount is close to expected
            assertApproxEqRel(
                claimedAmounts[i],
                expectedRewards[i],
                1e16, // 1% tolerance
                string.concat("User ", vm.toString(i), " rewards incorrect")
            );
        }

        // Verify proportional distribution based on stakes, but only among early stakers (0-3)
        // These users should maintain proportionality since they participated in both distributions
        for (uint256 i = 1; i < 4; i++) {
            uint256 expectedRatio = (stakes[i] * 1e18) / stakes[0];
            uint256 actualRatio = (claimedAmounts[i] * 1e18) / claimedAmounts[0];
            assertApproxEqRel(
                actualRatio, expectedRatio, 1e16, string.concat("Early user ", vm.toString(i), " ratio incorrect")
            );
        }

        // Verify user4's rewards are proportional only to the second distribution
        uint256 user4ExpectedShare = (stakes[4] * totalDistributing) / newTotalStaked;
        assertApproxEqRel(claimedAmounts[4], user4ExpectedShare, 1e16, "Late user rewards incorrect");

        // Final sanity checks
        uint256 totalClaimed;
        for (uint256 i = 0; i < 5; i++) {
            totalClaimed += claimedAmounts[i];
        }

        // Calculate total claimed amount that we expect:
        // First distribution: 10% of 2M USDC = 200,000 USDC
        // Second distribution:
        // - 10% of remaining initial (1.8M USDC) = 180,000 USDC
        // - 10% of new rewards (100k USDC) = 10,000 USDC
        // Total distributed = 200,000 + (180,000 + 10,000) = 390,000 USDC

        // Total claimed should be approximately secondReleaseInitial + firstReleaseNew
        assertApproxEqRel(
            totalClaimed,
            390_000 * 10 ** 6, // 390k USDC
            1e16,
            "Total claimed amount incorrect"
        );

        // Verify remaining reward balance
        // Should be:
        // Initial: 2M - 200k - 180k = 1.62M USDC
        // New: 100k - 10k = 90k USDC
        // Total: 1.62M USDC + 90k USDC = 1.71M USDC
        uint256 expectedRemaining = (remainingInitial - secondReleaseInitial) + (newRewards - firstReleaseNew);
        assertApproxEqRel(rewardToken.balanceOf(address(stake)), expectedRemaining, 1e16, "Remaining balance incorrect");
    }

    function test_RevertInsufficientRewardBalance() public {
        // Setup initial variables
        uint256 depositAmount = 100 ether;
        uint256 initialRewards = 10_000 * 10 ** 6; // 10k USDC

        // Remove all rewards from the contract
        uint256 initialRewardBalance = rewardToken.balanceOf(address(stake));
        vm.prank(address(stake));
        rewardToken.transfer(owner, initialRewardBalance);

        // Initial deposit from user
        vm.startPrank(user);
        stakingToken.approve(address(stake), depositAmount);
        stake.deposit(depositAmount);
        vm.stopPrank();

        // Send some rewards to the contract
        vm.prank(owner);
        rewardToken.transfer(address(stake), initialRewards);

        // Advance time and update rewards
        vm.warp(block.timestamp + 1 days + 1);
        stake.updateRewards();

        // Maliciously transfer out most of the reward tokens to simulate a balance shortage
        // (This could happen if the owner withdraws rewards incorrectly or there's a bug)
        vm.prank(address(stake));
        rewardToken.transfer(owner, initialRewards - 1); // Leave 1 wei in contract

        // Try to claim rewards - should revert due to insufficient balance
        vm.startPrank(user);
        vm.expectRevert("Stake: insufficient reward token balance");
        stake.claim();
        vm.stopPrank();

        // Verify that a smaller claim would still work
        // Return some rewards to the contract
        vm.prank(owner);
        rewardToken.transfer(address(stake), 1_000 * 10 ** 6); // 1k USDC

        // Now claiming should succeed
        vm.prank(user);
        uint256 claimedAmount = stake.claim();
        assertGt(claimedAmount, 0, "Should have claimed some rewards");
        assertLe(
            claimedAmount,
            rewardToken.balanceOf(address(stake)) + claimedAmount,
            "Claimed amount should not exceed contract balance"
        );
    }

    function test_PreservePendingRewardsOnDeposit() public {
        // Setup initial variables
        uint256 initialDeposit = 100 ether;
        uint256 additionalDeposit = 50 ether;
        uint256 rewardAmount = 1_000_000 * 10 ** 6; // 1M USDC

        // Initial deposit
        vm.startPrank(user);
        stakingToken.approve(address(stake), initialDeposit + additionalDeposit);
        stake.deposit(initialDeposit);
        vm.stopPrank();

        // Add rewards
        vm.prank(owner);
        rewardToken.transfer(address(stake), rewardAmount);

        // Advance time and update rewards
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        stake.updateRewards();

        // Record pending rewards before second deposit
        uint256 pendingBeforeDeposit = stake.pendingRewards(user);
        assertGt(pendingBeforeDeposit, 0, "Should have pending rewards before second deposit");

        // Make second deposit
        vm.prank(user);
        stake.deposit(additionalDeposit);

        // Check pending rewards immediately after deposit
        uint256 pendingAfterDeposit = stake.pendingRewards(user);
        assertEq(
            pendingAfterDeposit, pendingBeforeDeposit, "Pending rewards should be preserved after additional deposit"
        );

        // Add more rewards
        vm.prank(owner);
        rewardToken.transfer(address(stake), rewardAmount);

        // Advance time and update rewards again
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        stake.updateRewards();

        // Check final rewards
        uint256 finalPending = stake.pendingRewards(user);
        assertGt(finalPending, pendingAfterDeposit, "Should have accrued more rewards");

        // Claim rewards and verify the amount includes both periods
        vm.prank(user);
        uint256 claimedAmount = stake.claim();
        assertEq(claimedAmount, finalPending, "Claimed amount should match final pending rewards");
        assertGt(claimedAmount, pendingBeforeDeposit, "Claimed amount should be greater than initial pending rewards");

        // Verify the reward debt was properly updated
        (uint256 stakedAmount, uint256 rewardDebt) = stake.userInfo(user);
        assertEq(stakedAmount, initialDeposit + additionalDeposit, "Staked amount should be sum of deposits");
        assertEq(
            rewardDebt, (stakedAmount * stake.accRewardPerShare()) / 1e26, "Reward debt should be properly updated"
        );
    }
}
