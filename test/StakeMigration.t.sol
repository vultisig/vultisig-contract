// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Stake} from "../contracts/Stake.sol";
import {StakeSweeper} from "../contracts/StakeSweeper.sol";
import {MockERC1363} from "./mocks/MockERC1363.sol";
import {MockUniswapRouter} from "./mocks/MockUniswapRouter.sol";

contract StakeMigrationTest is Test {
    Stake public oldStake;
    Stake public newStake;
    StakeSweeper public sweeper;
    MockERC1363 public stakingToken;
    MockERC1363 public rewardToken;
    MockUniswapRouter public router;

    address public owner = makeAddr("owner");
    address public user = makeAddr("user");
    uint256 public constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 public constant USER_BALANCE = 1_000 ether;
    uint256 public constant DEPOSIT_AMOUNT = 100 ether;
    uint256 public constant REWARD_AMOUNT = 50 ether;

    function setUp() public {
        vm.startPrank(owner);

        // Create tokens
        stakingToken = new MockERC1363(INITIAL_SUPPLY);
        rewardToken = new MockERC1363(INITIAL_SUPPLY);

        // Deploy router and sweeper
        router = new MockUniswapRouter();
        sweeper = new StakeSweeper(address(rewardToken), address(router));

        // Deploy stake contracts
        oldStake = new Stake(address(stakingToken), address(rewardToken));
        newStake = new Stake(address(stakingToken), address(rewardToken));

        // Set sweeper for both contracts
        oldStake.setSweeper(address(sweeper));
        newStake.setSweeper(address(sweeper));

        // Transfer tokens
        rewardToken.transfer(address(oldStake), REWARD_AMOUNT * 2);
        rewardToken.transfer(address(newStake), REWARD_AMOUNT);
        stakingToken.transfer(user, USER_BALANCE);

        // Setup router
        stakingToken.transfer(address(router), 1000 ether);

        vm.stopPrank();

        // Set approvals for both stake contracts
        vm.prank(address(oldStake));
        rewardToken.approve(address(oldStake), type(uint256).max);
        vm.prank(address(newStake));
        rewardToken.approve(address(newStake), type(uint256).max);

        // User deposits tokens into old stake contract
        vm.startPrank(user);
        stakingToken.approve(address(oldStake), DEPOSIT_AMOUNT);
        oldStake.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Simulate passage of time with rewards accrual
        // First update rewards to establish baseline
        // oldStake.updateRewards();
    }

    function test_MigrateBasic() public {
        // Verify initial state
        (uint256 initialStakedAmount, ) = oldStake.userInfo(user);
        assertEq(initialStakedAmount, DEPOSIT_AMOUNT);
        assertEq(oldStake.totalStaked(), DEPOSIT_AMOUNT);
        assertEq(newStake.totalStaked(), 0);

        // User performs migration
        vm.startPrank(user);

        // Expect events for withdrawal and migration
        vm.expectEmit(true, true, false, true);
        emit Stake.Withdrawn(user, DEPOSIT_AMOUNT);
        vm.expectEmit(true, true, false, true);
        emit Stake.Migrated(user, address(newStake), DEPOSIT_AMOUNT);

        // Call migrate - now handles the complete migration in one transaction
        uint256 migratedAmount = oldStake.migrate(address(newStake));
        assertEq(migratedAmount, DEPOSIT_AMOUNT);

        // Check user's stake has been reset in old contract
        (uint256 oldStakedAmount, ) = oldStake.userInfo(user);
        assertEq(oldStakedAmount, 0);
        assertEq(oldStake.totalStaked(), 0);

        // Verify tokens are now directly in the new contract
        (uint256 newStakedAmount, ) = newStake.userInfo(user);
        assertEq(newStakedAmount, DEPOSIT_AMOUNT);
        assertEq(newStake.totalStaked(), DEPOSIT_AMOUNT);

        // Ensure user's wallet balance is unchanged (tokens went directly from old to new contract)
        assertEq(stakingToken.balanceOf(user), USER_BALANCE - DEPOSIT_AMOUNT);

        vm.stopPrank();
    }

    function test_MigrateWithRewards() public {
        // Setup initial stake
        vm.startPrank(user);
        stakingToken.approve(address(oldStake), DEPOSIT_AMOUNT);
        oldStake.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Send rewards to old stake contract
        vm.startPrank(owner);
        rewardToken.transfer(address(oldStake), REWARD_AMOUNT);
        vm.stopPrank();

        // Initial interaction to detect rewards
        oldStake.claim();

        // Wait for rewards to vest
        vm.warp(block.timestamp + 24 hours);

        // Verify rewards before migration
        uint256 pendingRewards = oldStake.pendingRewards(user);
        assertGt(pendingRewards, 0, "User should have pending rewards");

        // Perform migration
        vm.prank(user);
        oldStake.migrate(address(newStake));

        // Verify user received rewards during migration
        assertEq(rewardToken.balanceOf(user), REWARD_AMOUNT, "User should have received rewards");
    }

    function test_RevertMigrateToInvalidContract() public {
        // Create a stake contract with different staking token
        MockERC1363 differentToken = new MockERC1363(INITIAL_SUPPLY);
        Stake invalidStake = new Stake(address(differentToken), address(rewardToken));

        vm.startPrank(user);

        // Should revert when trying to migrate to a contract with different staking token
        vm.expectRevert("Stake: incompatible staking token");
        oldStake.migrate(address(invalidStake));

        vm.stopPrank();
    }

    function test_RevertMigrateZeroAddress() public {
        vm.startPrank(user);

        vm.expectRevert("Stake: new contract is the zero address");
        oldStake.migrate(address(0));

        vm.stopPrank();
    }

    function test_RevertMigrateToSelf() public {
        vm.startPrank(user);

        vm.expectRevert("Stake: cannot migrate to self");
        oldStake.migrate(address(oldStake));

        vm.stopPrank();
    }

    function test_RevertMigrateNoStake() public {
        // Create a new user with no stake
        address noStakeUser = makeAddr("noStakeUser");

        vm.startPrank(noStakeUser);

        vm.expectRevert("Stake: no tokens to migrate");
        oldStake.migrate(address(newStake));

        vm.stopPrank();
    }
}
