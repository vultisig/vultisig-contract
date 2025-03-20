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
        rewardToken = new MockERC1363(INITIAL_SUPPLY);

        // Deploy stake contract with different tokens for staking and rewards
        stake = new Stake(address(stakingToken), address(rewardToken));

        // Transfer reward tokens to the stake contract
        rewardToken.transfer(address(stake), INITIAL_SUPPLY / 2);

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
        assertEq(rewardToken.balanceOf(address(stake)), INITIAL_SUPPLY / 2);
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
        assertEq(rewardToken.balanceOf(address(stake)), INITIAL_SUPPLY / 2);
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
        assertEq(rewardTokenBalance, 500000000000000000000000);

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
        assertEq(rewardTokenBalance, 500000000000000000000000);

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

        // Simulate new rewards coming in
        vm.prank(owner);
        rewardToken.transfer(address(stake), 100 ether);

        vm.warp(block.timestamp + 1 days);

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
        rewardToken.transfer(address(stake), 100 ether);

        vm.warp(block.timestamp + 1 days);

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
        rewardToken.transfer(address(stake), 100 ether);

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

        // Add rewards
        vm.prank(owner);
        rewardToken.transfer(address(stake), 100 ether);

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
}
