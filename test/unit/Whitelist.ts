import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";

describe("Whitelist", function () {
  async function deployWhitelistFixture() {
    const [owner, otherAccount, batchedAccount, mockContract, pool] = await ethers.getSigners();

    const Whitelist = await ethers.getContractFactory("Whitelist");
    const whitelist = await Whitelist.deploy();
    await whitelist.setPool(pool);

    const MockOracleSuccess = await ethers.getContractFactory("MockOracleSuccess");
    const MockOracleFail = await ethers.getContractFactory("MockOracleFail");

    const mockOracleSuccess = await MockOracleSuccess.deploy();
    const mockOracleFail = await MockOracleFail.deploy();

    return {
      whitelist,
      mockOracleSuccess,
      mockOracleFail,
      owner,
      otherAccount,
      batchedAccount,
      mockContract,
      pool,
    };
  }

  describe("Deployment", function () {
    it("Should set max address cap, locked, isSelfWhitelistDisabled", async function () {
      const { whitelist } = await loadFixture(deployWhitelistFixture);

      expect(await whitelist.maxAddressCap()).to.eq(ethers.parseEther("4"));
      expect(await whitelist.locked()).to.eq(true);
    });
  });

  describe("Ownable", function () {
    // , max address cap, token, uniswap contract, isSelfWhitelistDisabled
    it("Should set locked", async function () {
      const { whitelist } = await loadFixture(deployWhitelistFixture);

      await whitelist.setLocked(false);
      expect(await whitelist.locked()).to.eq(false);
    });

    it("Should set max address cap", async function () {
      const { whitelist } = await loadFixture(deployWhitelistFixture);

      await whitelist.setMaxAddressCap(10_000_000 * 1e6);
      expect(await whitelist.maxAddressCap()).to.eq(10_000_000 * 1e6);
    });

    it("Should set token token", async function () {
      const { whitelist, mockContract } = await loadFixture(deployWhitelistFixture);

      await whitelist.setToken(mockContract.address);
      expect(await whitelist.token()).to.eq(mockContract.address);
    });

    // it("Should set self whitelist disabled", async function () {
    //   const { whitelist } = await loadFixture(deployWhitelistFixture);

    //   await whitelist.setIsSelfWhitelistDisabled(true);
    //   expect(await whitelist.isSelfWhitelistDisabled()).to.eq(true);
    // });

    it("Should set oracle contract", async function () {
      const { whitelist, mockOracleSuccess } = await loadFixture(deployWhitelistFixture);

      await whitelist.setOracle(mockOracleSuccess);
      expect(await whitelist.oracle()).to.eq(mockOracleSuccess);
    });

    it("Should set blacklisted", async function () {
      const { whitelist, otherAccount } = await loadFixture(deployWhitelistFixture);
      expect(await whitelist.isBlacklisted(otherAccount)).to.eq(false);
      await whitelist.setBlacklisted(otherAccount, true);
      expect(await whitelist.isBlacklisted(otherAccount)).to.eq(true);
    });

    it("Should set allowed sender and receiver whitelist index", async function () {
      const { whitelist } = await loadFixture(deployWhitelistFixture);
      const allowedSender = Math.floor(Math.random() * 1000);
      const allowedReceiver = Math.floor(Math.random() * 1000);
      
      expect(await whitelist.allowedSenderWhitelistIndex()).to.eq(0);
      await whitelist.setAllowedSenderWhitelistIndex(allowedSender);
      expect(await whitelist.allowedSenderWhitelistIndex()).to.eq(allowedSender);
      
      expect(await whitelist.allowedReceiverWhitelistIndex()).to.eq(0);
      await whitelist.setAllowedReceiverWhitelistIndex(allowedReceiver);
      expect(await whitelist.allowedReceiverWhitelistIndex()).to.eq(allowedReceiver);
    });

    it("Should add sender and receiver whitelisted address", async function () {
      const { whitelist, owner, otherAccount } = await loadFixture(deployWhitelistFixture);

      // Test sender whitelist
      expect(await whitelist.senderWhitelistIndex(owner)).to.eq(0);
      await whitelist.addSenderWhitelistedAddress(owner);
      expect(await whitelist.senderWhitelistIndex(owner)).to.eq(1);
      expect(await whitelist.senderWhitelistCount()).to.eq(1);

      expect(await whitelist.senderWhitelistIndex(otherAccount)).to.eq(0);
      await whitelist.addSenderWhitelistedAddress(otherAccount);
      expect(await whitelist.senderWhitelistIndex(otherAccount)).to.eq(2);
      expect(await whitelist.senderWhitelistCount()).to.eq(2);

      expect(await whitelist.senderWhitelistIndex(otherAccount)).to.eq(2);
      expect(await whitelist.senderWhitelistCount()).to.eq(2);
      
      // Test receiver whitelist
      expect(await whitelist.receiverWhitelistIndex(owner)).to.eq(0);
      await whitelist.addReceiverWhitelistedAddress(owner);
      expect(await whitelist.receiverWhitelistIndex(owner)).to.eq(1);
      expect(await whitelist.receiverWhitelistCount()).to.eq(1);

      expect(await whitelist.receiverWhitelistIndex(otherAccount)).to.eq(0);
      await whitelist.addReceiverWhitelistedAddress(otherAccount);
      expect(await whitelist.receiverWhitelistIndex(otherAccount)).to.eq(2);
      expect(await whitelist.receiverWhitelistCount()).to.eq(2);

      expect(await whitelist.receiverWhitelistIndex(otherAccount)).to.eq(2);
      expect(await whitelist.receiverWhitelistCount()).to.eq(2);
    });

    it("Should add batch sender and receiver whitelisted address", async function () {
      const { whitelist, otherAccount, batchedAccount } = await loadFixture(deployWhitelistFixture);

      // Test sender batch whitelist
      expect(await whitelist.senderWhitelistIndex(otherAccount)).to.eq(0);
      expect(await whitelist.senderWhitelistIndex(batchedAccount)).to.eq(0);
      expect(await whitelist.senderWhitelistCount()).to.eq(0);
      await whitelist.addBatchSenderWhitelist([otherAccount, batchedAccount, otherAccount]);
      expect(await whitelist.senderWhitelistIndex(otherAccount)).to.eq(1);
      expect(await whitelist.senderWhitelistIndex(batchedAccount)).to.eq(2);
      expect(await whitelist.senderWhitelistCount()).to.eq(2);
      
      // Test receiver batch whitelist
      expect(await whitelist.receiverWhitelistIndex(otherAccount)).to.eq(0);
      expect(await whitelist.receiverWhitelistIndex(batchedAccount)).to.eq(0);
      expect(await whitelist.receiverWhitelistCount()).to.eq(0);
      await whitelist.addBatchReceiverWhitelist([otherAccount, batchedAccount, otherAccount]);
      expect(await whitelist.receiverWhitelistIndex(otherAccount)).to.eq(1);
      expect(await whitelist.receiverWhitelistIndex(batchedAccount)).to.eq(2);
      expect(await whitelist.receiverWhitelistCount()).to.eq(2);
    });

    it("Should revert if called from non-owner address", async function () {
      const { whitelist, otherAccount, batchedAccount, mockContract } = await loadFixture(deployWhitelistFixture);

      await expect(whitelist.connect(otherAccount).setLocked(true)).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );
      await expect(whitelist.connect(otherAccount).setMaxAddressCap(10_000)).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );
      await expect(whitelist.connect(otherAccount).setToken(mockContract)).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );
      // await expect(whitelist.connect(otherAccount).setIsSelfWhitelistDisabled(true)).to.be.revertedWith(
      //   "Ownable: caller is not the owner",
      // );
      await expect(whitelist.connect(otherAccount).setOracle(mockContract)).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );
      await expect(whitelist.connect(otherAccount).setBlacklisted(mockContract, true)).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );

      await expect(whitelist.connect(otherAccount).setAllowedSenderWhitelistIndex(100)).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );
      
      await expect(whitelist.connect(otherAccount).setAllowedReceiverWhitelistIndex(100)).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );

      await expect(whitelist.connect(otherAccount).addSenderWhitelistedAddress(otherAccount)).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );
      
      await expect(whitelist.connect(otherAccount).addReceiverWhitelistedAddress(otherAccount)).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );
      
      await expect(
        whitelist.connect(otherAccount).addBatchSenderWhitelist([otherAccount, batchedAccount]),
      ).to.be.revertedWith("Ownable: caller is not the owner");
      
      await expect(
        whitelist.connect(otherAccount).addBatchReceiverWhitelist([otherAccount, batchedAccount]),
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  // describe("Self-whitelist", function () {
  //   it("Should self whitelist when ETH is sent", async function () {
  //     const { whitelist, otherAccount } = await loadFixture(deployWhitelistFixture);
  //     expect(await whitelist.whitelistIndex(otherAccount)).to.eq(0);
  //     const balanceChange = 67335443339441n;

  //     expect(
  //       await otherAccount.sendTransaction({
  //         to: whitelist,
  //         value: ethers.parseEther("1"),
  //       }),
  //     ).to.changeEtherBalance(otherAccount, -balanceChange);
  //     expect(await whitelist.whitelistIndex(otherAccount)).to.eq(1);
  //     expect(
  //       await otherAccount.sendTransaction({
  //         to: whitelist,
  //         value: ethers.parseEther("1"),
  //       }),
  //     ).to.changeEtherBalance(otherAccount, -balanceChange);
  //     expect(await whitelist.whitelistIndex(otherAccount)).to.eq(1);
  //     expect(await whitelist.whitelistCount()).to.eq(1);
  //   });

  //   it("Should revert if self whitelist is disabled by owner", async function () {
  //     const { whitelist, otherAccount } = await loadFixture(deployWhitelistFixture);

  //     await whitelist.setIsSelfWhitelistDisabled(true);

  //     await expect(
  //       otherAccount.sendTransaction({
  //         to: whitelist,
  //         value: ethers.parseEther("1"),
  //       }),
  //     ).to.be.revertedWithCustomError(whitelist, "SelfWhitelistDisabled");
  //   });

  //   it("Should revert if blacklisted by owner", async function () {
  //     const { whitelist, otherAccount } = await loadFixture(deployWhitelistFixture);

  //     await whitelist.setBlacklisted(otherAccount, true);

  //     await expect(
  //       otherAccount.sendTransaction({
  //         to: whitelist,
  //         value: ethers.parseEther("1"),
  //       }),
  //     ).to.be.revertedWithCustomError(whitelist, "Blacklisted");
  //   });
  // });

  describe("Checkwhitelist", function () {
    it("Should revert when called from non token contract", async function () {
      const { whitelist, otherAccount, pool } = await loadFixture(deployWhitelistFixture);

      await expect(whitelist.checkWhitelist(pool, otherAccount, 0)).to.be.revertedWithCustomError(
        whitelist,
        "NotToken",
      );
    });

    it("Should revert when locked, blacklisted or not whitelisted", async function () {
      const { whitelist, pool, otherAccount, batchedAccount, mockContract } = await loadFixture(deployWhitelistFixture);

      await whitelist.setToken(mockContract);

      // Test with normal addresses instead of pool (since we skip pool checks in our new implementation)
      await expect(whitelist.connect(mockContract).checkWhitelist(otherAccount, batchedAccount, 0)).to.be.revertedWithCustomError(
        whitelist,
        "Locked",
      );

      await whitelist.setLocked(false);
      
      // Test sender not whitelisted
      await expect(whitelist.connect(mockContract).checkWhitelist(otherAccount, batchedAccount, 0)).to.be.revertedWithCustomError(
        whitelist,
        "SenderNotWhitelisted",
      );
      
      // Add sender to whitelist
      await whitelist.addSenderWhitelistedAddress(otherAccount);
      await whitelist.setAllowedSenderWhitelistIndex(1);
      
      // Now test receiver not whitelisted
      await expect(whitelist.connect(mockContract).checkWhitelist(otherAccount, batchedAccount, 0)).to.be.revertedWithCustomError(
        whitelist,
        "ReceiverNotWhitelisted",
      );
      
      // Now add receiver to whitelist
      await whitelist.addReceiverWhitelistedAddress(batchedAccount);
      await whitelist.setAllowedReceiverWhitelistIndex(1);
      
      // Test blacklist function for sender
      await whitelist.setBlacklisted(otherAccount, true);
      await expect(whitelist.connect(mockContract).checkWhitelist(otherAccount, batchedAccount, 0)).to.be.revertedWithCustomError(
        whitelist,
        "Blacklisted",
      );
      
      // Clear blacklist and put it on receiver
      await whitelist.setBlacklisted(otherAccount, false);
      await whitelist.setBlacklisted(batchedAccount, true);
      
      await expect(whitelist.connect(mockContract).checkWhitelist(otherAccount, batchedAccount, 0)).to.be.revertedWithCustomError(
        whitelist,
        "Blacklisted",
      );
    });

    it("Should revert when ETH amount exceeds max address cap or already contributed", async function () {
      const { whitelist, mockOracleFail, mockOracleSuccess, pool, otherAccount, mockContract } =
        await loadFixture(deployWhitelistFixture);

      await whitelist.setToken(mockContract);
      await whitelist.setOracle(mockOracleFail);
      await whitelist.setLocked(false);
      
      // Set up separate sender (pool) and receiver (otherAccount) whitelists
      await whitelist.addSenderWhitelistedAddress(pool);
      await whitelist.addReceiverWhitelistedAddress(otherAccount);
      await whitelist.setAllowedSenderWhitelistIndex(1);
      await whitelist.setAllowedReceiverWhitelistIndex(1);
      
      // Set max address cap to very low (0.1 ETH) so mockOracleFail returns more than the cap
      await whitelist.setMaxAddressCap(ethers.parseEther("0.1"));

      await expect(whitelist.connect(mockContract).checkWhitelist(pool, otherAccount, 1000)).to.be.revertedWithCustomError(
        whitelist,
        "MaxAddressCapOverflow",
      );

      // Now set back a reasonable cap and use the successful oracle
      await whitelist.setMaxAddressCap(ethers.parseEther("4"));
      await whitelist.setOracle(mockOracleSuccess);
      await whitelist.connect(mockContract).checkWhitelist(pool, otherAccount, 0);
      expect(await whitelist.contributed(otherAccount)).to.eq(ethers.parseEther("1.5"));

      await whitelist.connect(mockContract).checkWhitelist(pool, otherAccount, 0);
      expect(await whitelist.contributed(otherAccount)).to.eq(ethers.parseEther("3"));

      await expect(whitelist.connect(mockContract).checkWhitelist(pool, otherAccount, 0)).to.be.revertedWithCustomError(
        whitelist,
        "MaxAddressCapOverflow",
      );
    });
  });
});
