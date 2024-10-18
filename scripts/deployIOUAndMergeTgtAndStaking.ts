const hre = require("hardhat");
import { ethers } from "hardhat";

async function main() {
  const tgtAddress = "0x429fEd88f10285E61b12BDF00848315fbDfCC341";
  const usdcAddress = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
  const TokenIOU = await ethers.getContractFactory("TokenIOU");
  const MergeTgt = await ethers.getContractFactory("MergeTgt");
  const TokenIOUStaking = await ethers.getContractFactory("TokenIOUStaking");


  const tokenIOU = await TokenIOU.deploy("VULTISIG", "VULT.IOU");
  await tokenIOU.waitForDeployment();

  const tokenIOUStaking = await TokenIOUStaking.deploy(usdcAddress, tokenIOU.target);
  await tokenIOUStaking.waitForDeployment();
  const rewardAmount = 1000n * ethers.parseEther("1");
  await tokenIOU.transfer(tokenIOUStaking.target, rewardAmount);

  const mergeTgt = await MergeTgt.deploy(tgtAddress, tokenIOU.target);
  await mergeTgt.waitForDeployment();
  console.log("MergeTgt:", await mergeTgt.getAddress());


  await hre.run("verify:verify", {
      address: tokenIOUStaking.target,
      constructorArguments: [usdcAddress, tokenIOU.target],
  })
  console.log("Staking contract was verified successfully")

  await hre.run("verify:verify", {
      address: tokenIOU.target,
      constructorArguments: ["VULTISIG", "VULT.IOU"],
  })
  console.log("tokenIOU contract was verified successfully")

  await hre.run("verify:verify", {
    address: mergeTgt.target,
    constructorArguments: [tgtAddress, tokenIOU.target],
  })
  console.log("Staking contract was verified successfully")

  // Configuration
  const tokenAmount = 1000n * ethers.parseEther("1");

  const approveTx = await tokenIOU.approve(mergeTgt, tokenAmount); 
  await approveTx.wait(2);

  const depositTx = await mergeTgt.deposit(tokenIOU.target, tokenAmount);
  await depositTx.wait(2);

  const setMergeTx = await tokenIOU.setMerge(mergeTgt);
  await setMergeTx.wait(2);

  const setStakingTx = await tokenIOU.setStaking(tokenIOUStaking.target);
  await setStakingTx.wait(2);

  // To unlock
  // const lockedTx = await merge.setLockedStatus(1);
  // await lockedTx.wait(2);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
