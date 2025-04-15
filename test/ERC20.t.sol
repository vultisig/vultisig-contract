// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "../contracts/extensions/ERC20.sol";
import {LaunchList} from "../contracts/LaunchList.sol";
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

    function mint(MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
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

    function onTransferReceived(address operator, address from, uint256 value, bytes calldata data)
        external
        returns (bytes4)
    {
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

contract ERC20Test is Test {
    using SafeERC20 for IERC20;

    // The fork
    uint256 mainnetFork;

    // Contracts under test
    ERC20 public tokenA; // Token on chain A
    LaunchList public launchList;

    // Uniswap contracts
    IUniswapV3Factory public uniswapFactory;
    INonfungiblePositionManager public positionManager;
    ISwapRouter public swapRouter;

    // Tokens for Uniswap pool
    IERC20 public weth;
    IERC20 public usdc;

    // Test addresses
    address public owner;
    address public user1;
    address public user2;
    address public nonLaunchListUser;
    MockERC1363Receiver public mockReceiver;
    MockERC1363Spender public mockSpender;

    // Define pool addresses for launch list tests
    address public pool1;
    address public pool2;
    address public nonLaunchListPool;

    uint256 public constant INITIAL_SUPPLY = 100_000_000 * 1e18;

    // Addresses on Ethereum mainnet
    address constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant UNISWAP_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant UNISWAP_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Fee tier for pool (0.3%)
    uint24 constant FEE_TIER = 3000;

    // Update constants
    address constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint8 constant USDC_DECIMALS = 6;
    address constant USDC_WHALE = 0x7713974908Be4BEd47172370115e8b1219F4A5f0;

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

        owner = address(0x9999999999999999999999999999999999999999);
        user1 = address(0x1);
        user2 = address(0x2);
        nonLaunchListUser = address(0x3);
        pool1 = address(0x4);
        pool2 = address(0x5);
        nonLaunchListPool = address(0x6);

        // Get Uniswap V3 contracts from mainnet
        uniswapFactory = IUniswapV3Factory(UNISWAP_V3_FACTORY);
        positionManager = INonfungiblePositionManager(UNISWAP_POSITION_MANAGER);
        swapRouter = ISwapRouter(UNISWAP_SWAP_ROUTER);

        // Get WETH and USDC tokens
        weth = IERC20(WETH_ADDRESS);

        // Get USDC token instead of WETH
        usdc = IERC20(USDC_ADDRESS);

        // Get USDC from whale
        vm.startPrank(USDC_WHALE);
        usdc.transfer(address(this), 10_000_000 * 10 ** USDC_DECIMALS); // 1M USDC
        vm.stopPrank();

        // Fund this address with ETH, WETH, and USDC for testing
        vm.deal(owner, 100000 ether);
        // Fund with USDC now
        usdc.transfer(owner, 1_000_000 * 10 ** USDC_DECIMALS); // 1M USDC

        // Get WETH by wrapping ETH
        vm.startPrank(owner);
        (bool success,) = WETH_ADDRESS.call{value: 10000 ether}("");
        require(success, "Failed to get WETH");
        vm.stopPrank();

        // Get USDC by impersonating a whale
        // Deploy launch list with the real Uniswap pool
        launchList = new LaunchList(owner);

        // Configure launch list with the real Uniswap pool
        vm.startPrank(owner);

        // add users to launch list
        launchList.launchListAddress(owner);
        launchList.launchListAddress(user1);
        launchList.launchListAddress(user2);

        // add pools to launch list
        launchList.launchListPool(pool1);
        launchList.launchListPool(pool2);
        launchList.launchListPool(address(swapRouter));

        // Deploy tokens on both chains with real launch list
        tokenA = new ERC20("Test Token", "TEST");

        tokenA.setLaunchListContract(address(launchList));

        // Deploy mock receiver and spender
        mockReceiver = new MockERC1363Receiver();
        mockSpender = new MockERC1363Spender();

        // Transfer some tokens to pools for testing
        tokenA.transfer(pool1, 10000 ether);
        tokenA.transfer(pool2, 10000 ether);
        tokenA.transfer(owner, 10000 ether);

        // Get a portion of tokenA to add to Uniswap pool with WETH
        uint256 tokenAAmount = 1_000_000 * 10 ** 18; // 1M tokens
        uint256 usdcAmount = 1_000_000 * 10 ** USDC_DECIMALS; // 1M USDC

        // Approve tokens for adding liquidity
        usdc.approve(address(positionManager), usdcAmount);
        tokenA.approve(address(positionManager), tokenAAmount);

        // Add liquidity to Uniswap - creating a new pool with tokenA and USDC
        address tokenAAddress = address(tokenA);

        // Make sure token addresses are sorted
        address token0 = tokenAAddress < USDC_ADDRESS ? tokenAAddress : USDC_ADDRESS;
        address token1 = tokenAAddress < USDC_ADDRESS ? USDC_ADDRESS : tokenAAddress;

        // Create the pool
        uniswapFactory.createPool(token0, token1, FEE_TIER);
        address tokenAPoolAddress = uniswapFactory.getPool(token0, token1, FEE_TIER);

        // Initialize the pool with a price (1 tokenA = 1 USDC)
        IUniswapV3Pool tokenAPool = IUniswapV3Pool(tokenAPoolAddress);
        launchList.setUniswapV3OraclePool(address(tokenAPoolAddress));

        // Add to launch list
        launchList.launchListPool(tokenAPoolAddress);

        // sqrt(1) * 2^96
        uint160 sqrtPriceX96 = uint160(79228162514264337593543950336);
        tokenAPool.initialize(sqrtPriceX96);

        // Get balances for logging
        uint256 usdcBalance = usdc.balanceOf(owner);
        console2.log("USDC balance of owner:", usdcBalance);
        uint256 tokenABalance = tokenA.balanceOf(owner);
        console2.log("TokenA balance of owner:", tokenABalance);

        // Add liquidity using position manager
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: FEE_TIER,
            tickLower: -887220,
            tickUpper: 887220,
            amount0Desired: token0 == tokenAAddress ? tokenAAmount : usdcAmount,
            amount1Desired: token0 == tokenAAddress ? usdcAmount : tokenAAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: owner,
            deadline: block.timestamp + 3600
        });

        // Mint position
        positionManager.mint(params);

        launchList.setPhase(LaunchList.Phase.PUBLIC);

        vm.stopPrank();

        // Fund users with ETH for gas
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(nonLaunchListUser, 100 ether);
        vm.deal(pool1, 100 ether);
        vm.deal(pool2, 100 ether);
    }

    // ==================== Basic ERC20 Tests ====================

    function testInitialSupply() public view {
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

        uint256 preBurnBalance = tokenA.balanceOf(owner);
        vm.prank(owner);
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

    // ==================== Launch List Tests ====================

    function testLaunchListPhase0Restrictions() public {
        // Set launch list phase
        vm.startPrank(owner);
        launchList.setPhase(LaunchList.Phase.LAUNCH_LIST_ONLY);

        // Test: Launch listed user can send to another launch listed user
        bool success = tokenA.transfer(user1, 100 ether);
        assertTrue(success);

        assertFalse(launchList.isAddressOnLaunchList(nonLaunchListUser));
        assertFalse(launchList.isPoolOnLaunchList(nonLaunchListPool));

        // Test: Launch listed user cannot send to non-launch listed user
        vm.expectRevert("Transaction not allowed by launch list");
        tokenA.transfer(nonLaunchListUser, 100 ether);
    }

    function testRealUniswapPoolWithLaunchList() public {
        // Set launch list to Phase 1 (Limited trading)
        vm.prank(owner);
        launchList.setPhase(LaunchList.Phase.LIMITED_POOL_TRADING);

        // User1 needs USDC to buy tokens
        vm.startPrank(USDC_WHALE);
        usdc.transfer(user1, 2000 * 10 ** USDC_DECIMALS); // Give user1 2000 USDC
        vm.stopPrank();

        // User1 approves router to spend USDC
        vm.startPrank(user1);
        usdc.approve(address(swapRouter), 2000 * 10 ** USDC_DECIMALS);

        // First swap: Should succeed as it's under 1000 USDC limit
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: USDC_ADDRESS,
            tokenOut: address(tokenA),
            fee: FEE_TIER,
            recipient: user1,
            deadline: block.timestamp + 60,
            amountIn: 900 * 10 ** USDC_DECIMALS, // Under the 1000 USDC limit
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = swapRouter.exactInputSingle(swapParams);
        assertTrue(amountOut > 0, "First swap failed");

        // Second swap: Should fail as it would exceed the 1000 USDC limit
        vm.expectRevert();
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: USDC_ADDRESS,
                tokenOut: address(tokenA),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 200 * 10 ** USDC_DECIMALS, // This would push us over the 1000 USDC limit
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        vm.stopPrank();
    }

    function testExtendedPoolTradingWithRealUniswap() public {
        // Set launch list to Phase 2 (Extended trading)
        vm.prank(owner);
        launchList.setPhase(LaunchList.Phase.EXTENDED_POOL_TRADING);

        // Give user1 enough USDC to test the 4000 USDC limit
        vm.startPrank(USDC_WHALE);
        usdc.transfer(user1, 11_000 * 10 ** USDC_DECIMALS);
        vm.stopPrank();

        // User1 approves router to spend USDC
        vm.startPrank(user1);
        usdc.approve(address(swapRouter), 11_000 * 10 ** USDC_DECIMALS);

        // First swap: 3000 USDC worth (should succeed)
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: USDC_ADDRESS,
            tokenOut: address(tokenA),
            fee: FEE_TIER,
            recipient: user1,
            deadline: block.timestamp + 60,
            amountIn: 3000 * 10 ** USDC_DECIMALS, // Under the 4000 USDC limit
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = swapRouter.exactInputSingle(swapParams);
        assertTrue(amountOut > 0, "First swap failed");

        // Second swap: 900 USDC worth (should succeed)
        uint256 amountOut2 = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: USDC_ADDRESS,
                tokenOut: address(tokenA),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 900 * 10 ** USDC_DECIMALS,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        assertTrue(amountOut2 > 0, "Second swap failed");

        // Third swap: Should fail as it would exceed the 9000 USDC limit
        vm.expectRevert();
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: USDC_ADDRESS,
                tokenOut: address(tokenA),
                fee: FEE_TIER,
                recipient: user1,
                deadline: block.timestamp + 60,
                amountIn: 6000 * 10 ** USDC_DECIMALS,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        vm.stopPrank();
    }

    function testPublicPhaseNoRestrictions() public {
        // Set launch list to PUBLIC phase
        vm.prank(owner);
        launchList.setPhase(LaunchList.Phase.PUBLIC);

        // Give non-launch listed user some USDC
        vm.startPrank(USDC_WHALE);
        usdc.transfer(nonLaunchListUser, 10000 * 10 ** USDC_DECIMALS);
        vm.stopPrank();

        // Non-launch listed user should be able to swap any amount
        vm.startPrank(nonLaunchListUser);
        usdc.approve(address(swapRouter), 10000 * 10 ** USDC_DECIMALS);

        // Execute swap with a large amount (should succeed in PUBLIC phase)
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: USDC_ADDRESS,
            tokenOut: address(tokenA),
            fee: FEE_TIER,
            recipient: nonLaunchListUser,
            deadline: block.timestamp + 60,
            amountIn: 5000 * 10 ** USDC_DECIMALS, // Large amount, should work in PUBLIC phase
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = swapRouter.exactInputSingle(swapParams);
        assertTrue(amountOut > 0, "Swap failed for non-launch listed user in PUBLIC phase");

        vm.stopPrank();
    }
}
