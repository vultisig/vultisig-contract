import { ethers } from "hardhat";

async function main() {
  const tgtAddress = "0x429fEd88f10285E61b12BDF00848315fbDfCC341";
  const TokenIOU = await ethers.getContractFactory("TokenIOU");
  const MergeTgt = await ethers.getContractFactory("MergeTgt");

  const tokenIOU = await TokenIOU.deploy("VULTISIG", "VULT.IOU");
  await tokenIOU.waitForDeployment();

  const tokenAddress = await tokenIOU.getAddress();
  const mergeTgt = await MergeTgt.deploy(tgtAddress, tokenAddress);
  await mergeTgt.waitForDeployment();
  console.log("Merge:", await mergeTgt.getAddress());

  // Configuration
  const tokenAmount = 10000000n * ethers.parseEther("1");

  const approveTx = await tokenIOU.approve(mergeTgt, tokenAmount);
  await approveTx.wait(2);

  const depositTx = await mergeTgt.deposit(tokenAddress, tokenAmount);
  await depositTx.wait(2);

  const setMergeTx = await tokenIOU.setMerge(mergeTgt);
  await setMergeTx.wait(2);

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
