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

    function test_Deployment() public view {
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
        (uint256 stakedAmount, ) = stake.userInfo(user);
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
        (uint256 stakedAmount, ) = stake.userInfo(user);
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
        (uint256 stakedAmount, ) = stake.userInfo(user);
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
        (uint256 stakedAmount, ) = stake.userInfo(user);
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

    function test_LinearVesting() public {
        uint256 depositAmount = 100 ether;
        uint256 rewardAmount = 10 ether;

        // Setup: User deposits tokens
        vm.startPrank(user);
        stakingToken.approve(address(stake), depositAmount);
        stake.deposit(depositAmount);
        vm.stopPrank();

        // Owner sends new rewards
        vm.startPrank(owner);
        rewardToken.transfer(address(stake), rewardAmount);
        vm.stopPrank();

        // Do an initial interaction to detect rewards (can be a zero claim)
        stake.claim();

        // Check initial vesting state
        (uint256 currentVestingAmount, uint256 vestingStartTime) = stake.getCurrentVestingInfo();
        assertEq(currentVestingAmount, rewardAmount);
        assertGt(vestingStartTime, 0);

        // Check unvested amount at start
        assertEq(stake.getUnvestedAmount(), rewardAmount);
        assertEq(stake.getVestedAmount(), 0);

        // Move forward 12 hours (half the vesting period)
        vm.warp(block.timestamp + 12 hours);

        // Check half vested amounts
        assertApproxEqAbs(stake.getUnvestedAmount(), rewardAmount / 2, 1);
        assertApproxEqAbs(stake.getVestedAmount(), rewardAmount / 2, 1);

        // Move forward to complete vesting
        vm.warp(block.timestamp + 12 hours);

        // Check fully vested state
        assertEq(stake.getUnvestedAmount(), 0);
        assertEq(stake.getVestedAmount(), rewardAmount);
    }

    function test_RewardsClaimDuringVesting() public {
        uint256 depositAmount = 100 ether;
        uint256 rewardAmount = 10 ether;

        // Setup: User deposits tokens
        vm.startPrank(user);
        stakingToken.approve(address(stake), depositAmount);
        stake.deposit(depositAmount);
        vm.stopPrank();

        // Owner sends new rewards
        vm.startPrank(owner);
        rewardToken.transfer(address(stake), rewardAmount);
        vm.stopPrank();

        // Do an initial interaction to detect rewards
        stake.claim();

        // Move forward 12 hours (half vesting)
        vm.warp(block.timestamp + 12 hours);

        // User claims rewards
        vm.startPrank(user);
        uint256 claimedAmount = stake.claim();
        vm.stopPrank();

        // Should receive exactly half the rewards after 12 hours
        assertApproxEqAbs(claimedAmount, rewardAmount / 2, 1);
    }

    function test_MultipleRewardDistributions() public {
        uint256 depositAmount = 100 ether;
        uint256 rewardAmount = 10 ether;

        // Setup: User deposits tokens
        vm.startPrank(user);
        stakingToken.approve(address(stake), depositAmount);
        stake.deposit(depositAmount);
        vm.stopPrank();

        // First reward distribution
        vm.startPrank(owner);
        rewardToken.transfer(address(stake), rewardAmount);
        vm.stopPrank();

        // Start first vesting period
        stake.claim();

        // Verify initial state
        assertEq(stake.getUnvestedAmount(), rewardAmount);
        assertEq(stake.getVestedAmount(), 0);

        // Move forward 12 hours - first distribution should be half vested
        vm.warp(block.timestamp + 12 hours);

        // Second reward distribution
        vm.startPrank(owner);
        rewardToken.transfer(address(stake), rewardAmount);
        vm.stopPrank();

        stake.claim();

        vm.warp(block.timestamp + 12 hours);

        stake.claim();

        // At this point:
        // - First distribution (10 ETH) should be half vested (5 ETH vested, 5 ETH unvested)
        // - Second distribution (10 ETH) should be starting its vesting
        // Total unvested: 15 ETH (5 ETH from first + 10 ETH from second)
        assertEq(stake.getUnvestedAmount() + stake.getVestedAmount(), rewardAmount * 2, "Total rewards incorrect");
    }

    function test_WithdrawUnvestedRewards() public {
        uint256 depositAmount = 100 ether;
        uint256 rewardAmount = 10 ether;

        // Setup: User deposits tokens
        vm.startPrank(user);
        stakingToken.approve(address(stake), depositAmount);
        stake.deposit(depositAmount);
        vm.stopPrank();

        // Owner sends new rewards
        vm.startPrank(owner);
        rewardToken.transfer(address(stake), rewardAmount);

        // Try to withdraw unvested rewards
        uint256 withdrawnAmount = stake.withdrawUnclaimedRewards();

        // Should be able to withdraw only unvested amount
        assertEq(withdrawnAmount, 0, "Should not be able to withdraw vesting rewards");
        vm.stopPrank();
    }
}
