// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Stake} from "../contracts/Stake.sol";
import {MockERC1363} from "./mocks/MockERC1363.sol";

contract StakeTest is Test {
    Stake public stake;
    MockERC1363 public token;

    address public owner = makeAddr("owner");
    address public user = makeAddr("user");
    uint256 public constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 public constant USER_BALANCE = 1_000 ether;

    function setUp() public {
        vm.startPrank(owner);
        token = new MockERC1363(INITIAL_SUPPLY);
        stake = new Stake(address(token));
        token.transfer(user, USER_BALANCE);
        vm.stopPrank();
    }

    function test_Deployment() public {
        assertEq(address(stake.token()), address(token));
    }

    function test_RevertDeploymentWithZeroAddress() public {
        vm.expectRevert("Stake: token is the zero address");
        new Stake(address(0));
    }

    function test_Deposit() public {
        uint256 amount = 100 ether;

        vm.startPrank(user);
        token.approve(address(stake), amount);

        vm.expectEmit(true, false, false, true);
        emit Stake.Deposited(user, amount);
        stake.deposit(amount);

        assertEq(stake.balanceOf(user), amount);
        assertEq(stake.totalStaked(), amount);
        assertEq(token.balanceOf(address(stake)), amount);
        vm.stopPrank();
    }

    function test_ApproveAndCall() public {
        uint256 amount = 100 ether;

        vm.startPrank(user);
        vm.expectEmit(true, false, false, true);
        emit Stake.Deposited(user, amount);
        token.approveAndCall(address(stake), amount, "");

        assertEq(stake.balanceOf(user), amount);
        assertEq(stake.totalStaked(), amount);
        assertEq(token.balanceOf(address(stake)), amount);
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
        token.approve(address(stake), depositAmount);
        stake.deposit(depositAmount);

        // Then withdraw
        vm.expectEmit(true, false, false, true);
        emit Stake.Withdrawn(user, depositAmount);
        stake.withdraw(depositAmount);

        assertEq(stake.balanceOf(user), 0);
        assertEq(stake.totalStaked(), 0);
        assertEq(token.balanceOf(address(stake)), 0);
        assertEq(token.balanceOf(user), USER_BALANCE);
        vm.stopPrank();
    }

    function test_PartialWithdraw() public {
        uint256 depositAmount = 100 ether;
        uint256 withdrawAmount = 60 ether;

        vm.startPrank(user);
        token.approve(address(stake), depositAmount);
        stake.deposit(depositAmount);

        stake.withdraw(withdrawAmount);

        assertEq(stake.balanceOf(user), depositAmount - withdrawAmount);
        assertEq(stake.totalStaked(), depositAmount - withdrawAmount);
        assertEq(token.balanceOf(address(stake)), depositAmount - withdrawAmount);
        vm.stopPrank();
    }

    function test_RevertWithdrawInsufficientBalance() public {
        uint256 depositAmount = 100 ether;
        uint256 withdrawAmount = 101 ether;

        vm.startPrank(user);
        token.approve(address(stake), depositAmount);
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
        vm.expectRevert("Stake: caller is not the token");
        stake.onApprovalReceived(user, 100 ether, "");
        vm.stopPrank();
    }
}
