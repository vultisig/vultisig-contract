import fs from "fs";
import hre, { ethers } from "hardhat";
import { abi as FACTORY_ABI } from "@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json";
import { computePoolAddress, encodeSqrtRatioX96 } from "@uniswap/v3-sdk";
import { Token } from "@uniswap/sdk-core";
import { UniswapV3Factory } from "../typechain-types";
import { UNISWAP, USDC } from "./consts";

const FEE = 10000; // 1% fee

async function main() {
  const network = hre.network.name as "mainnet" | "sepolia";

  // const TokenWhitelisted = await ethers.getContractFactory("TokenWhitelisted");
  // const Whitelist = await ethers.getContractFactory("Whitelist");

  // Initial supply for ETH mainnet should be 90m
  // const token = await TokenWhitelisted.deploy("TKE", "Token-ETH", ethers.ZeroAddress);
  // await token.waitForDeployment();

  // const whitelist = await Whitelist.deploy();
  // await whitelist.waitForDeployment();

  // const set1Tx = await token.setWhitelistContract(whitelist);
  // await set1Tx.wait(3);
  // const set2Tx = await whitelist.setToken(token);
  // await set2Tx.wait(3);

  const token = await ethers.getContractAt("TokenWhitelisted", "0x7430FA7673D66C0cDe141A94Be07Cf371fa78b33");
  const whitelist = await ethers.getContractAt("Whitelist", "0x99d1772FF92bB19177A08a21d214E71D37Fb6F91");

  // const factory = (await ethers.getContractAt(FACTORY_ABI, UNISWAP[network].factory)) as unknown as UniswapV3Factory;
  // Create the pool
  // WETH
  // const token0 = "0x4200000000000000000000000000000000000006";
  // const token1 = await token.getAddress();
  const token0 = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
  const token1 = await token.getAddress();

  console.log("--> token config", hre.network.config.chainId, token0, token1);
  const tokenA = new Token(hre.network.config.chainId as number, token0, 18);
  const tokenB = new Token(hre.network.config.chainId as number, token1, 18);

  // const createPoolTx = await factory.createPool(token0, token1, FEE);
  // await createPoolTx.wait();

  // const poolAddress = await factory.getPool(token0, token1, FEE);
  const poolAddress = computePoolAddress({
    factoryAddress: UNISWAP[network].factory,
    tokenA,
    tokenB,
    fee: FEE,
  });
  const poolAddress1 = computePoolAddress({
    factoryAddress: UNISWAP[network].factory,
    tokenA: tokenB,
    tokenB: tokenA,
    fee: FEE,
  });
  console.log({ poolAddress, poolAddress1 });

  await whitelist.setPool(poolAddress);

  // Initialize the pool - using 0.01 initial price
  // const pool = await ethers.getContractAt("IUniswapV3Pool", poolAddress);
  // await pool.initialize(
  //   encodeSqrtRatioX96(ethers.parseUnits("100", 18).toString(), ethers.parseUnits("1", 6).toString()).toString(),
  // );

  // Deploy uniswap v3 oracle
  const OracleFactory = await ethers.getContractFactory("UniswapV3Oracle");
  const oracle = await OracleFactory.deploy(poolAddress, token1, token0);
  await oracle.waitForDeployment();

  // const priceTx = await pool.increaseObservationCardinalityNext(10);
  // await priceTx.wait();

  await whitelist.setOracle(oracle);

  const deployedContracts = {
    token: await token.getAddress(),
    whitelist: await whitelist.getAddress(),
    poolAddress,
    oracle: await oracle.getAddress(),
  };

  fs.writeFileSync(`./deployment-${network}.json`, JSON.stringify(deployedContracts));
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
