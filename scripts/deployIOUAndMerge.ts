import { ethers } from "hardhat";

async function main() {
  const weweAddress = "0x6b9bb36519538e0C073894E964E90172E1c0B41F";
  const TokenIOU = await ethers.getContractFactory("TokenIOU");
  const Merge = await ethers.getContractFactory("Merge");

  const tokenIOU = await TokenIOU.deploy("VULTISIG", "VULT.IOU");
  await tokenIOU.waitForDeployment();

  const tokenAddress = await tokenIOU.getAddress();
  const merge = await Merge.deploy(weweAddress, tokenAddress);
  await merge.waitForDeployment();
  console.log("Merge:", await merge.getAddress());

  // Configuration
  const weweAmount = 10000000000n * ethers.parseEther("1");
  const tokenAmount = 10000000n * ethers.parseEther("1");

  const virtualT = await merge.setVirtualWeweBalance(weweAmount);
  await virtualT.wait(2);

  const approveTx = await tokenIOU.approve(merge, tokenAmount);
  await approveTx.wait(2);

  const depositTx = await merge.deposit(tokenAddress, tokenAmount);
  await depositTx.wait(2);

  const setMergeTx = await tokenIOU.setMerge(merge);
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
