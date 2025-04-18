import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import hre, { ethers } from "hardhat";
import {
  NonfungiblePositionManager as NonfungiblePositionManagerContract,
  SwapRouter,
  UniswapV3Factory,
} from "../../typechain-types";
import { Percent, Token } from "@uniswap/sdk-core";
import { encodeSqrtRatioX96, nearestUsableTick, NonfungiblePositionManager, Position, Pool } from "@uniswap/v3-sdk";

import {
  abi as FACTORY_ABI,
  bytecode as FACTORY_BYTECODE,
} from "@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json";

import {
  abi as MANAGER_ABI,
  bytecode as MANAGER_BYTECODE,
} from "@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json";

import {
  abi as SWAP_ROUTER_ABI,
  bytecode as SWAP_ROUTER_BYTECODE,
} from "@uniswap/v3-periphery/artifacts/contracts/SwapRouter.sol/SwapRouter.json";

// Set initial price 0.01 USD -> which is around 0.0000026 ETH(assuming ETH price is 3.8k)
const ETH_AMOUNT = ethers.parseEther("26");
const TOKEN_AMOUNT = ethers.parseUnits("10000000", 18);
const FEE = 3000;

describe("TokenWhitelisted with Whitelist", function () {
  async function deployTokenWhitelistedFixture() {
    const [owner, buyer, otherAccount] = await ethers.getSigners();

    const TokenWhitelisted = await ethers.getContractFactory("TokenWhitelisted");
    const Whitelist = await ethers.getContractFactory("Whitelist");
    const WETH = await ethers.getContractFactory("WETH9");

    const token = await TokenWhitelisted.deploy("", "");
    const whitelist = await Whitelist.deploy();
    const mockWETH = await WETH.deploy();

    await whitelist.setToken(token);
    await token.setWhitelistContract(whitelist);

    // Transfer test tokens to other account
    await mockWETH.connect(owner).deposit({ value: ETH_AMOUNT * 2n });
    await mockWETH.connect(buyer).deposit({ value: ETH_AMOUNT });
    await mockWETH.connect(otherAccount).deposit({ value: ETH_AMOUNT });

    // Deploy uniswap v3 contracts - Uniswap V3 Factory, PositionManager, and Router
    const UniswapV3Factory = await ethers.getContractFactory(FACTORY_ABI, FACTORY_BYTECODE);
    const factory = (await UniswapV3Factory.deploy()) as UniswapV3Factory;
    await factory.waitForDeployment();
    const PositionManagerFactory = await ethers.getContractFactory(MANAGER_ABI, MANAGER_BYTECODE);
    const factoryAddress = await factory.getAddress();
    const positionManager = (await PositionManagerFactory.deploy(
      factoryAddress,
      ethers.ZeroAddress,
      ethers.ZeroAddress,
    )) as NonfungiblePositionManagerContract;
    await positionManager.waitForDeployment();
    const positionManagerAddress = await positionManager.getAddress();

    const RouterFactory = await ethers.getContractFactory(SWAP_ROUTER_ABI, SWAP_ROUTER_BYTECODE);
    const router = (await RouterFactory.deploy(factoryAddress, ethers.ZeroAddress)) as SwapRouter;
    await router.waitForDeployment();

    // Create the pool
    const token0 = await mockWETH.getAddress();
    const token1 = await token.getAddress();

    await factory.createPool(token0, token1, FEE);
    const poolAddress = await factory.getPool(token0, token1, FEE);
    expect(poolAddress).to.not.equal(ethers.ZeroAddress);
    await whitelist.setPool(poolAddress);

    // Initialize the pool
    const pool = await ethers.getContractAt("IUniswapV3Pool", poolAddress);
    await pool.initialize(encodeSqrtRatioX96(TOKEN_AMOUNT.toString(), ETH_AMOUNT.toString()).toString());

    // Approve the position manager to spend tokens
    await token.approve(positionManagerAddress, TOKEN_AMOUNT);
    await mockWETH.approve(positionManagerAddress, ETH_AMOUNT);

    const slot = await pool.slot0();
    const liquidity = await pool.liquidity();

    const state = {
      liquidity,
      sqrtPriceX96: slot[0],
      tick: slot[1],
      observationIndex: slot[2],
      observationCardinality: slot[3],
      observationCardinalityNext: slot[4],
      feeProtocol: slot[5],
      unlocked: slot[6],
    };

    const Token0 = new Token(hre.network.config.chainId as number, token0, 18);
    const Token1 = new Token(hre.network.config.chainId as number, token1, 18);

    const configuredPool = new Pool(
      Token0,
      Token1,
      FEE,
      state.sqrtPriceX96.toString(),
      state.liquidity.toString(),
      Number(state.tick),
    );

    const position = Position.fromAmounts({
      pool: configuredPool,
      tickLower:
        nearestUsableTick(configuredPool.tickCurrent, configuredPool.tickSpacing) - configuredPool.tickSpacing * 2,
      tickUpper:
        nearestUsableTick(configuredPool.tickCurrent, configuredPool.tickSpacing) + configuredPool.tickSpacing * 2,
      amount0: ETH_AMOUNT.toString(),
      amount1: TOKEN_AMOUNT.toString(),
      useFullPrecision: false,
    });

    const mintOptions = {
      recipient: owner.address,
      deadline: Math.floor(Date.now() / 1000) + 60 * 20,
      slippageTolerance: new Percent(50, 10_000),
    };

    const { calldata, value } = NonfungiblePositionManager.addCallParameters(position, mintOptions);

    const transaction = {
      data: calldata,
      to: positionManagerAddress,
      value: value,
      from: owner.address,
      gasLimit: 10000000,
    };
    const txRes = await owner.sendTransaction(transaction);
    await txRes.wait();
    // Check the liquidity
    const liquidityAfter = await pool.liquidity();
    expect(liquidityAfter).to.be.gt(0);

    // Check pool balance
    // console.log("-> check liquidity", await mockUSDC.balanceOf(poolAddress), await token.balanceOf(poolAddress));

    // Deploy uniswap v3 oracle
    const OracleFactory = await ethers.getContractFactory("UniswapV3Oracle");
    const oracle = await OracleFactory.deploy(poolAddress, token1, token0);
    await oracle.waitForDeployment();

    const priceTx = await pool.increaseObservationCardinalityNext(10);
    await priceTx.wait();

    await whitelist.setOracle(oracle);

    // Remove locked status
    await whitelist.setLocked(false);
    
    // Add addresses to both sender and receiver whitelists
    await whitelist.addBatchSenderWhitelist([buyer, otherAccount, pool]);
    await whitelist.addBatchReceiverWhitelist([buyer, otherAccount, owner]);
    
    // Set the allowed index for both whitelists
    await whitelist.setAllowedSenderWhitelistIndex(3);
    await whitelist.setAllowedReceiverWhitelistIndex(3);

    return { token, mockWETH, whitelist, factory, positionManager, router, pool, owner, buyer, otherAccount };
  }

  describe("Transfer", function () {
    it("Should buy tokens via uniswap", async function () {
      const amount = ethers.parseEther("1");
      const limitAmount = ethers.parseEther("4.3");
      const { token, mockWETH, whitelist, router, positionManager, pool, owner, buyer, otherAccount } =
        await loadFixture(deployTokenWhitelistedFixture);
      const routerAddress = await router.getAddress();

      await mockWETH.connect(buyer).approve(routerAddress, limitAmount);
      await mockWETH.connect(otherAccount).approve(routerAddress, limitAmount);

      // Perform the swap
      const defaultSwapParams = {
        tokenIn: await mockWETH.getAddress(),
        tokenOut: await token.getAddress(),
        fee: FEE,
        recipient: buyer.address,
        amountOutMinimum: 0,
        sqrtPriceLimitX96: 0,
      };
      // First we need to setup conditions to trigger MaxAddressCapOverflow
      await whitelist.setMaxAddressCap(ethers.parseEther("2"));
      
      // We need to try-catch here since the error is occurring at a lower level that
      // can't be caught by the .to.be.revertedWith matcher
      try {
        await router.connect(buyer).exactInputSingle({
          ...defaultSwapParams,
          deadline: Math.floor(Date.now() / 1000) + 60 * 10,
          amountIn: limitAmount,
        });
        // If we get here, the transaction didn't revert
        expect.fail("Transaction should have reverted");
      } catch (error: any) {
        // Verify that the error contains our expected error message
        expect(error.message).to.include("TF");
      }

      await router.connect(buyer).exactInputSingle({
        ...defaultSwapParams,
        deadline: Math.floor(Date.now() / 1000) + 60 * 10,
        amountIn: amount,
      });

      expect(await whitelist.contributed(buyer)).to.eq("946925025644641024"); // This is deterministic because of the initial liquidity and price configured in the fixture setup

      // Increase the max address cap to allow a larger swap
      await whitelist.setMaxAddressCap(ethers.parseEther("5"));
      
      // Buy more ETH and it should succeed now that we've increased the cap
      try {
        await router.connect(buyer).exactInputSingle({
          ...defaultSwapParams,
          deadline: Math.floor(Date.now() / 1000) + 60 * 10,
          amountIn: amount * 3n,
        });
        // Success - this is what we expect
      } catch (error: any) {
        // Should not error
        expect.fail(`Transaction should not have reverted: ${error.message}`);
      }

      // Should fail when already contributed max cap
      try {
        await router.connect(buyer).exactInputSingle({
          ...defaultSwapParams,
          deadline: Math.floor(Date.now() / 1000) + 60 * 10,
          amountIn: amount,
        });
        // If we get here, the transaction didn't revert
        expect.fail("Transaction should have reverted");
      } catch (error: any) {
        // Verify that the error contains our expected error message
        expect(error.message).to.include("TF");
      }

      await router.connect(otherAccount).exactInputSingle({
        ...defaultSwapParams,
        recipient: otherAccount.address,
        deadline: Math.floor(Date.now() / 1000) + 60 * 10,
        amountIn: amount,
      });

      expect(await whitelist.contributed(otherAccount)).to.eq("945188049797336997"); // This is deterministic, same as the 1st swap, also amount should be smaller because there were big swaps already impacting the price

      // Regular transfers should always work
      await token.connect(otherAccount).transfer(buyer, amount);
      await token.connect(otherAccount).transfer(owner, amount);

      // Increase/Decrease liquidity should still work
      const tokenId = await positionManager.tokenOfOwnerByIndex(owner, 0); // 1
      const liquidity = await pool.liquidity();

      await positionManager.decreaseLiquidity({
        tokenId,
        liquidity: liquidity / 2n,
        amount0Min: 0,
        amount1Min: 0,
        deadline: Math.floor(Date.now() / 1000) + 60 * 10,
      });

      await positionManager.collect({
        tokenId,
        recipient: owner.address,
        amount0Max: ETH_AMOUNT,
        amount1Max: TOKEN_AMOUNT,
      });
    });
  });
});
