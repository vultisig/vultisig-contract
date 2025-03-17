import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";

describe("TokenWhitelisted", function () {
  async function deployTokenWhitelistedFixture() {
    const [owner, otherAccount] = await ethers.getSigners();

    const TokenWhitelisted = await ethers.getContractFactory("TokenWhitelisted");
    const token = await TokenWhitelisted.deploy("", "");

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
    
    it("Should revoke whitelist setting and clear whitelist contract", async function () {
      const { token, mockWhitelistSuccess, mockWhitelistFail } = await loadFixture(deployTokenWhitelistedFixture);
      
      // First set a whitelist contract
      await token.setWhitelistContract(mockWhitelistSuccess);
      expect(await token.whitelistContract()).to.eq(mockWhitelistSuccess);
      
      // Revoke the ability to change the whitelist
      await token.revokeSettingWhitelist();
      
      // Verify the whitelist contract address is now cleared (set to address(0))
      expect(await token.whitelistContract()).to.eq("0x0000000000000000000000000000000000000000");
      
      // Try to set a new whitelist contract - should have no effect due to revocation
      await token.setWhitelistContract(mockWhitelistFail);
      
      // Verify the whitelist contract address remains at address(0) and cannot be changed
      expect(await token.whitelistContract()).to.eq("0x0000000000000000000000000000000000000000");
    });
    
    it("Should not allow non-owner to revoke whitelist setting", async function () {
      const { token, otherAccount } = await loadFixture(deployTokenWhitelistedFixture);
      
      // Attempt to revoke from non-owner account
      await expect(token.connect(otherAccount).revokeSettingWhitelist()).to.be.revertedWith(
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
