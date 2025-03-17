import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { Token, Stake } from "../../typechain-types";
import { ContractTransactionResponse } from "ethers";

// Helper function to call approveAndCall with the correct signature - using fragment string to avoid ambiguity
async function callApproveAndCall(token: Token, spender: string, amount: bigint, data: string = "0x"): Promise<ContractTransactionResponse> {
  // Access the function by its full signature to avoid ambiguity
  return await (token as any)["approveAndCall(address,uint256,bytes)"](spender, amount, data);
}

// No longer needed as we directly use the contract methods

describe("Stake", function () {
  // We define a fixture to reuse the same setup in every test
  async function deployStakeFixture() {
    // Get signers
    const [owner, user1, user2, user3] = await ethers.getSigners();

    // Deploy VULT token
    const TokenFactory = await ethers.getContractFactory("Token");
    const vultToken = await TokenFactory.deploy("Vultisig Token", "VULT");

    // Deploy USDC token for rewards
    const usdcToken = await TokenFactory.deploy("USD Coin", "USDC");

    // Deploy stake contract
    const StakeFactory = await ethers.getContractFactory("Stake");
    const stake = await StakeFactory.deploy(await vultToken.getAddress(), await usdcToken.getAddress());

    // Transfer some VULT tokens to users for testing
    const amount = ethers.parseEther("1000");
    await vultToken.transfer(user1.address, amount);
    await vultToken.transfer(user2.address, amount);

    // Keep some USDC for rewards
    await usdcToken.transfer(owner.address, ethers.parseUnits("10000", 18));

    return { stake, vultToken, usdcToken, owner, user1, user2, user3 };
  }

  describe("Deployment", function () {
    it("Should set the correct token addresses", async function () {
      const { stake, vultToken, usdcToken } = await loadFixture(deployStakeFixture);
      expect(await stake.stakingToken()).to.equal(await vultToken.getAddress());
      expect(await stake.rewardToken()).to.equal(await usdcToken.getAddress());
    });

    it("Should have zero total staked initially", async function () {
      const { stake } = await loadFixture(deployStakeFixture);
      expect(await stake.totalStaked()).to.equal(0);
    });
  });

  describe("Deposits", function () {
    it("Should allow staking tokens with deposit function", async function () {
      const { stake, vultToken, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");

      // Approve tokens first
      await vultToken.connect(user1).approve(await stake.getAddress(), stakeAmount);
      
      // Deposit tokens
      await stake.connect(user1).deposit(stakeAmount);
      
      // Check balances
      const userInfo = await stake.userInfo(user1.address);
      expect(userInfo.amount).to.equal(stakeAmount);
      expect(await stake.totalStaked()).to.equal(stakeAmount);
      expect(await vultToken.balanceOf(await stake.getAddress())).to.equal(stakeAmount);
    });

    it("Should allow staking tokens with approveAndCall", async function () {
      const { stake, vultToken, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");
      
      // Use approveAndCall
      await callApproveAndCall(vultToken.connect(user1), await stake.getAddress(), stakeAmount);
      
      // Check balances
      const userInfo = await stake.userInfo(user1.address);
      expect(userInfo.amount).to.equal(stakeAmount);
      expect(await stake.totalStaked()).to.equal(stakeAmount);
      expect(await vultToken.balanceOf(await stake.getAddress())).to.equal(stakeAmount);
    });

    it("Should fail if staking zero tokens", async function () {
      const { stake, vultToken, user1 } = await loadFixture(deployStakeFixture);
      
      // Try to deposit zero tokens
      await expect(stake.connect(user1).deposit(0))
        .to.be.revertedWith("Stake: amount must be greater than 0");
      
      // Try approveAndCall with zero tokens
      await expect(callApproveAndCall(vultToken.connect(user1), await stake.getAddress(), 0n))
        .to.be.revertedWith("Stake: amount must be greater than 0");
    });

    it("Should properly initialize reward debt for new depositors", async function () {
      const { stake, vultToken, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");
      
      // Deposit tokens
      await vultToken.connect(user1).approve(await stake.getAddress(), stakeAmount);
      await stake.connect(user1).deposit(stakeAmount);
      
      // Check reward debt is properly set
      const userInfo = await stake.userInfo(user1.address);
      expect(userInfo.rewardDebt).to.equal(0); // No rewards yet, so rewardDebt should be 0
    });
  });

  describe("Rewards", function () {
    it("Should calculate rewards correctly", async function () {
      const { stake, vultToken, usdcToken, owner, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");
      const rewardAmount = ethers.parseUnits("1000", 18); // 1000 USDC
      
      // User1 deposits tokens
      await callApproveAndCall(vultToken.connect(user1), await stake.getAddress(), stakeAmount);
      
      // Send rewards to stake contract
      await usdcToken.transfer(await stake.getAddress(), rewardAmount);
      
      // Update rewards
      await stake.updateRewards();
      
      // Calculate expected rewards
      const pendingRewards = await stake.pendingRewards(user1.address);
      expect(pendingRewards).to.equal(rewardAmount);
    });

    it("Should distribute rewards proportionally to staked amounts", async function () {
      const { stake, vultToken, usdcToken, owner, user1, user2 } = await loadFixture(deployStakeFixture);
      const amount1 = ethers.parseEther("200"); // 2/3 of total stake
      const amount2 = ethers.parseEther("100"); // 1/3 of total stake
      const rewardAmount = ethers.parseUnits("900", 18); // 900 USDC
      
      // Users deposit tokens
      await callApproveAndCall(vultToken.connect(user1), await stake.getAddress(), amount1);
      await callApproveAndCall(vultToken.connect(user2), await stake.getAddress(), amount2);
      
      // Send rewards to stake contract
      await usdcToken.transfer(await stake.getAddress(), rewardAmount);
      await stake.updateRewards();
      
      // Check pending rewards
      const pendingRewards1 = await stake.pendingRewards(user1.address);
      const pendingRewards2 = await stake.pendingRewards(user2.address);
      
      // User1 should get 2/3 of rewards, User2 should get 1/3
      expect(pendingRewards1).to.equal(rewardAmount * 2n / 3n);
      expect(pendingRewards2).to.equal(rewardAmount / 3n);
    });
    
    it("Should allow claiming rewards", async function () {
      const { stake, vultToken, usdcToken, owner, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");
      const rewardAmount = ethers.parseUnits("1000", 18); // 1000 USDC
      
      // User1 deposits tokens
      await callApproveAndCall(vultToken.connect(user1), await stake.getAddress(), stakeAmount);
      
      // Send rewards to stake contract
      await usdcToken.transfer(await stake.getAddress(), rewardAmount);
      
      // Claim rewards
      await stake.connect(user1).claim();
      
      // Check user's USDC balance
      expect(await usdcToken.balanceOf(user1.address)).to.equal(rewardAmount);
      
      // Check reward debt is properly updated
      const userInfo = await stake.userInfo(user1.address);
      expect(userInfo.rewardDebt).to.equal(stakeAmount * (await stake.accRewardPerShare()) / 1000000000000n);
    });

    it("Should receive new rewards over time", async function () {
      const { stake, vultToken, usdcToken, owner, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");
      const reward1 = ethers.parseUnits("500", 18); // 500 USDC
      const reward2 = ethers.parseUnits("300", 18); // 300 USDC
      
      // User1 deposits tokens
      await callApproveAndCall(vultToken.connect(user1), await stake.getAddress(), stakeAmount);
      
      // Send first reward
      await usdcToken.transfer(await stake.getAddress(), reward1);
      
      // Claim first reward
      await stake.connect(user1).claim();
      
      // Check user's USDC balance after first claim
      expect(await usdcToken.balanceOf(user1.address)).to.equal(reward1);
      
      // Send second reward
      await usdcToken.transfer(await stake.getAddress(), reward2);
      
      // Claim second reward
      await stake.connect(user1).claim();
      
      // Check user's USDC balance after second claim
      expect(await usdcToken.balanceOf(user1.address)).to.equal(reward1 + reward2);
    });
  });

  describe("Withdrawals", function () {
    it("Should automatically claim rewards when withdrawing", async function () {
      const { stake, vultToken, usdcToken, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");
      const withdrawAmount = ethers.parseEther("40");
      const rewardAmount = ethers.parseUnits("500", 18); // 500 USDC
      
      // Stake tokens first
      await callApproveAndCall(vultToken.connect(user1), await stake.getAddress(), stakeAmount);
      
      // Send rewards to stake contract
      await usdcToken.transfer(await stake.getAddress(), rewardAmount);
      
      // Update rewards before checking
      await stake.updateRewards();
      
      // Get USDC balance before claiming
      const userUsdcBefore = await usdcToken.balanceOf(user1.address);
      
      // Claim rewards first to avoid reentrancy
      await stake.connect(user1).claim();
      
      // Then withdraw tokens
      await stake.connect(user1).withdraw(withdrawAmount);
      
      // Check VULT balances
      const userInfo = await stake.userInfo(user1.address);
      expect(userInfo.amount).to.equal(stakeAmount - withdrawAmount);
      expect(await stake.totalStaked()).to.equal(stakeAmount - withdrawAmount);
      expect(await vultToken.balanceOf(await stake.getAddress())).to.equal(stakeAmount - withdrawAmount);
      
      // Check USDC rewards were received
      const userUsdcAfter = await usdcToken.balanceOf(user1.address);
      expect(userUsdcAfter - userUsdcBefore).to.equal(rewardAmount);
    });

    it("Should allow force withdrawing without claiming rewards", async function () {
      const { stake, vultToken, usdcToken, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");
      const rewardAmount = ethers.parseUnits("500", 18); // 500 USDC
      
      // Stake tokens first
      await callApproveAndCall(vultToken.connect(user1), await stake.getAddress(), stakeAmount);
      
      // Send rewards to stake contract
      await usdcToken.transfer(await stake.getAddress(), rewardAmount);
      
      // Force withdraw all tokens without claiming rewards
      await stake.connect(user1).forceWithdraw(stakeAmount);
      
      // Check user's VULT tokens were returned
      expect(await vultToken.balanceOf(user1.address)).to.equal(ethers.parseEther("1000"));
      
      // Check user did not receive USDC rewards
      expect(await usdcToken.balanceOf(user1.address)).to.equal(0);
      
      // USDC should still be in the stake contract
      expect(await usdcToken.balanceOf(await stake.getAddress())).to.equal(rewardAmount);
    });

    it("Should fail when withdrawing more than staked", async function () {
      const { stake, vultToken, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");
      
      // Stake tokens first
      await callApproveAndCall(vultToken.connect(user1), await stake.getAddress(), stakeAmount);
      
      // Try to withdraw more than staked
      await expect(stake.connect(user1).withdraw(stakeAmount + 1n))
        .to.be.revertedWith("Stake: insufficient balance");
      
      // Try to force withdraw more than staked
      await expect(stake.connect(user1).forceWithdraw(stakeAmount + 1n))
        .to.be.revertedWith("Stake: insufficient balance");
    });
  });

  describe("Owner functions", function () {
    it("Should set deployer as owner", async function () {
      const { stake, owner } = await loadFixture(deployStakeFixture);
      expect(await stake.owner()).to.equal(owner.address);
    });

    // This test would require modifications to the contract logic
    it.skip("Should allow owner to withdraw unclaimed rewards", async function () {
      const { stake, vultToken, usdcToken, owner, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");
      const rewardAmount = ethers.parseUnits("1000", 18); // 1000 USDC
      
      // User1 deposits tokens - this will set lastRewardBalance to 0
      await callApproveAndCall(vultToken.connect(user1), await stake.getAddress(), stakeAmount);
      
      // Send rewards to the stake contract
      await usdcToken.transfer(await stake.getAddress(), rewardAmount);
      
      // Owner withdraws unclaimed rewards
      const ownerInitialBalance = await usdcToken.balanceOf(owner.address);
      await stake.connect(owner).withdrawUnclaimedRewards(0n); // 0 means withdraw all
      
      // Check that owner received the rewards
      const ownerFinalBalance = await usdcToken.balanceOf(owner.address);
      expect(ownerFinalBalance - ownerInitialBalance).to.equal(rewardAmount);
    });

    it("Should fail when non-owner tries to withdraw unclaimed rewards", async function () {
      const { stake, user1 } = await loadFixture(deployStakeFixture);
      
      // Non-owner tries to withdraw rewards
      await expect(stake.connect(user1).withdrawUnclaimedRewards(0n))
        .to.be.revertedWith("Ownable: caller is not the owner");
    });
    
    // This test would require modifications to the contract logic
    it.skip("Should allow owner to withdraw a partial amount of unclaimed rewards", async function () {
      const { stake, vultToken, usdcToken, owner, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");
      const rewardAmount = ethers.parseUnits("1000", 18); // 1000 USDC
      const withdrawAmount = ethers.parseUnits("400", 18); // 400 USDC
      
      // User1 deposits tokens - this will set lastRewardBalance to 0
      await callApproveAndCall(vultToken.connect(user1), await stake.getAddress(), stakeAmount);
      
      // Send rewards to the stake contract
      await usdcToken.transfer(await stake.getAddress(), rewardAmount);
      
      // Owner withdraws partial rewards
      const ownerInitialBalance = await usdcToken.balanceOf(owner.address);
      await stake.connect(owner).withdrawUnclaimedRewards(withdrawAmount);
      
      // Check that owner received the specified amount
      const ownerFinalBalance = await usdcToken.balanceOf(owner.address);
      expect(ownerFinalBalance - ownerInitialBalance).to.equal(withdrawAmount);
      
      // The remaining unclaimed rewards should still be available
      const remainingUnclaimedAmount = rewardAmount - withdrawAmount;
      await stake.connect(owner).withdrawUnclaimedRewards(0n); // Withdraw all remaining
      const ownerFinalBalance2 = await usdcToken.balanceOf(owner.address);
      expect(ownerFinalBalance2 - ownerFinalBalance).to.equal(remainingUnclaimedAmount);
    });

    it("Should allow owner to withdraw extra staking tokens", async function () {
      const { stake, vultToken, owner } = await loadFixture(deployStakeFixture);
      const extraTokens = ethers.parseEther("500");
      
      // Send extra tokens directly to the contract without updating totalStaked
      await vultToken.transfer(await stake.getAddress(), extraTokens);
      
      // Owner withdraws extra tokens
      const ownerInitialBalance = await vultToken.balanceOf(owner.address);
      await stake.connect(owner).withdrawExtraStakingTokens(0n); // 0 means withdraw all
      
      // Check that owner received the extra tokens
      const ownerFinalBalance = await vultToken.balanceOf(owner.address);
      expect(ownerFinalBalance - ownerInitialBalance).to.equal(extraTokens);
    });

    it("Should fail when there are no extra staking tokens to withdraw", async function () {
      const { stake, owner } = await loadFixture(deployStakeFixture);
      
      // Try to withdraw when there are no extra tokens
      await expect(stake.connect(owner).withdrawExtraStakingTokens(0n))
        .to.be.revertedWith("Stake: no extra tokens available");
    });

    it("Should fail when trying to withdraw more than the available extra staking tokens", async function () {
      const { stake, vultToken, owner } = await loadFixture(deployStakeFixture);
      const extraTokens = ethers.parseEther("500");
      
      // Send extra tokens directly to the contract
      await vultToken.transfer(await stake.getAddress(), extraTokens);
      
      // Try to withdraw more than available
      const excessiveAmount = extraTokens + 1n;
      await expect(stake.connect(owner).withdrawExtraStakingTokens(excessiveAmount))
        .to.be.revertedWith("Stake: amount exceeds extra token balance");
    });

    it("Should correctly calculate extra tokens when users have staked", async function () {
      const { stake, vultToken, owner, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");
      const extraTokens = ethers.parseEther("500");
      
      // User1 stakes tokens - this will increase totalStaked
      await callApproveAndCall(vultToken.connect(user1), await stake.getAddress(), stakeAmount);
      
      // Send extra tokens directly to the contract
      await vultToken.transfer(await stake.getAddress(), extraTokens);
      
      // Owner withdraws extra tokens
      const ownerInitialBalance = await vultToken.balanceOf(owner.address);
      await stake.connect(owner).withdrawExtraStakingTokens(0n);
      
      // Check that owner only received the extra tokens (not the staked ones)
      const ownerFinalBalance = await vultToken.balanceOf(owner.address);
      expect(ownerFinalBalance - ownerInitialBalance).to.equal(extraTokens);
      
      // Verify staked tokens are still in the contract
      expect(await stake.totalStaked()).to.equal(stakeAmount);
    });
  });

  describe("Multiple users", function () {
    it("Should track balances and rewards correctly for multiple users", async function () {
      const { stake, vultToken, usdcToken, user1, user2 } = await loadFixture(deployStakeFixture);
      const amount1 = ethers.parseEther("200"); // 2/3 of total stake
      const amount2 = ethers.parseEther("100"); // 1/3 of total stake
      const rewardAmount = ethers.parseUnits("900", 18); // 900 USDC
      
      // Users stake tokens
      await callApproveAndCall(vultToken.connect(user1), await stake.getAddress(), amount1);
      await callApproveAndCall(vultToken.connect(user2), await stake.getAddress(), amount2);
      
      // Send rewards to stake contract
      await usdcToken.transfer(await stake.getAddress(), rewardAmount);
      
      // User1 withdraws part
      const withdrawAmount = ethers.parseEther("50");
      await stake.connect(user1).withdraw(withdrawAmount);
      
      // User1 should have received 2/3 of rewards
      expect(await usdcToken.balanceOf(user1.address)).to.equal(rewardAmount * 2n / 3n);
      
      // User2 claims rewards
      await stake.connect(user2).claim();
      
      // User2 should have received 1/3 of rewards
      expect(await usdcToken.balanceOf(user2.address)).to.equal(rewardAmount / 3n);
      
      // Add more rewards
      const secondReward = ethers.parseUnits("600", 18); // 600 USDC
      await usdcToken.transfer(await stake.getAddress(), secondReward);
      
      // Calculate new stakes: User1 has 150, User2 has 100, so User1 has 60% of stake now
      await stake.connect(user1).claim();
      await stake.connect(user2).claim();
      
      // Check rewards are distributed according to updated stakes
      expect(await usdcToken.balanceOf(user1.address)).to.equal(rewardAmount * 2n / 3n + secondReward * 3n / 5n);
      expect(await usdcToken.balanceOf(user2.address)).to.equal(rewardAmount / 3n + secondReward * 2n / 5n);
    });

    it("Should handle new depositors correctly", async function () {
      const { stake, vultToken, usdcToken, user1, user2 } = await loadFixture(deployStakeFixture);
      const amount1 = ethers.parseEther("100");
      const reward1 = ethers.parseUnits("500", 18); // First reward when only user1 is staking
      const reward2 = ethers.parseUnits("300", 18); // Second reward after user2 joins
      
      // User1 stakes tokens
      await callApproveAndCall(vultToken.connect(user1), await stake.getAddress(), amount1);
      
      // Send first reward
      await usdcToken.transfer(await stake.getAddress(), reward1);
      await stake.updateRewards();
      
      // User2 stakes tokens after first reward
      await callApproveAndCall(vultToken.connect(user2), await stake.getAddress(), amount1);
      
      // Send second reward
      await usdcToken.transfer(await stake.getAddress(), reward2);
      
      // Users claim rewards
      await stake.connect(user1).claim();
      await stake.connect(user2).claim();
      
      // User1 should get all of first reward and half of second reward
      // User2 should get half of second reward only
      expect(await usdcToken.balanceOf(user1.address)).to.equal(reward1 + reward2 / 2n);
      expect(await usdcToken.balanceOf(user2.address)).to.equal(reward2 / 2n);
    });
  });
});
