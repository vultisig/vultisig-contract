// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../contracts/WhitelistV2.sol";
import {TokenWhitelisted} from "../contracts/extensions/TokenWhitelisted.sol";
import {IUniswapV3Pool} from "../contracts/interfaces/IUniswapV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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

contract WhitelistV2Test is Test {
    using SafeERC20 for IERC20;

    // The fork
    uint256 mainnetFork;

    // Contracts under test
    WhitelistV2 public whitelist;
    TokenWhitelisted public token;

    // Uniswap contracts
    IUniswapV3Factory public uniswapFactory;
    IUniswapV3Pool public uniswapPool;
    INonfungiblePositionManager public positionManager;
    ISwapRouter public swapRouter;

    // Tokens for Uniswap pool
    IERC20 public weth;

    // Test addresses
    address public owner;
    address public user1;
    address public user2;
    address public user3;
    address public nonWhitelistedUser;

    address public pool1;
    address public pool2;
    address public nonWhitelistedPool;

    // Addresses on Ethereum mainnet
    address constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant UNISWAP_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant UNISWAP_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Fee tier for pool (0.3%)
    uint24 constant FEE_TIER = 3000;

    function setUp() public {
        // Create a fork of mainnet
        mainnetFork = vm.createSelectFork("mainnet");

        owner = address(this);
        user1 = address(0x100);
        user2 = address(0x200);
        user3 = address(0x300);
        nonWhitelistedUser = address(0x400);

        pool1 = address(0x500);
        pool2 = address(0x600);
        nonWhitelistedPool = address(0x700);

        // Get Uniswap V3 contracts from mainnet
        uniswapFactory = IUniswapV3Factory(UNISWAP_V3_FACTORY);
        positionManager = INonfungiblePositionManager(UNISWAP_POSITION_MANAGER);
        swapRouter = ISwapRouter(UNISWAP_SWAP_ROUTER);

        // Get WETH token
        weth = IERC20(WETH_ADDRESS);

        // Fund this address with ETH
        vm.deal(owner, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(user3, 100 ether);
        vm.deal(nonWhitelistedUser, 100 ether);

        // Get WETH by wrapping ETH
        (bool success, ) = WETH_ADDRESS.call{value: 10 ether}("");
        require(success, "Failed to get WETH");

        // Deploy the whitelist contract
        whitelist = new WhitelistV2(owner);

        // Deploy a test token that uses the whitelist
        token = new TokenWhitelisted("Test Token", "TEST");

        token.setWhitelistContract(address(whitelist));

        // Create a new Uniswap pool for our token and WETH
        uint256 tokenAmount = 1000000 * 10 ** 18; // 1M tokens
        uint256 wethAmount = 100 * 10 ** 18; // 100 WETH

        // Sort token addresses correctly
        address tokenAddress = address(token);
        address token0 = tokenAddress < WETH_ADDRESS ? tokenAddress : WETH_ADDRESS;
        address token1 = tokenAddress < WETH_ADDRESS ? WETH_ADDRESS : tokenAddress;

        // Create the pool
        uniswapFactory.createPool(token0, token1, FEE_TIER);
        address poolAddress = uniswapFactory.getPool(token0, token1, FEE_TIER);

        // Initialize the pool with a price (approximately 1 token = 0.0001 WETH)
        IUniswapV3Pool tokenPool = IUniswapV3Pool(poolAddress);
        uint160 sqrtPriceX96 = uint160(79232123187620800136); // sqrt(0.0001) * 2^96
        tokenPool.initialize(sqrtPriceX96);

        // Set the pool as our oracle
        whitelist.setUniswapV3OraclePool(poolAddress);
        uniswapPool = tokenPool;

        // Approve for adding liquidity
        token.approve(address(positionManager), tokenAmount);
        weth.approve(address(positionManager), wethAmount);

        // Whitelist users
        whitelist.whitelistUser(owner);
        whitelist.whitelistUser(user1);
        whitelist.whitelistUser(user2);
        whitelist.whitelistUser(user3);

        // Whitelist pools
        whitelist.whitelistPool(pool1);
        whitelist.whitelistPool(pool2);
        whitelist.whitelistPool(address(uniswapPool));
        whitelist.whitelistPool(address(swapRouter));
        whitelist.whitelistPool(address(positionManager));

        // Add liquidity using position manager
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: FEE_TIER,
            tickLower: -887220, // min price
            tickUpper: 887220, // max price
            amount0Desired: token0 == tokenAddress ? tokenAmount : wethAmount,
            amount1Desired: token0 == tokenAddress ? wethAmount : tokenAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 3600
        });

        // Mint position
        positionManager.mint(params);

        // Transfer tokens to users and pools for testing
        token.transfer(user1, 10000 ether);
        token.transfer(user2, 10000 ether);
        token.transfer(user3, 10000 ether);
        // token.transfer(nonWhitelistedUser, 10000 ether);
        token.transfer(pool1, 100000 ether);
        token.transfer(pool2, 100000 ether);
    }

    // ==================== Admin Function Tests ====================

    function testPhaseAdvancement() public {
        // Test initial phase
        assertEq(uint(whitelist.currentPhase()), uint(WhitelistV2.Phase.WHITELIST_ONLY));

        // Test phase advancement
        whitelist.advancePhase();
        assertEq(uint(whitelist.currentPhase()), uint(WhitelistV2.Phase.LIMITED_POOL_TRADING));

        whitelist.advancePhase();
        assertEq(uint(whitelist.currentPhase()), uint(WhitelistV2.Phase.EXTENDED_POOL_TRADING));

        whitelist.advancePhase();
        assertEq(uint(whitelist.currentPhase()), uint(WhitelistV2.Phase.PUBLIC));

        // Test cannot advance past PUBLIC
        vm.expectRevert("Already in final phase");
        whitelist.advancePhase();

        // Test setPhase
        whitelist.setPhase(WhitelistV2.Phase.WHITELIST_ONLY);
        assertEq(uint(whitelist.currentPhase()), uint(WhitelistV2.Phase.WHITELIST_ONLY));
    }

    function testWhitelistUsersAndPools() public {
        // Test individual whitelisting
        address newUser = address(0x800);
        address newPool = address(0x900);

        whitelist.whitelistUser(newUser);
        assertTrue(whitelist.isUserWhitelisted(newUser));

        whitelist.whitelistPool(newPool);
        assertTrue(whitelist.isPoolWhitelisted(newPool));

        // Test batch whitelisting
        address[] memory newUsers = new address[](2);
        newUsers[0] = address(0x801);
        newUsers[1] = address(0x802);

        whitelist.whitelistUsers(newUsers);
        assertTrue(whitelist.isUserWhitelisted(newUsers[0]));
        assertTrue(whitelist.isUserWhitelisted(newUsers[1]));

        address[] memory newPools = new address[](2);
        newPools[0] = address(0x901);
        newPools[1] = address(0x902);

        whitelist.whitelistPools(newPools);
        assertTrue(whitelist.isPoolWhitelisted(newPools[0]));
        assertTrue(whitelist.isPoolWhitelisted(newPools[1]));

        // Test removal
        whitelist.removeUserFromWhitelist(newUser);
        assertFalse(whitelist.isUserWhitelisted(newUser));

        whitelist.removePoolFromWhitelist(newPool);
        assertFalse(whitelist.isPoolWhitelisted(newPool));
    }

    function testWhitelistGetters() public {
        // Test user count
        uint256 userCount = whitelist.getWhitelistedUserCount();
        assertEq(userCount, 4); // user1, user2, user3, owner

        // Test getting user at index
        address userAtIndex = whitelist.getWhitelistedUserAtIndex(0);
        assertTrue(userAtIndex == user1 || userAtIndex == user2 || userAtIndex == user3 || userAtIndex == owner);

        // Test getting all users
        address[] memory allUsers = whitelist.getAllWhitelistedUsers();
        assertEq(allUsers.length, 4);

        // Test pool count
        uint256 poolCount = whitelist.getWhitelistedPoolCount();
        assertEq(poolCount, 5); // pool1, pool2, uniswapPool, swapRouter, positionManager

        // Test getting pool at index
        address poolAtIndex = whitelist.getWhitelistedPoolAtIndex(0);
        assertTrue(
            poolAtIndex == pool1 ||
                poolAtIndex == pool2 ||
                poolAtIndex == address(uniswapPool) ||
                poolAtIndex == address(swapRouter) ||
                poolAtIndex == address(positionManager)
        );
    }

    // ==================== Phase Tests with Real Uniswap Pool ====================

    function testPhaseWhitelistOnly() public {
        // Phase 0: Whitelist Only
        whitelist.setPhase(WhitelistV2.Phase.WHITELIST_ONLY);

        // Test: Whitelisted user can send to another whitelisted user
        vm.prank(user1);
        assertTrue(token.transfer(user2, 100 ether));

        // Test: Whitelisted user cannot send to non-whitelisted user
        vm.prank(user1);
        vm.expectRevert("Transaction not allowed by whitelist");
        token.transfer(nonWhitelistedUser, 100 ether);

        // Test: Non-whitelisted user cannot send to anyone
        vm.prank(nonWhitelistedUser);
        vm.expectRevert("Transaction not allowed by whitelist");
        token.transfer(user1, 100 ether);

        // Test: Whitelisted user cannot trade with Uniswap in Phase 0
        vm.startPrank(user1);

        // Approve the router to spend tokens
        token.approve(address(swapRouter), 1000 ether);

        // Attempt to swap tokens for WETH
        // This is allowed to allow WL users to add liquidity
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token),
                tokenOut: WETH_ADDRESS,
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 1000 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        vm.stopPrank();
    }

    function testPhaseLimitedPoolTrading() public {
        // Phase 1: Limited Pool Trading (1 ETH limit)
        whitelist.setPhase(WhitelistV2.Phase.LIMITED_POOL_TRADING);

        // Prepare user for swapping
        vm.startPrank(user1);
        weth.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Test: Whitelisted user can trade with Uniswap up to 1 ETH limit
        vm.startPrank(user1);

        // Wrap ETH to get WETH for trading
        (bool success, ) = WETH_ADDRESS.call{value: 1 ether}("");
        require(success, "Failed to get WETH");

        // Attempt to buy tokens with 0.9 ETH worth of WETH
        uint256 amountOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 0.9 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // Verify swap succeeded
        assertTrue(amountOut > 0, "Swap failed");

        // Test: User cannot exceed the 1 ETH limit
        // Wrap more ETH
        (success, ) = WETH_ADDRESS.call{value: 1 ether}("");
        require(success, "Failed to get WETH");

        vm.expectRevert();
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 0.5 ether, // This would push us over the 1 ETH limit
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        vm.stopPrank();

        // Test: Non-whitelisted user cannot trade with Uniswap
        vm.startPrank(nonWhitelistedUser);
        (success, ) = WETH_ADDRESS.call{value: 1 ether}("");
        require(success, "Failed to get WETH");
        weth.approve(address(swapRouter), 1 ether);

        vm.expectRevert();
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: nonWhitelistedUser,
                deadline: block.timestamp + 60,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        vm.stopPrank();
    }

    function testPhaseExtendedPoolTrading() public {
        // Phase 2: Extended Pool Trading (4 ETH limit)
        whitelist.setPhase(WhitelistV2.Phase.EXTENDED_POOL_TRADING);

        // Prepare user for swapping
        vm.startPrank(user1);
        weth.approve(address(swapRouter), type(uint256).max);

        // Wrap ETH to get WETH for trading
        (bool success, ) = WETH_ADDRESS.call{value: 8 ether}("");
        require(success, "Failed to get WETH");

        // Test trading in multiple transactions to reach the limit

        // First swap: 1 ETH worth
        uint256 amountOut1 = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        assertTrue(amountOut1 > 0, "First swap failed");

        // Second swap: 2 ETH worth
        uint256 amountOut2 = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 2 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        assertTrue(amountOut2 > 0, "Second swap failed");

        // Third swap: 0.9 ETH worth (should bring total to 3.9 ETH)
        uint256 amountOut3 = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 0.9 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        assertTrue(amountOut3 > 0, "Third swap failed");

        // Attempt to exceed the 4 ETH limit
        vm.expectRevert();
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 1.2 ether, // This would push us over the 4 ETH limit
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        vm.stopPrank();
    }

    function testSpendingLimitsAcrossPhases() public {
        // Test that spending limits are maintained when phases change

        // Start with Phase 1 (1 ETH limit)
        whitelist.setPhase(WhitelistV2.Phase.LIMITED_POOL_TRADING);

        // Prepare user for swapping
        vm.startPrank(user1);

        (bool success, ) = WETH_ADDRESS.call{value: 8 ether}("");
        require(success, "Failed to get WETH");

        weth.approve(address(swapRouter), type(uint256).max);

        // Spend 0.8 ETH worth in Phase 1 (8000 tokens)
        uint256 tokensToSwap = 0.8 ether;
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: tokensToSwap,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        vm.stopPrank();

        // Advance to Phase 2 (4 ETH limit total)
        whitelist.setPhase(WhitelistV2.Phase.EXTENDED_POOL_TRADING);

        // Should be able to spend 3.2 ETH more
        vm.startPrank(user1);

        // Swap approximately 3.2 ETH worth (32000 tokens)
        uint256 moreTokensToSwap = 3.2 ether;
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: moreTokensToSwap,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // Trying to spend more should fail
        vm.expectRevert();
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 0.1 ether, // Even a small amount over the limit should fail
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        vm.stopPrank();
    }

    function testPhasePublic() public {
        // Phase 3: Public - No restrictions
        whitelist.setPhase(WhitelistV2.Phase.PUBLIC);

        vm.startPrank(owner);
        token.transfer(nonWhitelistedUser, 60000 ether);
        vm.stopPrank();

        // Test: Any user can send to any other user
        vm.startPrank(nonWhitelistedUser);
        assertTrue(token.transfer(user1, 100 ether));

        // Test: Non-whitelisted user can trade with Uniswap
        token.approve(address(swapRouter), 5000 ether);

        uint256 amountOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token),
                tokenOut: WETH_ADDRESS,
                fee: FEE_TIER,
                recipient: nonWhitelistedUser,
                deadline: block.timestamp + 60,
                amountIn: 5000 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        assertTrue(amountOut > 0, "Swap failed in PUBLIC phase");

        // Test: No spending limits in PUBLIC phase
        token.approve(address(swapRouter), 50000 ether);

        // Should be able to swap large amounts without hitting limits
        amountOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token),
                tokenOut: WETH_ADDRESS,
                fee: FEE_TIER,
                recipient: nonWhitelistedUser,
                deadline: block.timestamp + 60,
                amountIn: 50000 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        assertTrue(amountOut > 0, "Large swap failed in PUBLIC phase");

        vm.stopPrank();
    }

    // ==================== Edge Cases and Security Tests ====================

    function testOraclePoolNotSet() public {
        // Deploy new whitelist without oracle
        WhitelistV2 newWhitelist = new WhitelistV2(owner);

        // Create token using the new whitelist
        TokenWhitelisted newToken = new TokenWhitelisted("New Test Token", "NTEST");
        newToken.setWhitelistContract(address(newWhitelist));

        // Try to check transaction with no oracle set
        newWhitelist.setPhase(WhitelistV2.Phase.LIMITED_POOL_TRADING);

        vm.expectRevert();
        newWhitelist.getEthValueForToken(1000 ether);
    }

    function testOnlyOwnerFunctions() public {
        // Test that only owner can call restricted functions
        vm.startPrank(user1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        whitelist.advancePhase();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        whitelist.setPhase(WhitelistV2.Phase.PUBLIC);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        whitelist.whitelistUser(nonWhitelistedUser);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        whitelist.whitelistPool(nonWhitelistedPool);

        vm.stopPrank();
    }

    function testPhaseLimitsUpdate() public {
        // Test that phase limits can be updated
        whitelist.setPhaseLimits(10 ether, 40 ether);
        assertEq(whitelist.phase1EthLimit(), 10 ether);
        assertEq(whitelist.phase2EthLimit(), 40 ether);
    }
}
