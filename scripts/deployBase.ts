import fs from "fs";
import hre, { ethers } from "hardhat";
import { abi as FACTORY_ABI } from "@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json";
import { computePoolAddress, encodeSqrtRatioX96 } from "@uniswap/v3-sdk";
import { Token } from "@uniswap/sdk-core";
import { UniswapV3Factory } from "../typechain-types";
import { UNISWAP, USDC, LZ } from "./consts";

const FEE = 10000; // 1% fee

async function main() {
  const network = hre.network.name as "mainnet" | "sepolia" | "base";

  const Token = await ethers.getContractFactory("TokenWhitelisted");
  const WhitelistMerge = await ethers.getContractFactory("WhitelistMerge");

  // Always make sure for BASE, it should be 10m, and for ETH, 90m initial supply
  const token = await Token.deploy("Vultisig", "VULT", LZ[network]);
  await token.waitForDeployment();

  const whitelist = await WhitelistMerge.deploy();
  await whitelist.waitForDeployment();

  const set1Tx = await token.setWhitelistContract(whitelist);
  await set1Tx.wait(3);
  const set2Tx = await whitelist.setToken(token);
  await set2Tx.wait(3);
  // After merge is deployed, call setMerge

  const deployedContracts = {
    token: await token.getAddress(),
    whitelist: await whitelist.getAddress(),
  };

  fs.writeFileSync(`./deployment-vult-${network}.json`, JSON.stringify(deployedContracts));
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
