// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../contracts/LaunchList.sol";
import {ERC20} from "../contracts/extensions/ERC20.sol";
import {IUniswapV3Pool} from "../contracts/interfaces/IUniswapV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
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

contract LaunchListTest is Test {
    using SafeERC20 for IERC20;

    // The fork
    uint256 mainnetFork;

    // Contracts under test
    LaunchList public launchList;
    ERC20 public token;

    // Uniswap contracts
    IUniswapV3Factory public uniswapFactory;
    IUniswapV3Pool public uniswapPool;
    INonfungiblePositionManager public positionManager;
    ISwapRouter public swapRouter;

    // Tokens for Uniswap pool
    IERC20 public usdc;

    // Test addresses
    address public owner;
    address public user1;
    address public user2;
    address public user3;
    address public nonLaunchListUser;

    address public pool1;
    address public pool2;
    address public nonLaunchListPool;

    // Addresses on Ethereum mainnet
    address constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint8 constant USDC_DECIMALS = 6;
    address constant USDC_WHALE = 0x7713974908Be4BEd47172370115e8b1219F4A5f0; // Example USDC whale
    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant UNISWAP_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant UNISWAP_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Fee tier for pool (0.3%)
    uint24 constant FEE_TIER = 3000;

    function setUp() public {
        // Try to use Alchemy if available, otherwise fall back to Infura
        string memory alchemyKey;
        string memory infuraKey;

        // Try to get Alchemy key
        try vm.envString("VULTISIG_ALCHEMY_KEY") returns (string memory value) {
            alchemyKey = value;
        } catch {
            alchemyKey = "";
        }

        // Try to get Infura key
        try vm.envString("VULTISIG_INFURA_KEY") returns (string memory value) {
            infuraKey = value;
        } catch {
            infuraKey = "";
        }

        if (bytes(alchemyKey).length > 0) {
            // Use Alchemy if key is available
            string memory alchemyUrl = string.concat("https://eth-mainnet.g.alchemy.com/v2/", alchemyKey);
            mainnetFork = vm.createSelectFork(alchemyUrl);
        } else if (bytes(infuraKey).length > 0) {
            // Fall back to Infura if Alchemy key is not available
            string memory infuraUrl = string.concat("https://mainnet.infura.io/v3/", infuraKey);
            mainnetFork = vm.createSelectFork(infuraUrl);
        } else {
            // Fall back to using the RPC endpoint configured in foundry.toml
            mainnetFork = vm.createSelectFork("mainnet");
        }

        owner = address(this);
        user1 = address(0x100);
        user2 = address(0x200);
        user3 = address(0x300);
        nonLaunchListUser = address(0x400);

        pool1 = address(0x500);
        pool2 = address(0x600);
        nonLaunchListPool = address(0x700);

        // Get Uniswap V3 contracts from mainnet
        uniswapFactory = IUniswapV3Factory(UNISWAP_V3_FACTORY);
        positionManager = INonfungiblePositionManager(UNISWAP_POSITION_MANAGER);
        swapRouter = ISwapRouter(UNISWAP_SWAP_ROUTER);

        // Get USDC token instead of WETH
        usdc = IERC20(USDC_ADDRESS);

        // Fund this address with USDC from whale
        vm.startPrank(USDC_WHALE);
        usdc.transfer(address(this), 1_000_000 * 10 ** USDC_DECIMALS); // 1M USDC

        // Distribute USDC to test users
        usdc.transfer(user1, 10_000 * 10 ** USDC_DECIMALS);
        usdc.transfer(user2, 10_000 * 10 ** USDC_DECIMALS);
        usdc.transfer(user3, 10_000 * 10 ** USDC_DECIMALS);
        vm.stopPrank();

        // Deploy the launch list contract
        launchList = new LaunchList(owner);

        // Deploy a test token that uses the launch list
        token = new ERC20("Test Token", "TEST");

        // Set launch list contract
        token.setLaunchListContract(address(launchList));

        // Manually authorize the token contract to call isTransactionAllowed
        launchList.grantRole(launchList.LAUNCHLIST_SPENDER_ROLE(), address(token));

        // Create pool with USDC instead of WETH
        uint256 tokenAmount = 1_000_000 * 10 ** 18; // 1M tokens
        uint256 usdcAmount = 1_000_000 * 10 ** USDC_DECIMALS; // 1M USDC

        // Sort token addresses correctly
        address tokenAddress = address(token);
        address token0 = tokenAddress < USDC_ADDRESS ? tokenAddress : USDC_ADDRESS;
        address token1 = tokenAddress < USDC_ADDRESS ? USDC_ADDRESS : tokenAddress;

        // Create the pool
        uniswapFactory.createPool(token0, token1, FEE_TIER);
        address poolAddress = uniswapFactory.getPool(token0, token1, FEE_TIER);

        // Initialize the pool with a price (1 token = 1 USDC)
        IUniswapV3Pool tokenPool = IUniswapV3Pool(poolAddress);
        uint160 sqrtPriceX96 = uint160(79228162514264337593543950336); // sqrt(1) * 2^96
        tokenPool.initialize(sqrtPriceX96);

        // Set the pool as our oracle
        launchList.setUniswapV3OraclePool(poolAddress);
        uniswapPool = tokenPool;

        // Approve for adding liquidity
        token.approve(address(positionManager), tokenAmount);
        usdc.approve(address(positionManager), usdcAmount);

        // Add users to launch list
        launchList.launchListAddress(owner);
        launchList.launchListAddress(user1);
        launchList.launchListAddress(user2);
        launchList.launchListAddress(user3);

        // Add pools to launch list
        launchList.launchListPool(pool1);
        launchList.launchListPool(pool2);
        launchList.launchListPool(address(uniswapPool));
        launchList.launchListPool(address(swapRouter));
        launchList.launchListPool(address(positionManager));

        // Add liquidity using position manager
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: FEE_TIER,
            tickLower: -887220,
            tickUpper: 887220,
            amount0Desired: token0 == tokenAddress ? tokenAmount : usdcAmount,
            amount1Desired: token0 == tokenAddress ? usdcAmount : tokenAmount,
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
        token.transfer(pool1, 100000 ether);
        token.transfer(pool2, 100000 ether);
    }

    // ==================== Admin Function Tests ====================

    function testPhaseAdvancement() public {
        // Test initial phase
        assertEq(uint256(launchList.currentPhase()), uint256(LaunchList.Phase.LAUNCH_LIST_ONLY));

        // Test phase advancement
        launchList.advancePhase();
        assertEq(uint256(launchList.currentPhase()), uint256(LaunchList.Phase.LIMITED_POOL_TRADING));

        launchList.advancePhase();
        assertEq(uint256(launchList.currentPhase()), uint256(LaunchList.Phase.EXTENDED_POOL_TRADING));

        launchList.advancePhase();
        assertEq(uint256(launchList.currentPhase()), uint256(LaunchList.Phase.PUBLIC));

        // Test cannot advance past PUBLIC
        vm.expectRevert("Already in final phase");
        launchList.advancePhase();

        // Test setPhase
        launchList.setPhase(LaunchList.Phase.LAUNCH_LIST_ONLY);
        assertEq(uint256(launchList.currentPhase()), uint256(LaunchList.Phase.LAUNCH_LIST_ONLY));
    }

    function testLaunchListUsersAndPools() public {
        // Test individual launch listing
        address newUser = address(0x800);
        address newPool = address(0x900);

        launchList.launchListAddress(newUser);
        assertTrue(launchList.isAddressOnLaunchList(newUser));

        launchList.launchListPool(newPool);
        assertTrue(launchList.isPoolOnLaunchList(newPool));

        // Test batch launch listing
        address[] memory newUsers = new address[](2);
        newUsers[0] = address(0x801);
        newUsers[1] = address(0x802);

        launchList.launchListAddresses(newUsers);
        assertTrue(launchList.isAddressOnLaunchList(newUsers[0]));
        assertTrue(launchList.isAddressOnLaunchList(newUsers[1]));

        address[] memory newPools = new address[](2);
        newPools[0] = address(0x901);
        newPools[1] = address(0x902);

        launchList.launchListPools(newPools);
        assertTrue(launchList.isPoolOnLaunchList(newPools[0]));
        assertTrue(launchList.isPoolOnLaunchList(newPools[1]));

        // Test removal
        launchList.removeLaunchListAddress(newUser);
        assertFalse(launchList.isAddressOnLaunchList(newUser));

        launchList.removePoolFromLaunchList(newPool);
        assertFalse(launchList.isPoolOnLaunchList(newPool));
    }

    function testLaunchListGetters() public {
        // Test user count
        uint256 userCount = launchList.getLaunchListAddressCount();
        assertEq(userCount, 4); // user1, user2, user3, owner

        // Test getting user at index
        address userAtIndex = launchList.getLaunchListAddressAtIndex(0);
        assertTrue(userAtIndex == user1 || userAtIndex == user2 || userAtIndex == user3 || userAtIndex == owner);

        // Test getting all users
        address[] memory allUsers = launchList.getAllLaunchListAddresses();
        assertEq(allUsers.length, 4);

        // Test pool count
        uint256 poolCount = launchList.getLaunchListPoolCount();
        assertEq(poolCount, 5); // pool1, pool2, uniswapPool, swapRouter, positionManager

        // Test getting pool at index
        address poolAtIndex = launchList.getLaunchListPoolAtIndex(0);
        assertTrue(
            poolAtIndex == pool1 ||
                poolAtIndex == pool2 ||
                poolAtIndex == address(uniswapPool) ||
                poolAtIndex == address(swapRouter) ||
                poolAtIndex == address(positionManager)
        );
    }

    // ==================== Phase Tests with Real Uniswap Pool ====================

    function testPhaseLaunchListOnly() public {
        // Phase 0: Launch List Only
        launchList.setPhase(LaunchList.Phase.LAUNCH_LIST_ONLY);

        // Test: Launch listed user can send to another launch listed user
        vm.prank(user1);
        assertTrue(token.transfer(user2, 100 ether));

        // Test: Launch listed user cannot send to non-launch listed user
        vm.prank(user1);
        vm.expectRevert("Transaction not allowed by launch list");
        token.transfer(nonLaunchListUser, 100 ether);

        // Test: Non-launch listed user cannot send to anyone
        vm.prank(nonLaunchListUser);
        vm.expectRevert("Transaction not allowed by launch list");
        token.transfer(user1, 100 ether);

        // Test: Launch listed user cannot trade with Uniswap in Phase 0
        vm.startPrank(user1);

        // Approve the router to spend tokens
        token.approve(address(swapRouter), 1000 ether);

        // Attempt to swap tokens for WETH
        // This is allowed to allow WL users to add liquidity
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token),
                tokenOut: USDC_ADDRESS,
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
        launchList.setPhase(LaunchList.Phase.LIMITED_POOL_TRADING);

        vm.startPrank(user1);
        usdc.approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);

        // Try to swap 900 USDC worth (should succeed)
        uint256 amountOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: USDC_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 900 * 10 ** USDC_DECIMALS,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        assertTrue(amountOut > 0, "Swap failed");

        // Try to swap more than limit (should fail)
        vm.expectRevert();
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: USDC_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 200 * 10 ** USDC_DECIMALS, // Would exceed 1000 USDC limit
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        vm.stopPrank();
    }

    function testPhaseExtendedPoolTrading() public {
        launchList.setPhase(LaunchList.Phase.EXTENDED_POOL_TRADING);

        vm.startPrank(user1);
        usdc.approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);

        // Test trading in multiple transactions up to 9000 USDC limit
        uint256 amountOut1 = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: USDC_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 1000 * 10 ** USDC_DECIMALS,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        assertTrue(amountOut1 > 0, "First swap failed");

        // Second swap: 2000 USDC
        uint256 amountOut2 = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: USDC_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 2000 * 10 ** USDC_DECIMALS,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        assertTrue(amountOut2 > 0, "Second swap failed");

        // Try to exceed 9000 USDC limit
        vm.expectRevert();
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: USDC_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 8500 * 10 ** USDC_DECIMALS, // Would exceed 9000 USDC limit
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        vm.stopPrank();
    }

    function testSpendingLimitsAcrossPhases() public {
        // Start with Phase 1 (1000 USDC limit)
        launchList.setPhase(LaunchList.Phase.LIMITED_POOL_TRADING);

        vm.startPrank(user1);
        usdc.approve(address(swapRouter), type(uint256).max);

        // Spend 800 USDC in Phase 1
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: USDC_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 800 * 10 ** USDC_DECIMALS,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();

        // Advance to Phase 2 (10,000 USDC total limit)
        launchList.setPhase(LaunchList.Phase.EXTENDED_POOL_TRADING);

        vm.startPrank(user1);
        // Should be able to spend 9200 USDC more (10,000 - 800 = 9,200)
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: USDC_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 9200 * 10 ** USDC_DECIMALS,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // Trying to spend more should fail
        vm.expectRevert();
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: USDC_ADDRESS,
                tokenOut: address(token),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 100 * 10 ** USDC_DECIMALS,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        vm.stopPrank();
    }

    function testPhasePublic() public {
        // Phase 3: Public - No restrictions
        launchList.setPhase(LaunchList.Phase.PUBLIC);

        vm.startPrank(owner);
        token.transfer(nonLaunchListUser, 60000 ether);
        vm.stopPrank();

        // Test: Any user can send to any other user
        vm.startPrank(nonLaunchListUser);
        assertTrue(token.transfer(user1, 100 ether));

        // Test: Non-launch listed user can trade with Uniswap
        token.approve(address(swapRouter), 5000 ether);

        uint256 amountOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token),
                tokenOut: USDC_ADDRESS,
                fee: FEE_TIER,
                recipient: nonLaunchListUser,
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
                tokenOut: USDC_ADDRESS,
                fee: FEE_TIER,
                recipient: nonLaunchListUser,
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
        // Deploy new launch list without oracle
        LaunchList newLaunchList = new LaunchList(owner);

        // Create token using the new launch list
        ERC20 newToken = new ERC20("New Test Token", "NTEST");
        newToken.setLaunchListContract(address(newLaunchList));

        // Try to check transaction with no oracle set
        newLaunchList.setPhase(LaunchList.Phase.LIMITED_POOL_TRADING);

        vm.expectRevert();
        newLaunchList.getUsdcValueForToken(1000 ether);
    }

    function testOnlyOwnerFunctions() public {
        // Test that only owner can call restricted functions
        vm.startPrank(user1);

        // Phase management functions still require owner
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        launchList.advancePhase();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        launchList.setPhase(LaunchList.Phase.PUBLIC);

        // Whitelist functions now require WHITELIST_MANAGER_ROLE
        bytes32 whitelistManagerRole = launchList.WHITELIST_MANAGER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                whitelistManagerRole
            )
        );
        launchList.launchListAddress(nonLaunchListUser);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                whitelistManagerRole
            )
        );
        launchList.launchListPool(nonLaunchListPool);

        vm.stopPrank();
    }

    function testPhaseLimitsUpdate() public {
        // Test that phase limits can be updated
        launchList.setPhaseLimits(1000 * 10 ** USDC_DECIMALS, 9000 * 10 ** USDC_DECIMALS);
        assertEq(launchList.phase1UsdcLimit(), 1000 * 10 ** USDC_DECIMALS);
        assertEq(launchList.phase2UsdcLimit(), 9000 * 10 ** USDC_DECIMALS);
    }

    function testWhitelistManagerRole() public {
        // Test that WHITELIST_MANAGER_ROLE can manage whitelist
        address whitelistManager = address(0x999);
        address newUser = address(0x888);
        address newPool = address(0x777);

        // Grant WHITELIST_MANAGER_ROLE to whitelistManager
        bytes32 whitelistManagerRole = launchList.WHITELIST_MANAGER_ROLE();
        launchList.grantRole(whitelistManagerRole, whitelistManager);

        // Verify the role was granted
        assertTrue(launchList.hasRole(whitelistManagerRole, whitelistManager));

        // Test that whitelistManager can add addresses and pools
        vm.startPrank(whitelistManager);

        launchList.launchListAddress(newUser);
        assertTrue(launchList.isAddressOnLaunchList(newUser));

        launchList.launchListPool(newPool);
        assertTrue(launchList.isPoolOnLaunchList(newPool));

        // Test removal
        launchList.removeLaunchListAddress(newUser);
        assertFalse(launchList.isAddressOnLaunchList(newUser));

        launchList.removePoolFromLaunchList(newPool);
        assertFalse(launchList.isPoolOnLaunchList(newPool));

        vm.stopPrank();

        // Test that revoking the role prevents access
        launchList.revokeRole(whitelistManagerRole, whitelistManager);
        assertFalse(launchList.hasRole(whitelistManagerRole, whitelistManager));

        vm.startPrank(whitelistManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                whitelistManager,
                whitelistManagerRole
            )
        );
        launchList.launchListAddress(newUser);
        vm.stopPrank();
    }

    function testLaunchListSpenderRoleProtection() public {
        // Test that isTransactionAllowed is protected from public DoS attacks
        address attacker = address(0x666);

        // Setup oracle pool first
        launchList.setUniswapV3OraclePool(address(uniswapPool));
        launchList.setPhase(LaunchList.Phase.LIMITED_POOL_TRADING);

        // Attacker should not be able to call isTransactionAllowed directly
        bytes32 spenderRole = launchList.LAUNCHLIST_SPENDER_ROLE();
        vm.startPrank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, spenderRole)
        );
        launchList.isTransactionAllowed(address(uniswapPool), user1, 1000 ether);
        vm.stopPrank();

        // Test manual authorization of token contracts
        vm.startPrank(owner);
        ERC20 newToken = new ERC20("Test Token 2", "TEST2");

        // Before authorization, token should not have the role
        assertFalse(launchList.hasRole(spenderRole, address(newToken)));

        // Set launch list contract
        newToken.setLaunchListContract(address(launchList));

        // Token still shouldn't have the role until manually authorized
        assertFalse(launchList.hasRole(spenderRole, address(newToken)));

        // Manually authorize the token contract using grantRole
        launchList.grantRole(spenderRole, address(newToken));

        // Now token should have the role
        assertTrue(launchList.hasRole(spenderRole, address(newToken)));
        vm.stopPrank();

        // Test manual authorization/deauthorization using standard AccessControl functions
        address anotherContract = address(0x777);
        launchList.grantRole(spenderRole, anotherContract);
        assertTrue(launchList.hasRole(spenderRole, anotherContract));

        launchList.revokeRole(spenderRole, anotherContract);
        assertFalse(launchList.hasRole(spenderRole, anotherContract));
    }
}
