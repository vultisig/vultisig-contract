// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {StakedVult} from "../contracts/StakedVult.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";

contract MockVult is ERC20 {
    constructor(uint256 supply) ERC20("VULT", "VULT") {
        _mint(msg.sender, supply);
    }
}

contract StakedVultTest is Test {
    StakedVult internal svult;
    MockVult internal vult;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 internal constant USER_BALANCE = 10_000 ether;

    function setUp() public {
        vm.startPrank(owner);
        vult = new MockVult(INITIAL_SUPPLY);
        svult = new StakedVult(IERC20(address(vult)), owner);
        vult.transfer(alice, USER_BALANCE);
        vult.transfer(bob, USER_BALANCE);
        vm.stopPrank();
    }

    // --------------------------------------------------------------------- //
    // Helpers
    // --------------------------------------------------------------------- //

    function _depositFor(address user, uint256 amount) internal {
        vm.startPrank(user);
        vult.approve(address(svult), amount);
        svult.depositFor(user, amount);
        vm.stopPrank();
    }

    function _requestUnstake(address user, uint256 amount) internal returns (uint256 requestId) {
        vm.prank(user);
        requestId = svult.requestUnstake(amount);
    }

    // --------------------------------------------------------------------- //
    // Deployment & metadata
    // --------------------------------------------------------------------- //

    function test_Deployment() public view {
        assertEq(svult.name(), "Staked VULT");
        assertEq(svult.symbol(), "sVULT");
        assertEq(svult.decimals(), 18);
        assertEq(svult.owner(), owner);
        assertEq(address(svult.underlying()), address(vult));
        assertEq(svult.cooldownDuration(), 0);
        assertEq(svult.totalPendingUnstake(), 0);
        assertEq(svult.totalSupply(), 0);
    }

    // --------------------------------------------------------------------- //
    // Deposit (depositFor) — inherited but exercised for coverage of overrides
    // --------------------------------------------------------------------- //

    function test_DepositMintsOneToOne() public {
        _depositFor(alice, 100 ether);
        assertEq(svult.balanceOf(alice), 100 ether);
        assertEq(svult.totalSupply(), 100 ether);
        assertEq(vult.balanceOf(address(svult)), 100 ether);
    }

    function test_DepositForOtherAccount() public {
        vm.startPrank(alice);
        vult.approve(address(svult), 50 ether);
        svult.depositFor(bob, 50 ether);
        vm.stopPrank();

        assertEq(svult.balanceOf(bob), 50 ether);
        assertEq(svult.balanceOf(alice), 0);
    }

    // --------------------------------------------------------------------- //
    // Synchronous withdraw (cooldownDuration == 0)
    // --------------------------------------------------------------------- //

    function test_WithdrawSyncWhenNoCooldown() public {
        _depositFor(alice, 100 ether);

        vm.prank(alice);
        svult.withdrawTo(alice, 40 ether);

        assertEq(svult.balanceOf(alice), 60 ether);
        assertEq(vult.balanceOf(alice), USER_BALANCE - 100 ether + 40 ether);
        assertEq(svult.totalSupply(), 60 ether);
    }

    function test_WithdrawSyncReverts_WhenCooldownActive() public {
        _depositFor(alice, 100 ether);
        vm.prank(owner);
        svult.setCooldownDuration(1 days);

        vm.prank(alice);
        vm.expectRevert(StakedVult.CooldownActive.selector);
        svult.withdrawTo(alice, 10 ether);
    }

    // --------------------------------------------------------------------- //
    // Admin: setCooldownDuration
    // --------------------------------------------------------------------- //

    function test_SetCooldownDuration_EmitsAndStores() public {
        vm.expectEmit(true, true, true, true, address(svult));
        emit StakedVult.CooldownDurationSet(0, 7 days);
        vm.prank(owner);
        svult.setCooldownDuration(7 days);

        assertEq(svult.cooldownDuration(), 7 days);
    }

    function test_SetCooldownDuration_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        svult.setCooldownDuration(1);
    }

    function test_SetCooldownDuration_CanBeReducedAndRaised() public {
        vm.startPrank(owner);
        svult.setCooldownDuration(5 days);
        assertEq(svult.cooldownDuration(), 5 days);
        svult.setCooldownDuration(0);
        assertEq(svult.cooldownDuration(), 0);
        svult.setCooldownDuration(type(uint64).max);
        assertEq(svult.cooldownDuration(), type(uint64).max);
        vm.stopPrank();
    }

    // --------------------------------------------------------------------- //
    // requestUnstake
    // --------------------------------------------------------------------- //

    function test_RequestUnstake_EscrowsAndEmits() public {
        _depositFor(alice, 100 ether);
        vm.prank(owner);
        svult.setCooldownDuration(2 days);

        uint256 startTs = block.timestamp;

        vm.expectEmit(true, true, false, true, address(svult));
        emit StakedVult.UnstakeRequested(alice, 1, 30 ether, startTs + 2 days);
        uint256 requestId = _requestUnstake(alice, 30 ether);

        assertEq(requestId, 1);
        assertEq(svult.balanceOf(alice), 70 ether);
        assertEq(svult.balanceOf(address(svult)), 30 ether);
        assertEq(svult.totalPendingUnstake(), 30 ether);
        assertEq(svult.totalSupply(), 100 ether);

        (address reqOwner, uint256 maturity, uint256 amount) = svult.getUnstakeRequest(requestId);
        assertEq(reqOwner, alice);
        assertEq(maturity, startTs + 2 days);
        assertEq(amount, 30 ether);
    }

    function test_RequestUnstake_ZeroCooldown_ImmediatelyMature() public {
        _depositFor(alice, 100 ether);
        uint256 requestId = _requestUnstake(alice, 25 ether);
        assertTrue(svult.isClaimable(requestId));

        vm.prank(alice);
        svult.claim(requestId, alice);

        assertEq(svult.balanceOf(alice), 75 ether);
        assertEq(vult.balanceOf(alice), USER_BALANCE - 100 ether + 25 ether);
    }

    function test_RequestUnstake_RevertsOnZeroAmount() public {
        _depositFor(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(StakedVult.ZeroAmount.selector);
        svult.requestUnstake(0);
    }

    function test_RequestUnstake_RevertsWhenBalanceInsufficient() public {
        _depositFor(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, alice, 100 ether, 150 ether
            )
        );
        svult.requestUnstake(150 ether);
    }

    function test_RequestUnstake_AssignsIncreasingIds() public {
        _depositFor(alice, 100 ether);
        uint256 id1 = _requestUnstake(alice, 10 ether);
        uint256 id2 = _requestUnstake(alice, 20 ether);
        uint256 id3 = _requestUnstake(alice, 30 ether);
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
        assertEq(svult.totalPendingUnstake(), 60 ether);
    }

    // --------------------------------------------------------------------- //
    // claim
    // --------------------------------------------------------------------- //

    function test_Claim_AfterCooldown_TransfersUnderlying() public {
        _depositFor(alice, 100 ether);
        vm.prank(owner);
        svult.setCooldownDuration(3 days);

        uint256 requestId = _requestUnstake(alice, 40 ether);

        // Not mature yet
        assertFalse(svult.isClaimable(requestId));

        vm.warp(block.timestamp + 3 days);
        assertTrue(svult.isClaimable(requestId));

        vm.expectEmit(true, true, true, true, address(svult));
        emit StakedVult.UnstakeClaimed(alice, requestId, alice, 40 ether);
        vm.prank(alice);
        svult.claim(requestId, alice);

        assertEq(svult.balanceOf(alice), 60 ether);
        assertEq(svult.balanceOf(address(svult)), 0);
        assertEq(svult.totalSupply(), 60 ether);
        assertEq(vult.balanceOf(alice), USER_BALANCE - 100 ether + 40 ether);
        assertEq(svult.totalPendingUnstake(), 0);
    }

    function test_Claim_ToDifferentReceiver() public {
        _depositFor(alice, 100 ether);
        vm.prank(owner);
        svult.setCooldownDuration(1 days);

        uint256 requestId = _requestUnstake(alice, 50 ether);
        vm.warp(block.timestamp + 1 days);

        uint256 carolBefore = vult.balanceOf(carol);
        vm.prank(alice);
        svult.claim(requestId, carol);
        assertEq(vult.balanceOf(carol), carolBefore + 50 ether);
    }

    function test_Claim_RevertsBeforeMaturity() public {
        _depositFor(alice, 100 ether);
        vm.prank(owner);
        svult.setCooldownDuration(1 days);

        uint256 requestId = _requestUnstake(alice, 50 ether);
        uint256 maturity = block.timestamp + 1 days;

        vm.warp(maturity - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakedVult.RequestNotMature.selector, maturity));
        svult.claim(requestId, alice);
    }

    function test_Claim_RevertsForUnknownRequest() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakedVult.RequestUnknown.selector, 999));
        svult.claim(999, alice);
    }

    function test_Claim_RevertsForNonOwner() public {
        _depositFor(alice, 100 ether);
        uint256 requestId = _requestUnstake(alice, 10 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StakedVult.NotRequestOwner.selector, bob, alice));
        svult.claim(requestId, bob);
    }

    function test_Claim_RevertsForZeroReceiver() public {
        _depositFor(alice, 100 ether);
        uint256 requestId = _requestUnstake(alice, 10 ether);

        vm.prank(alice);
        vm.expectRevert(StakedVult.ZeroAddress.selector);
        svult.claim(requestId, address(0));
    }

    function test_Claim_DoubleClaimReverts() public {
        _depositFor(alice, 100 ether);
        uint256 requestId = _requestUnstake(alice, 10 ether);

        vm.prank(alice);
        svult.claim(requestId, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakedVult.RequestUnknown.selector, requestId));
        svult.claim(requestId, alice);
    }

    // --------------------------------------------------------------------- //
    // Cooldown lifecycle interactions
    // --------------------------------------------------------------------- //

    function test_MultipleTickets_ClaimableIndependently() public {
        _depositFor(alice, 100 ether);
        vm.prank(owner);
        svult.setCooldownDuration(1 days);

        uint256 id1 = _requestUnstake(alice, 10 ether);
        vm.warp(block.timestamp + 12 hours);
        uint256 id2 = _requestUnstake(alice, 20 ether);

        // After id1 matures id2 is still pending
        vm.warp(block.timestamp + 12 hours);
        assertTrue(svult.isClaimable(id1));
        assertFalse(svult.isClaimable(id2));

        vm.prank(alice);
        svult.claim(id1, alice);

        // Advance to id2 maturity
        vm.warp(block.timestamp + 12 hours);
        assertTrue(svult.isClaimable(id2));
        vm.prank(alice);
        svult.claim(id2, alice);

        assertEq(vult.balanceOf(alice), USER_BALANCE - 100 ether + 30 ether);
        assertEq(svult.balanceOf(alice), 70 ether);
        assertEq(svult.totalPendingUnstake(), 0);
    }

    function test_TicketKeepsOriginalMaturity_WhenCooldownChanges() public {
        _depositFor(alice, 100 ether);
        vm.prank(owner);
        svult.setCooldownDuration(5 days);

        uint256 requestId = _requestUnstake(alice, 40 ether);
        uint256 maturity = block.timestamp + 5 days;

        // Owner extends cooldown for new tickets; existing ticket unaffected.
        vm.prank(owner);
        svult.setCooldownDuration(30 days);

        vm.warp(maturity);
        assertTrue(svult.isClaimable(requestId));

        vm.prank(alice);
        svult.claim(requestId, alice);
    }

    function test_ShortenedCooldown_DoesNotMatureOlderTicket() public {
        _depositFor(alice, 100 ether);
        vm.prank(owner);
        svult.setCooldownDuration(10 days);

        uint256 id = _requestUnstake(alice, 10 ether);
        uint256 originalMaturity = block.timestamp + 10 days;

        vm.prank(owner);
        svult.setCooldownDuration(1 hours);

        vm.warp(block.timestamp + 1 hours);
        assertFalse(svult.isClaimable(id));

        vm.warp(originalMaturity);
        assertTrue(svult.isClaimable(id));
    }

    function test_GetUnstakeRequest_RevertsForUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(StakedVult.RequestUnknown.selector, 42));
        svult.getUnstakeRequest(42);
    }

    function test_IsClaimable_FalseForUnknown() public view {
        assertFalse(svult.isClaimable(42));
    }

    // --------------------------------------------------------------------- //
    // ERC20Wrapper invariant: totalSupply == VULT.balanceOf(this)
    // --------------------------------------------------------------------- //

    function test_Invariant_AcrossCooldownLifecycle() public {
        _depositFor(alice, 100 ether);
        _depositFor(bob, 200 ether);
        vm.prank(owner);
        svult.setCooldownDuration(1 days);

        uint256 r1 = _requestUnstake(alice, 30 ether);
        uint256 r2 = _requestUnstake(bob, 50 ether);
        assertEq(svult.totalSupply(), vult.balanceOf(address(svult)));

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        svult.claim(r1, alice);
        assertEq(svult.totalSupply(), vult.balanceOf(address(svult)));

        vm.prank(bob);
        svult.claim(r2, bob);
        assertEq(svult.totalSupply(), vult.balanceOf(address(svult)));
    }

    // --------------------------------------------------------------------- //
    // Fuzz
    // --------------------------------------------------------------------- //

    function testFuzz_RoundTrip_NoCooldown(uint128 amount) public {
        amount = uint128(bound(uint256(amount), 1, USER_BALANCE));
        _depositFor(alice, amount);

        uint256 requestId = _requestUnstake(alice, amount);
        vm.prank(alice);
        svult.claim(requestId, alice);

        assertEq(svult.balanceOf(alice), 0);
        assertEq(vult.balanceOf(alice), USER_BALANCE);
        assertEq(svult.totalSupply(), 0);
    }

    function testFuzz_RoundTrip_WithCooldown(uint128 amount, uint32 cooldown) public {
        amount = uint128(bound(uint256(amount), 1, USER_BALANCE));
        vm.prank(owner);
        svult.setCooldownDuration(cooldown);

        _depositFor(alice, amount);
        uint256 maturity = block.timestamp + cooldown;
        uint256 requestId = _requestUnstake(alice, amount);

        if (cooldown != 0) {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(StakedVult.RequestNotMature.selector, maturity));
            svult.claim(requestId, alice);
        }

        vm.warp(maturity);
        vm.prank(alice);
        svult.claim(requestId, alice);
        assertEq(vult.balanceOf(alice), USER_BALANCE);
    }
}
