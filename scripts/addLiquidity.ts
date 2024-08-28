import hre, { ethers } from "hardhat";
import { abi as MANAGER_ABI } from "@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json";
import { nearestUsableTick, NonfungiblePositionManager, Position, Pool } from "@uniswap/v3-sdk";
import { Percent, Token } from "@uniswap/sdk-core";
import { NonfungiblePositionManager as NonfungiblePositionManagerContract } from "../typechain-types";
import { UNISWAP, USDC } from "./consts";
import deploymentSepolia from "../deployment-sepolia.json";

// Set initial price 0.01 USDC
const USDC_AMOUNT = ethers.parseUnits("100000", 6);
const VULTISIG_AMOUNT = ethers.parseUnits("10000000", 18);
const FEE = 10000; // 1% fee

async function main() {
  const network = hre.network.name as "mainnet" | "sepolia";
  const deployments = {
    sepolia: deploymentSepolia,
    mainnet: null, // To-do after mainnet deploymnet, there will be deployment-mainnet.json file in the directory
  };
  const [owner] = await ethers.getSigners();

  if (deployments[network] === null) {
    console.log("--> Contracts not deployed yet for network", network);
    return;
  }

  const positionManager = (await ethers.getContractAt(
    MANAGER_ABI,
    UNISWAP[network].nfpm,
  )) as unknown as NonfungiblePositionManagerContract;
  const positionManagerAddress = await positionManager.getAddress();

  const vultisig = await ethers.getContractAt("VultisigWhitelisted", deployments[network]?.vultisig as string);
  const usdc = await ethers.getContractAt("MockUSDC", USDC[network]);

  // Approve the position manager to spend tokens
  const vultisigApproveTx = await vultisig.approve(positionManagerAddress, VULTISIG_AMOUNT);
  await vultisigApproveTx.wait();
  const usdcApproveTx = await usdc.approve(positionManagerAddress, USDC_AMOUNT);
  await usdcApproveTx.wait();

  const pool = await ethers.getContractAt("IUniswapV3Pool", deployments[network]?.poolAddress as string);
  const token0 = await usdc.getAddress();
  const token1 = await vultisig.getAddress();

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

  const Token0 = new Token(hre.network.config.chainId as number, token0, 6);
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
    amount0: USDC_AMOUNT.toString(),
    amount1: VULTISIG_AMOUNT.toString(),
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

  const poolAddress = await pool.getAddress();
  // Check pool balance
  console.log("-> check liquidity", await usdc.balanceOf(poolAddress), await vultisig.balanceOf(poolAddress));
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
