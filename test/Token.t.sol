// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Token} from "../contracts/Token.sol";
import {WhitelistV2} from "../contracts/WhitelistV2.sol";
import {IERC1363Receiver} from "../contracts/interfaces/IERC1363Receiver.sol";
import {IERC1363Spender} from "../contracts/interfaces/IERC1363Spender.sol";
import {SendParam, MessagingFee, MessagingReceipt, OFTReceipt} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Pool} from "../contracts/interfaces/IUniswapV3Pool.sol";
// Uniswap V3 Factory Interface
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

// Uniswap V3 Position Manager Interface
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(
        MintParams calldata params
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

// Uniswap V3 Router Interface
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

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
    using SafeERC20 for IERC20;

    // The fork
    uint256 mainnetFork;

    // Contracts under test
    Token public tokenA; // Token on chain A
    Token public tokenB; // Token on chain B
    WhitelistV2 public whitelist;

    // Uniswap contracts
    IUniswapV3Factory public uniswapFactory;
    IUniswapV3Pool public uniswapPool;
    INonfungiblePositionManager public positionManager;
    ISwapRouter public swapRouter;

    // Tokens for Uniswap pool
    IERC20 public weth;
    IERC20 public usdc;

    // Test addresses
    address public owner;
    address public user1;
    address public user2;
    address public nonWhitelistedUser;
    MockERC1363Receiver public mockReceiver;
    MockERC1363Spender public mockSpender;

    // Define pool addresses for whitelist tests
    address public pool1;
    address public pool2;
    address public nonWhitelistedPool;

    // Define chain EIDs
    uint16 aEid = 1;
    uint16 bEid = 2;

    uint256 public constant INITIAL_SUPPLY = 10_000_000 * 1e18;

    // Addresses on Ethereum mainnet
    address constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant UNISWAP_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant UNISWAP_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Fee tier for pool (0.3%)
    uint24 constant FEE_TIER = 3000;

    function setUp() public override {
        // Create a fork of mainnet
        mainnetFork = vm.createSelectFork("mainnet");

        super.setUp();

        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        nonWhitelistedUser = address(0x3);
        pool1 = address(0x4);
        pool2 = address(0x5);
        nonWhitelistedPool = address(0x6);

        // Setup function to initialize 2 Mock Endpoints with Mock MessageLib
        setUpEndpoints(2, LibraryType.UltraLightNode);

        // Get Uniswap V3 contracts from mainnet
        uniswapFactory = IUniswapV3Factory(UNISWAP_V3_FACTORY);
        positionManager = INonfungiblePositionManager(UNISWAP_POSITION_MANAGER);
        swapRouter = ISwapRouter(UNISWAP_SWAP_ROUTER);

        // Get WETH and USDC tokens
        weth = IERC20(WETH_ADDRESS);
        usdc = IERC20(USDC_ADDRESS);

        // Check if pool exists for WETH-USDC with 0.3% fee tier
        address poolAddress = uniswapFactory.getPool(WETH_ADDRESS, USDC_ADDRESS, FEE_TIER);

        // If pool doesn't exist, create it
        if (poolAddress == address(0)) {
            // Sort token addresses
            address token0 = WETH_ADDRESS < USDC_ADDRESS ? WETH_ADDRESS : USDC_ADDRESS;
            address token1 = WETH_ADDRESS < USDC_ADDRESS ? USDC_ADDRESS : WETH_ADDRESS;

            // Create the pool
            uniswapFactory.createPool(token0, token1, FEE_TIER);
            poolAddress = uniswapFactory.getPool(token0, token1, FEE_TIER);

            // Initialize the pool with a price
            IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

            // 1 WETH = 1800 USDC square root price
            uint160 sqrtPriceX96 = 1771845812700903892492222464; // approximately sqrt(1800) * 2^96
            pool.initialize(sqrtPriceX96);
        }

        // Set the pool
        uniswapPool = IUniswapV3Pool(poolAddress);

        // Fund this address with ETH, WETH, and USDC for testing
        vm.deal(owner, 100 ether);

        // We need to get some WETH and USDC for our tests
        // For WETH, we can deposit ETH
        // For USDC, we'll use an address that has a lot of USDC
        address usdcWhale = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341; // A known address with USDC

        // Get WETH by wrapping ETH
        (bool success, ) = WETH_ADDRESS.call{value: 10 ether}("");
        require(success, "Failed to get WETH");

        // Get USDC by impersonating a whale
        vm.startPrank(usdcWhale);
        uint256 usdcAmount = 20000 * 10 ** 6; // 20,000 USDC
        usdc.transfer(address(this), usdcAmount);
        vm.stopPrank();

        // Deploy whitelist with the real Uniswap pool
        whitelist = new WhitelistV2(owner);

        // Configure whitelist with the real Uniswap pool
        vm.startPrank(owner);
        whitelist.setUniswapV3OraclePool(address(uniswapPool));

        // Whitelist users
        whitelist.whitelistUser(owner);
        whitelist.whitelistUser(user1);
        whitelist.whitelistUser(user2);

        // Whitelist pools and routers
        whitelist.whitelistPool(pool1);
        whitelist.whitelistPool(pool2);
        whitelist.whitelistPool(address(uniswapPool));
        whitelist.whitelistPool(address(swapRouter));
        whitelist.whitelistPool(address(getEndpoint(aEid))); // Whitelist LZ endpoint for bridge tests
        whitelist.whitelistPool(address(getEndpoint(bEid))); // Whitelist LZ endpoint for bridge tests

        // Deploy tokens on both chains with real whitelist
        tokenA = new Token("Test Token", "TEST", getEndpoint(aEid), owner, address(whitelist));
        tokenB = new Token("Test Token", "TEST", getEndpoint(bEid), owner, address(whitelist));

        // Set each token as peer on the other chain
        bytes32 peerA = addressToBytes32(address(tokenA));
        bytes32 peerB = addressToBytes32(address(tokenB));

        tokenA.setPeer(bEid, peerB);
        tokenB.setPeer(aEid, peerA);

        // Deploy mock receiver and spender
        mockReceiver = new MockERC1363Receiver();
        mockSpender = new MockERC1363Spender();

        // Transfer some tokens to pools for testing
        tokenA.transfer(pool1, 10000 ether);
        tokenA.transfer(pool2, 10000 ether);

        // Get a portion of tokenA to add to Uniswap pool with WETH
        uint256 tokenAAmount = 1000000 * 10 ** 18; // 1M tokens
        uint256 wethAmount = 100 * 10 ** 18; // 100 WETH

        // Approve tokens for adding liquidity
        weth.approve(address(positionManager), wethAmount);
        tokenA.approve(address(positionManager), tokenAAmount);

        // Add liquidity to Uniswap - creating a new pool with tokenA and WETH
        address tokenAAddress = address(tokenA);

        // Make sure token addresses are sorted
        address token0 = tokenAAddress < WETH_ADDRESS ? tokenAAddress : WETH_ADDRESS;
        address token1 = tokenAAddress < WETH_ADDRESS ? WETH_ADDRESS : tokenAAddress;

        // Create the pool
        uniswapFactory.createPool(token0, token1, FEE_TIER);
        address tokenAPoolAddress = uniswapFactory.getPool(token0, token1, FEE_TIER);

        // Initialize the pool with a price (assume 1 tokenA = 0.0001 WETH)
        IUniswapV3Pool tokenAPool = IUniswapV3Pool(tokenAPoolAddress);

        // Add to whitelist
        whitelist.whitelistPool(tokenAPoolAddress);

        // sqrt(0.0001) * 2^96
        uint160 sqrtPriceX96 = uint160(79232123187620800136);
        tokenAPool.initialize(sqrtPriceX96);

        // Add liquidity using position manager
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: FEE_TIER,
            tickLower: -887220, // min price
            tickUpper: 887220, // max price
            amount0Desired: token0 == tokenAAddress ? tokenAAmount : wethAmount,
            amount1Desired: token0 == tokenAAddress ? wethAmount : tokenAAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 3600
        });

        // Mint position
        positionManager.mint(params);

        whitelist.setPhase(WhitelistV2.Phase.PUBLIC);

        vm.stopPrank();

        // Fund users with ETH for gas
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(nonWhitelistedUser, 100 ether);
        vm.deal(pool1, 100 ether);
        vm.deal(pool2, 100 ether);
    }

    // ==================== Basic ERC20 Tests ====================

    function testInitialSupply() public {
        assertEq(tokenA.totalSupply(), INITIAL_SUPPLY);
        // Note: We've transferred tokens to other addresses, the owner now holds less
    }

    function testTransfer() public {
        uint256 amount = 1000 * 1e18;

        uint256 preTransferBalance = tokenA.balanceOf(owner);

        vm.prank(owner);
        bool success = tokenA.transfer(user1, amount);

        assertTrue(success);
        assertEq(tokenA.balanceOf(user1), amount);
        assertEq(tokenA.balanceOf(owner), preTransferBalance - amount);
    }

    function testApproveAndTransferFrom() public {
        uint256 amount = 1000 * 1e18;

        vm.prank(owner);
        tokenA.approve(user1, amount);
        assertEq(tokenA.allowance(owner, user1), amount);

        uint256 preTransferBalance = tokenA.balanceOf(owner);
        uint256 preAllowance = tokenA.allowance(owner, user1);

        vm.prank(user1);
        bool success = tokenA.transferFrom(owner, user2, amount);

        assertTrue(success);
        assertEq(tokenA.balanceOf(user2), amount);
        assertEq(tokenA.balanceOf(owner), preTransferBalance - amount);
        assertEq(tokenA.allowance(owner, user1), preAllowance - amount);
    }

    // ==================== Owner Functions Tests ====================

    function testMint() public {
        uint256 amount = 5000 * 1e18;
        uint256 initialSupply = tokenA.totalSupply();

        uint256 preMintBalance = tokenA.balanceOf(owner);

        vm.prank(owner);
        tokenA.mint(amount);

        assertEq(tokenA.totalSupply(), initialSupply + amount);
        assertEq(tokenA.balanceOf(owner), preMintBalance + amount);
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
        uint256 preBurnBalance = tokenA.balanceOf(owner);
        tokenA.burn(amount);

        assertEq(tokenA.totalSupply(), initialSupply - amount);
        assertEq(tokenA.balanceOf(owner), preBurnBalance - amount);
    }

    function testBurnFrom() public {
        uint256 amount = 1000 * 1e18;
        uint256 initialSupply = tokenA.totalSupply();

        vm.prank(owner);
        tokenA.approve(user1, amount);

        uint256 preBurnBalance = tokenA.balanceOf(owner);
        uint256 preBurnAllowance = tokenA.allowance(owner, user1);

        vm.prank(user1);
        tokenA.burnFrom(owner, amount);

        assertEq(tokenA.totalSupply(), initialSupply - amount);
        assertEq(tokenA.balanceOf(owner), preBurnBalance - amount);
        assertEq(tokenA.allowance(owner, user1), preBurnAllowance - amount);
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

        uint256 preSendBalance = tokenA.balanceOf(owner);
        // Send tokens from tokenA
        vm.prank(owner);
        (MessagingReceipt memory receipt, OFTReceipt memory oftReceipt) = tokenA.send{value: fee.nativeFee}(
            sendParam,
            fee,
            payable(owner)
        );

        // Assert the token was deducted from sender
        assertEq(tokenA.balanceOf(owner), preSendBalance - amount);
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

        uint256 preTransferBalance = tokenA.balanceOf(owner);

        vm.prank(owner);
        bool success = tokenA.transferAndCall(address(mockReceiver), amount);

        assertTrue(success);
        assertEq(tokenA.balanceOf(address(mockReceiver)), amount);
        assertEq(tokenA.balanceOf(owner), preTransferBalance - amount);
    }

    function testTransferAndCallWithData() public {
        uint256 amount = 1000 * 1e18;
        bytes memory data = abi.encode("test data");

        // Configure mock to behave correctly
        mockReceiver.configureBehavior(false, false);

        uint256 preTransferBalance = tokenA.balanceOf(owner);

        vm.prank(owner);
        bool success = tokenA.transferAndCall(address(mockReceiver), amount, data);

        assertTrue(success);
        assertEq(tokenA.balanceOf(address(mockReceiver)), amount);
        assertEq(tokenA.balanceOf(owner), preTransferBalance - amount);
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

        uint256 preTransferBalance = tokenA.balanceOf(owner);

        vm.prank(owner);
        tokenA.approve(user1, amount);

        vm.prank(user1);
        bool success = tokenA.transferFromAndCall(owner, address(mockReceiver), amount);

        assertTrue(success);
        assertEq(tokenA.balanceOf(address(mockReceiver)), amount);
        assertEq(tokenA.balanceOf(owner), preTransferBalance - amount);
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

    // ==================== Whitelist Tests ====================

    function testWhitelistPhase0Restrictions() public {
        // Set whitelist phase
        vm.prank(owner);
        whitelist.setPhase(WhitelistV2.Phase.WHITELIST_ONLY);

        // Test: Whitelisted user can send to another whitelisted user
        vm.prank(owner);
        bool success = tokenA.transfer(user1, 100 ether);
        assertTrue(success);

        // Test: Whitelisted user cannot send to non-whitelisted user
        vm.prank(owner);
        vm.expectRevert("Transaction not allowed by whitelist");
        tokenA.transfer(nonWhitelistedUser, 100 ether);
    }

    function testRealUniswapPoolWithWhitelist() public {
        // This test demonstrates interaction with a real Uniswap pool while respecting whitelist restrictions

        // Set whitelist to Phase 1 (Limited trading)
        vm.prank(owner);
        whitelist.setPhase(WhitelistV2.Phase.LIMITED_POOL_TRADING);

        // Transfer tokens to user1 for testing
        vm.prank(owner);
        tokenA.transfer(user1, 2000 ether);

        // User1 approves router to spend tokens
        vm.startPrank(user1);
        tokenA.approve(address(swapRouter), 2000 ether);

        // Set up swap parameters to sell tokens
        // Since we're in Phase 1, we should be able to swap up to 1 ETH worth of tokens

        // Estimate the amount of tokens that would be worth 0.9 ETH
        // Assuming our token price from pool initialization: 1 tokenA = 0.0001 WETH
        // So 0.9 ETH worth would be about 9000 tokens
        uint256 tokenAmountToSell = 900 ether; // This should be under 1 ETH worth

        // Execute swap using SwapRouter
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(tokenA),
            tokenOut: WETH_ADDRESS,
            fee: FEE_TIER,
            recipient: user1,
            deadline: block.timestamp + 60,
            amountIn: tokenAmountToSell,
            amountOutMinimum: 0, // No minimum for test
            sqrtPriceLimitX96: 0 // No price limit
        });

        uint256 amountOut = swapRouter.exactInputSingle(swapParams);

        // Verify swap succeeded
        assertTrue(amountOut > 0, "Swap failed");
        vm.stopPrank();

        // Try to swap more than the 1 ETH limit
        // Attempt another swap that would exceed the limit
        vm.startPrank(user1);

        // This should revert because we've already used up most of our limit
        vm.expectRevert("Transaction not allowed by whitelist");
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(tokenA),
                tokenOut: WETH_ADDRESS,
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 200 ether, // This would push us over the limit
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        vm.stopPrank();
    }

    function testExtendedPoolTradingWithRealUniswap() public {
        // Test the increased limit in Phase 2

        // Set whitelist to Phase 2 (Extended trading)
        vm.startPrank(owner);
        whitelist.setPhase(WhitelistV2.Phase.EXTENDED_POOL_TRADING);

        // Transfer tokens to user1 for testing
        tokenA.transfer(user1, 50000 ether);

        // User1 approves router to spend tokens
        vm.startPrank(user1);
        tokenA.approve(address(swapRouter), 50000 ether);

        // In Phase 2, we can swap up to 4 ETH worth of tokens
        // At our price ratio, that would be about 40000 tokens
        uint256 tokenAmountToSell = 3 ether; // This should be under 4 ETH worth

        // Execute swap using SwapRouter
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(tokenA),
            tokenOut: WETH_ADDRESS,
            fee: FEE_TIER,
            recipient: user1,
            deadline: block.timestamp + 60,
            amountIn: tokenAmountToSell,
            amountOutMinimum: 0, // No minimum for test
            sqrtPriceLimitX96: 0 // No price limit
        });

        uint256 amountOut = swapRouter.exactInputSingle(swapParams);

        // Verify swap succeeded
        assertTrue(amountOut > 0, "Swap failed");

        // Try to swap more, should still work if we're under the limit
        uint256 secondSwapAmount = 0.1 ether;
        uint256 amountOut2 = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(tokenA),
                tokenOut: WETH_ADDRESS,
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: secondSwapAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        assertTrue(amountOut2 > 0, "Second swap failed");

        // This should revert because we've used up our limit
        vm.expectRevert("Transaction not allowed by whitelist");
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(tokenA),
                tokenOut: WETH_ADDRESS,
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 5000 ether, // This would push us over the limit
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        vm.stopPrank();
    }

    function testPublicPhaseNoRestrictions() public {
        // Test that in PUBLIC phase, there are no restrictions

        // Set whitelist to PUBLIC phase
        vm.prank(owner);
        whitelist.setPhase(WhitelistV2.Phase.PUBLIC);

        // Transfer tokens to non-whitelisted user
        vm.prank(owner);
        tokenA.transfer(nonWhitelistedUser, 5000 ether);

        // Non-whitelisted user should be able to swap tokens
        vm.startPrank(nonWhitelistedUser);
        tokenA.approve(address(swapRouter), 5000 ether);

        // Execute swap
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(tokenA),
            tokenOut: WETH_ADDRESS,
            fee: FEE_TIER,
            recipient: nonWhitelistedUser,
            deadline: block.timestamp + 60,
            amountIn: 5000 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = swapRouter.exactInputSingle(swapParams);

        // Verify swap succeeded
        assertTrue(amountOut > 0, "Swap failed for non-whitelisted user in PUBLIC phase");

        vm.stopPrank();
    }

    // ==================== Helper Functions ====================
    function getEndpoint(uint16 eid) internal view returns (address) {
        return address(endpoints[eid]);
    }
}
