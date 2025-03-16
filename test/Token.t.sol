// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Token} from "../contracts/Token.sol";
import {IERC1363Receiver} from "../contracts/interfaces/IERC1363Receiver.sol";
import {IERC1363Spender} from "../contracts/interfaces/IERC1363Spender.sol";
import {SendParam, MessagingFee, MessagingReceipt, OFTReceipt} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";

// Mock receiver that implements IERC1363Receiver
contract MockERC1363Receiver is IERC1363Receiver {
    bool public shouldRevert;
    bool public shouldReturnWrongSelector;

    function configureBehavior(bool _shouldRevert, bool _shouldReturnWrongSelector) external {
        shouldRevert = _shouldRevert;
        shouldReturnWrongSelector = _shouldReturnWrongSelector;
    }

    function onTransferReceived(
        address operator,
        address from,
        uint256 value,
        bytes calldata data
    ) external returns (bytes4) {
        if (shouldRevert) {
            revert("MockERC1363Receiver: revert");
        }

        if (shouldReturnWrongSelector) {
            return 0xaabbccdd;
        }

        return this.onTransferReceived.selector;
    }
}

// Mock spender that implements IERC1363Spender
contract MockERC1363Spender is IERC1363Spender {
    bool public shouldRevert;
    bool public shouldReturnWrongSelector;

    function configureBehavior(bool _shouldRevert, bool _shouldReturnWrongSelector) external {
        shouldRevert = _shouldRevert;
        shouldReturnWrongSelector = _shouldReturnWrongSelector;
    }

    function onApprovalReceived(address owner, uint256 value, bytes calldata data) external returns (bytes4) {
        if (shouldRevert) {
            revert("MockERC1363Spender: revert");
        }

        if (shouldReturnWrongSelector) {
            return 0xaabbccdd;
        }

        return this.onApprovalReceived.selector;
    }
}

