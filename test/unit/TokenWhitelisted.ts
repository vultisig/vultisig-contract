import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";

describe("TokenWhitelisted", function () {
  async function deployTokenWhitelistedFixture() {
    const [owner, otherAccount] = await ethers.getSigners();

    const TokenWhitelisted = await ethers.getContractFactory("TokenWhitelisted");
    const token = await TokenWhitelisted.deploy("", "", ethers.ZeroAddress);

    const MockWhitelistSuccess = await ethers.getContractFactory("MockWhitelistSuccess");
    const MockWhitelistFail = await ethers.getContractFactory("MockWhitelistFail");

    const mockWhitelistSuccess = await MockWhitelistSuccess.deploy();
    const mockWhitelistFail = await MockWhitelistFail.deploy();

    return { token, owner, otherAccount, mockWhitelistSuccess, mockWhitelistFail };
  }

  describe("Ownable", function () {
    it("Should set the right whitelist contract", async function () {
      const { token, mockWhitelistSuccess } = await loadFixture(deployTokenWhitelistedFixture);

      await token.setWhitelistContract(mockWhitelistSuccess);

      expect(await token.whitelistContract()).to.eq(mockWhitelistSuccess);
    });

    it("Should revert if called from non-owner contract", async function () {
      const { token, otherAccount, mockWhitelistSuccess } = await loadFixture(deployTokenWhitelistedFixture);

      await expect(token.connect(otherAccount).setWhitelistContract(mockWhitelistSuccess)).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );
    });
  });

  describe("Transfer", function () {
    it("Should transfer when whitelist contract is not set", async function () {
      const amount = ethers.parseEther("1000");
      const { token, owner, otherAccount } = await loadFixture(deployTokenWhitelistedFixture);
      expect(await token.transfer(otherAccount.address, amount)).to.changeTokenBalances(
        token,
        [owner.address, otherAccount.address],
        [-amount, amount],
      );
    });

    it("Should transfer when checkWhitelist succeeds", async function () {
      const amount = ethers.parseEther("1000");
      const { token, owner, otherAccount, mockWhitelistSuccess } = await loadFixture(deployTokenWhitelistedFixture);
      await token.setWhitelistContract(mockWhitelistSuccess);
      expect(await token.transfer(otherAccount.address, amount)).to.changeTokenBalances(
        token,
        [owner.address, otherAccount.address],
        [-amount, amount],
      );
    });

    it("Should revert transfer when checkWhitelist reverts", async function () {
      const amount = ethers.parseEther("1000");
      const { token, otherAccount, mockWhitelistFail } = await loadFixture(deployTokenWhitelistedFixture);

      await token.setWhitelistContract(mockWhitelistFail);
      await expect(token.transfer(otherAccount.address, amount)).to.be.reverted;
    });

    it("Should revert transfer when sent to the token contract", async function () {
      const amount = ethers.parseEther("1000");
      const { token } = await loadFixture(deployTokenWhitelistedFixture);
      await expect(token.transfer(token, amount)).to.be.revertedWith("Cannot transfer to the token contract address");
    });
  });
});
