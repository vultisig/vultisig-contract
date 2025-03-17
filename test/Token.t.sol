// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Token} from "../contracts/Token.sol";
import {WhitelistV2} from "../contracts/WhitelistV2.sol";
import {IERC1363Receiver} from "../contracts/interfaces/IERC1363Receiver.sol";
import {IERC1363Spender} from "../contracts/interfaces/IERC1363Spender.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Pool} from "../contracts/interfaces/IUniswapV3Pool.sol";
import {Test} from "forge-std/Test.sol";

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

contract TokenTest is Test {
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

    uint256 public constant INITIAL_SUPPLY = 100_000_000 * 1e18;

    // Addresses on Ethereum mainnet
    address constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant UNISWAP_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant UNISWAP_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Fee tier for pool (0.3%)
    uint24 constant FEE_TIER = 3000;

    function setUp() public {
        // Create a fork of mainnet
        mainnetFork = vm.createSelectFork("mainnet");

        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        nonWhitelistedUser = address(0x3);
        pool1 = address(0x4);
        pool2 = address(0x5);
        nonWhitelistedPool = address(0x6);

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

        // Deploy tokens on both chains with real whitelist
        tokenA = new Token("Test Token", "TEST");
        tokenB = new Token("Test Token", "TEST");

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

        // User1 needs WETH to buy tokens
        deal(WETH_ADDRESS, user1, 2 ether); // Give user1 2 ETH worth of WETH

        // User1 approves router to spend WETH
        vm.startPrank(user1);
        IERC20(WETH_ADDRESS).approve(address(swapRouter), 2 ether);

        // First swap: Should succeed as it's under 1 ETH limit
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH_ADDRESS,
            tokenOut: address(tokenA),
            fee: FEE_TIER,
            recipient: user1,
            deadline: block.timestamp + 60,
            amountIn: 0.9 ether, // Under the 1 ETH limit
            amountOutMinimum: 0, // No minimum for test
            sqrtPriceLimitX96: 0 // No price limit
        });

        uint256 amountOut = swapRouter.exactInputSingle(swapParams);
        assertTrue(amountOut > 0, "First swap failed");

        // Second swap: Should fail as it would exceed the 1 ETH limit
        vm.expectRevert("Transaction not allowed by whitelist");
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_ADDRESS,
                tokenOut: address(tokenA),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 0.2 ether, // This would push us over the 1 ETH limit
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        vm.stopPrank();
    }

    function testExtendedPoolTradingWithRealUniswap() public {
        // Test the increased limit in Phase 2

        // Set whitelist to Phase 2 (Extended trading)
        vm.prank(owner);
        whitelist.setPhase(WhitelistV2.Phase.EXTENDED_POOL_TRADING);

        // Give user1 enough WETH to test the 4 ETH limit
        deal(WETH_ADDRESS, user1, 5 ether);

        // User1 approves router to spend WETH
        vm.startPrank(user1);
        IERC20(WETH_ADDRESS).approve(address(swapRouter), 5 ether);

        // First swap: 3 ETH worth (should succeed)
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH_ADDRESS,
            tokenOut: address(tokenA),
            fee: FEE_TIER,
            recipient: user1,
            deadline: block.timestamp + 60,
            amountIn: 3 ether, // Under the 4 ETH limit
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = swapRouter.exactInputSingle(swapParams);
        assertTrue(amountOut > 0, "First swap failed");

        // Second swap: 0.9 ETH worth (should succeed)
        uint256 amountOut2 = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_ADDRESS,
                tokenOut: address(tokenA),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 0.9 ether, // Still under the 4 ETH total limit
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        assertTrue(amountOut2 > 0, "Second swap failed");

        // Third swap: Should fail as it would exceed the 4 ETH limit
        vm.expectRevert("Transaction not allowed by whitelist");
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_ADDRESS,
                tokenOut: address(tokenA),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 0.2 ether, // This would push us over the 4 ETH limit
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

        // Give non-whitelisted user some WETH
        deal(WETH_ADDRESS, nonWhitelistedUser, 10 ether);

        // Non-whitelisted user should be able to swap any amount
        vm.startPrank(nonWhitelistedUser);
        IERC20(WETH_ADDRESS).approve(address(swapRouter), 10 ether);

        // Execute swap with a large amount (should succeed in PUBLIC phase)
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH_ADDRESS,
            tokenOut: address(tokenA),
            fee: FEE_TIER,
            recipient: nonWhitelistedUser,
            deadline: block.timestamp + 60,
            amountIn: 5 ether, // Large amount, should work in PUBLIC phase
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = swapRouter.exactInputSingle(swapParams);
        assertTrue(amountOut > 0, "Swap failed for non-whitelisted user in PUBLIC phase");

        vm.stopPrank();
    }
}