contract TokenTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    Token public tokenA; // Token on chain A
    Token public tokenB; // Token on chain B
    address public owner;
    address public user1;
    address public user2;
    MockERC1363Receiver public mockReceiver;
    MockERC1363Spender public mockSpender;

    // Define chain EIDs
    uint16 aEid = 1;
    uint16 bEid = 2;

    uint256 public constant INITIAL_SUPPLY = 10_000_000 * 1e18;

    function setUp() public override {
        super.setUp();

        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);

        // Setup function to initialize 2 Mock Endpoints with Mock MessageLib
        setUpEndpoints(2, LibraryType.UltraLightNode);

        // Deploy tokens on both chains
        vm.startPrank(owner);

        // Create tokens using the endpoints created by TestHelper
        // Note: Use bare endpoint addresses since the TestHelper manages them
        tokenA = new Token("Test Token", "TEST", getEndpoint(aEid), owner);
        tokenB = new Token("Test Token", "TEST", getEndpoint(bEid), owner);

        // Set each token as peer on the other chain
        bytes32 peerA = addressToBytes32(address(tokenA));
        bytes32 peerB = addressToBytes32(address(tokenB));

        tokenA.setPeer(bEid, peerB);
        tokenB.setPeer(aEid, peerA);

        // Deploy mock receiver and spender
        mockReceiver = new MockERC1363Receiver();
        mockSpender = new MockERC1363Spender();

        vm.stopPrank();

        // Fund users with ETH for gas
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
    }

    // ==================== Basic ERC20 Tests ====================

    function testInitialSupply() public {
        assertEq(tokenA.totalSupply(), INITIAL_SUPPLY);
        assertEq(tokenA.balanceOf(owner), INITIAL_SUPPLY);
    }

    function testTransfer() public {
        uint256 amount = 1000 * 1e18;

        vm.prank(owner);
        bool success = tokenA.transfer(user1, amount);

        assertTrue(success);
        assertEq(tokenA.balanceOf(user1), amount);
        assertEq(tokenA.balanceOf(owner), INITIAL_SUPPLY - amount);
    }

    function testApproveAndTransferFrom() public {
        uint256 amount = 1000 * 1e18;

        vm.prank(owner);
        tokenA.approve(user1, amount);
        assertEq(tokenA.allowance(owner, user1), amount);

        vm.prank(user1);
        bool success = tokenA.transferFrom(owner, user2, amount);

        assertTrue(success);
        assertEq(tokenA.balanceOf(user2), amount);
        assertEq(tokenA.balanceOf(owner), INITIAL_SUPPLY - amount);
        assertEq(tokenA.allowance(owner, user1), 0);
    }

    // ==================== Owner Functions Tests ====================

    function testMint() public {
        uint256 amount = 5000 * 1e18;
        uint256 initialSupply = tokenA.totalSupply();

        vm.prank(owner);
        tokenA.mint(amount);

        assertEq(tokenA.totalSupply(), initialSupply + amount);
        assertEq(tokenA.balanceOf(owner), INITIAL_SUPPLY + amount);
    }

    function testMintNotOwner() public {
        uint256 amount = 5000 * 1e18;

        vm.prank(user1);
        vm.expectRevert(); // Should revert with ownable error
        tokenA.mint(amount);
    }

    function testSetNameAndTicker() public {
        string memory newName = "New Token Name";
        string memory newTicker = "NEW";

        vm.prank(owner);
        tokenA.setNameAndTicker(newName, newTicker);

        assertEq(tokenA.name(), newName);
        assertEq(tokenA.symbol(), newTicker);
    }

    function testSetBridgeLocked() public {
        assertEq(tokenA.bridgeLocked(), false);

        vm.prank(owner);
        tokenA.setBridgeLocked(true);

        assertEq(tokenA.bridgeLocked(), true);
    }

    // ==================== Burn Tests ====================

    function testBurn() public {
        uint256 amount = 1000 * 1e18;
        uint256 initialSupply = tokenA.totalSupply();

        vm.prank(owner);
        tokenA.burn(amount);

        assertEq(tokenA.totalSupply(), initialSupply - amount);
        assertEq(tokenA.balanceOf(owner), INITIAL_SUPPLY - amount);
    }

    function testBurnFrom() public {
        uint256 amount = 1000 * 1e18;
        uint256 initialSupply = tokenA.totalSupply();

        vm.prank(owner);
        tokenA.approve(user1, amount);

        vm.prank(user1);
        tokenA.burnFrom(owner, amount);

        assertEq(tokenA.totalSupply(), initialSupply - amount);
        assertEq(tokenA.balanceOf(owner), INITIAL_SUPPLY - amount);
        assertEq(tokenA.allowance(owner, user1), 0);
    }

    // ==================== Bridge Tests ====================

    function testSendBridgeLocked() public {
        uint256 amount = 1000 * 1e18;

        // Lock the bridge
        vm.prank(owner);
        tokenA.setBridgeLocked(true);

        // Create SendParam struct
        SendParam memory sendParam = SendParam({
            dstEid: bEid, // destination chain id
            to: bytes32(uint256(uint160(user1))), // convert address to bytes32
            amountLD: amount,
            minAmountLD: amount, // No slippage
            extraOptions: "", // No extra options
            composeMsg: "", // No compose message
            oftCmd: "" // No OFT command
        });

        // Create MessagingFee struct
        MessagingFee memory fee = MessagingFee({nativeFee: 0.1 ether, lzTokenFee: 0});

        // Try to bridge tokens
        vm.prank(owner);
        vm.expectRevert(Token.BridgeLocked.selector);
        tokenA.send{value: 0.1 ether}(
            sendParam,
            fee,
            payable(owner) // refund address
        );
    }

    function testSendSuccess() public {
        uint256 amount = 1000 * 1e18;

        // Generate options with sufficient gas for message execution
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        // Create SendParam struct for the quoteSend call
        SendParam memory sendParam = SendParam({
            dstEid: bEid,
            to: bytes32(uint256(uint160(user1))),
            amountLD: amount,
            minAmountLD: amount,
            extraOptions: options,
            composeMsg: "",
            oftCmd: ""
        });

        // Get a quote for the bridging operation - use quoteSend instead of quote
        MessagingFee memory fee = tokenA.quoteSend(sendParam, false); // false = don't pay in LZ token

        // Send tokens from tokenA
        vm.prank(owner);
        (MessagingReceipt memory receipt, OFTReceipt memory oftReceipt) = tokenA.send{value: fee.nativeFee}(
            sendParam,
            fee,
            payable(owner)
        );

        // Assert the token was deducted from sender
        assertEq(tokenA.balanceOf(owner), INITIAL_SUPPLY - amount);
        assertEq(tokenB.balanceOf(user1), 0); // Not received yet

        // Assert the OFT receipt shows correct amounts
        assertEq(oftReceipt.amountSentLD, amount);
        assertEq(oftReceipt.amountReceivedLD, amount);

        // Verify there's a pending packet
        assertTrue(hasPendingPackets(bEid, addressToBytes32(address(tokenB))));

        // Deliver the packet to chainB
        verifyPackets(bEid, addressToBytes32(address(tokenB)));

        // Verify user1 received tokens on chainB
        assertEq(tokenB.balanceOf(user1), amount);
    }

    // Add a helper test to check bidirectional bridging works
    function testBidirectionalBridging() public {
        uint256 amount = 1000 * 1e18;

        // Generate options
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        // First, send from A to B
        SendParam memory sendParamAtoB = SendParam({
            dstEid: bEid,
            to: bytes32(uint256(uint160(user1))),
            amountLD: amount,
            minAmountLD: amount,
            extraOptions: options,
            composeMsg: "",
            oftCmd: ""
        });

        // Get quote for A to B
        MessagingFee memory feeAtoB = tokenA.quoteSend(sendParamAtoB, false);

        vm.prank(owner);
        tokenA.send{value: feeAtoB.nativeFee}(sendParamAtoB, feeAtoB, payable(owner));

        // Deliver the packet to chain B
        verifyPackets(bEid, addressToBytes32(address(tokenB)));

        // Verify user1 received tokens on chain B
        assertEq(tokenB.balanceOf(user1), amount);

        // Now send tokens back from B to A
        SendParam memory sendParamBtoA = SendParam({
            dstEid: aEid,
            to: bytes32(uint256(uint160(user2))),
            amountLD: amount / 2,
            minAmountLD: amount / 2,
            extraOptions: options,
            composeMsg: "",
            oftCmd: ""
        });

        // Get quote for B to A
        MessagingFee memory feeBtoA = tokenB.quoteSend(sendParamBtoA, false);

        vm.prank(user1);
        tokenB.send{value: feeBtoA.nativeFee}(sendParamBtoA, feeBtoA, payable(user1));

        // Deliver the packet to chain A
        verifyPackets(aEid, addressToBytes32(address(tokenA)));

        // Verify user2 received tokens on chain A
        assertEq(tokenA.balanceOf(user2), amount / 2);
    }

    // ==================== ERC1363 Tests ====================

    function testTransferAndCall() public {
        uint256 amount = 1000 * 1e18;

        // Configure mock to behave correctly
        mockReceiver.configureBehavior(false, false);

        vm.prank(owner);
        bool success = tokenA.transferAndCall(address(mockReceiver), amount);

        assertTrue(success);
        assertEq(tokenA.balanceOf(address(mockReceiver)), amount);
        assertEq(tokenA.balanceOf(owner), INITIAL_SUPPLY - amount);
    }

    function testTransferAndCallWithData() public {
        uint256 amount = 1000 * 1e18;
        bytes memory data = abi.encode("test data");

        // Configure mock to behave correctly
        mockReceiver.configureBehavior(false, false);

        vm.prank(owner);
        bool success = tokenA.transferAndCall(address(mockReceiver), amount, data);

        assertTrue(success);
        assertEq(tokenA.balanceOf(address(mockReceiver)), amount);
        assertEq(tokenA.balanceOf(owner), INITIAL_SUPPLY - amount);
    }

    function testTransferAndCallToNonReceiver() public {
        uint256 amount = 1000 * 1e18;

        vm.prank(owner);
        vm.expectRevert(); // Should revert with ERC1363EOAReceiver error
        tokenA.transferAndCall(user1, amount);
    }

    function testTransferAndCallInvalidReceiver() public {
        uint256 amount = 1000 * 1e18;

        // Configure mock to return wrong selector
        mockReceiver.configureBehavior(false, true);

        vm.prank(owner);
        vm.expectRevert(); // Should revert with ERC1363InvalidReceiver error
        tokenA.transferAndCall(address(mockReceiver), amount);
    }

    function testTransferFromAndCall() public {
        uint256 amount = 1000 * 1e18;

        // Configure mock to behave correctly
        mockReceiver.configureBehavior(false, false);

        vm.prank(owner);
        tokenA.approve(user1, amount);

        vm.prank(user1);
        bool success = tokenA.transferFromAndCall(owner, address(mockReceiver), amount);

        assertTrue(success);
        assertEq(tokenA.balanceOf(address(mockReceiver)), amount);
        assertEq(tokenA.balanceOf(owner), INITIAL_SUPPLY - amount);
    }

    function testApproveAndCall() public {
        uint256 amount = 1000 * 1e18;

        // Configure mock to behave correctly
        mockSpender.configureBehavior(false, false);

        vm.prank(owner);
        bool success = tokenA.approveAndCall(address(mockSpender), amount);

        assertTrue(success);
        assertEq(tokenA.allowance(owner, address(mockSpender)), amount);
    }

    function testApproveAndCallWithData() public {
        uint256 amount = 1000 * 1e18;
        bytes memory data = abi.encode("test data");

        // Configure mock to behave correctly
        mockSpender.configureBehavior(false, false);

        vm.prank(owner);
        bool success = tokenA.approveAndCall(address(mockSpender), amount, data);

        assertTrue(success);
        assertEq(tokenA.allowance(owner, address(mockSpender)), amount);
    }

    function testApproveAndCallInvalidSpender() public {
        uint256 amount = 1000 * 1e18;

        // Configure mock to return wrong selector
        mockSpender.configureBehavior(false, true);

        vm.prank(owner);
        vm.expectRevert(); // Should revert with ERC1363InvalidSpender error
        tokenA.approveAndCall(address(mockSpender), amount);
    }

    // ==================== Helper Functions ====================
    function getEndpoint(uint16 eid) internal view returns (address) {
        return address(endpoints[eid]);
    }
}
