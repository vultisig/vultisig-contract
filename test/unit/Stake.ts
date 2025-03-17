import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { Token, Stake } from "../../typechain-types";

describe("Stake", function () {
  // We define a fixture to reuse the same setup in every test
  async function deployStakeFixture() {
    // Get signers
    const [owner, user1, user2, user3] = await ethers.getSigners();

    // Deploy token
    const Token = await ethers.getContractFactory("Token");
    const token = await Token.deploy("Vultisig Token", "VULT");

    // Deploy stake contract
    const Stake = await ethers.getContractFactory("Stake");
    const stake = await Stake.deploy(await token.getAddress());

    // Transfer some tokens to users for testing
    const amount = ethers.parseEther("1000");
    await token.transfer(user1.address, amount);
    await token.transfer(user2.address, amount);

    return { stake, token, owner, user1, user2, user3 };
  }

  describe("Deployment", function () {
    it("Should set the correct token address", async function () {
      const { stake, token } = await loadFixture(deployStakeFixture);
      expect(await stake.token()).to.equal(await token.getAddress());
    });

    it("Should have zero total staked initially", async function () {
      const { stake } = await loadFixture(deployStakeFixture);
      expect(await stake.totalStaked()).to.equal(0);
    });
  });

  describe("Deposits", function () {
    it("Should allow staking tokens with deposit function", async function () {
      const { stake, token, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");

      // Approve tokens first
      await token.connect(user1).approve(await stake.getAddress(), stakeAmount);
      
      // Deposit tokens
      await stake.connect(user1).deposit(stakeAmount);
      
      // Check balances
      expect(await stake.balanceOf(user1.address)).to.equal(stakeAmount);
      expect(await stake.totalStaked()).to.equal(stakeAmount);
      expect(await token.balanceOf(await stake.getAddress())).to.equal(stakeAmount);
    });

    it("Should allow staking tokens with approveAndCall", async function () {
      const { stake, token, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");
      
      // Use approveAndCall
      await token.connect(user1).approveAndCall(await stake.getAddress(), stakeAmount);
      
      // Check balances
      expect(await stake.balanceOf(user1.address)).to.equal(stakeAmount);
      expect(await stake.totalStaked()).to.equal(stakeAmount);
      expect(await token.balanceOf(await stake.getAddress())).to.equal(stakeAmount);
    });

    it("Should fail if staking zero tokens", async function () {
      const { stake, token, user1 } = await loadFixture(deployStakeFixture);
      
      // Try to deposit zero tokens
      await expect(stake.connect(user1).deposit(0))
        .to.be.revertedWith("Stake: amount must be greater than 0");
      
      // Try approveAndCall with zero tokens
      await expect(token.connect(user1).approveAndCall(await stake.getAddress(), 0))
        .to.be.revertedWith("Stake: amount must be greater than 0");
    });
  });

  describe("Withdrawals", function () {
    it("Should allow withdrawing staked tokens", async function () {
      const { stake, token, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");
      const withdrawAmount = ethers.parseEther("40");
      
      // Stake tokens first
      await token.connect(user1).approveAndCall(await stake.getAddress(), stakeAmount);
      
      // Withdraw part of the tokens
      await stake.connect(user1).withdraw(withdrawAmount);
      
      // Check balances
      expect(await stake.balanceOf(user1.address)).to.equal(stakeAmount - withdrawAmount);
      expect(await stake.totalStaked()).to.equal(stakeAmount - withdrawAmount);
      expect(await token.balanceOf(await stake.getAddress())).to.equal(stakeAmount - withdrawAmount);
      expect(await token.balanceOf(user1.address)).to.equal(ethers.parseEther("940"));
    });

    it("Should allow withdrawing all staked tokens", async function () {
      const { stake, token, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");
      
      // Stake tokens first
      await token.connect(user1).approveAndCall(await stake.getAddress(), stakeAmount);
      
      // Withdraw all tokens
      await stake.connect(user1).withdraw(stakeAmount);
      
      // Check balances
      expect(await stake.balanceOf(user1.address)).to.equal(0);
      expect(await stake.totalStaked()).to.equal(0);
      expect(await token.balanceOf(await stake.getAddress())).to.equal(0);
      expect(await token.balanceOf(user1.address)).to.equal(ethers.parseEther("1000"));
    });

    it("Should fail when withdrawing more than staked", async function () {
      const { stake, token, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");
      
      // Stake tokens first
      await token.connect(user1).approveAndCall(await stake.getAddress(), stakeAmount);
      
      // Try to withdraw more than staked
      await expect(stake.connect(user1).withdraw(stakeAmount + 1n))
        .to.be.revertedWith("Stake: insufficient balance");
    });

    it("Should fail when withdrawing zero tokens", async function () {
      const { stake, token, user1 } = await loadFixture(deployStakeFixture);
      const stakeAmount = ethers.parseEther("100");
      
      // Stake tokens first
      await token.connect(user1).approveAndCall(await stake.getAddress(), stakeAmount);
      
      // Try to withdraw zero tokens
      await expect(stake.connect(user1).withdraw(0))
        .to.be.revertedWith("Stake: amount must be greater than 0");
    });
  });

  describe("Multiple users", function () {
    it("Should track balances correctly for multiple users", async function () {
      const { stake, token, user1, user2 } = await loadFixture(deployStakeFixture);
      const amount1 = ethers.parseEther("100");
      const amount2 = ethers.parseEther("200");
      
      // User1 stakes tokens
      await token.connect(user1).approveAndCall(await stake.getAddress(), amount1);
      
      // User2 stakes tokens
      await token.connect(user2).approveAndCall(await stake.getAddress(), amount2);
      
      // Check individual balances
      expect(await stake.balanceOf(user1.address)).to.equal(amount1);
      expect(await stake.balanceOf(user2.address)).to.equal(amount2);
      
      // Check total staked
      expect(await stake.totalStaked()).to.equal(amount1 + amount2);
      
      // User1 withdraws part of tokens
      const withdrawAmount = ethers.parseEther("30");
      await stake.connect(user1).withdraw(withdrawAmount);
      
      // Check updated balances
      expect(await stake.balanceOf(user1.address)).to.equal(amount1 - withdrawAmount);
      expect(await stake.balanceOf(user2.address)).to.equal(amount2);
      expect(await stake.totalStaked()).to.equal(amount1 + amount2 - withdrawAmount);
    });
  });
});
