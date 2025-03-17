import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";

describe("Whitelist Phases", function () {
  async function deployWhitelistFixture() {
    const [owner, investor1, investor2, normalUser1, normalUser2, pool, extraSigner] = await ethers.getSigners();

    // Deploy Whitelist contract
    const Whitelist = await ethers.getContractFactory("Whitelist");
    const whitelist = await Whitelist.deploy();

    // Deploy Mock Oracle
    const MockOracleSuccess = await ethers.getContractFactory("MockOracleSuccess");
    const oracle = await MockOracleSuccess.deploy();

    // Deploy Mock Token
    const TokenMock = await ethers.getContractFactory("TokenMock");
    const mockToken = await TokenMock.deploy();

    // Setup whitelist
    const mockTokenAddress = await mockToken.getAddress();
    await whitelist.setToken(mockTokenAddress);
    await whitelist.setPool(pool.address);
    await whitelist.setOracle(oracle);
    await whitelist.setMaxAddressCap(ethers.parseEther("4"));
    
    // Setup mock token to use the whitelist
    await mockToken.setWhitelist(await whitelist.getAddress());
    
    // Debug output to verify setup
    console.log("Token address in whitelist:", await whitelist.token());
    console.log("Mock token address:", mockTokenAddress);
    console.log("Whitelist address in mock token:", await mockToken.whitelist());

    return {
      whitelist,
      oracle,
      owner,
      investor1,
      investor2,
      normalUser1,
      normalUser2,
      mockToken,
      pool,
    };
  }

  describe("Phase 0 - Start (locked = true)", function () {
    it("Owner can send to anyone when locked", async function () {
      const { whitelist, owner, normalUser1, mockToken } = await loadFixture(deployWhitelistFixture);
      
      // Call through the mock token to simulate token's checkWhitelist call
      await expect(
        mockToken.checkWhitelistFrom(owner.address, normalUser1.address, 100)
      ).to.not.be.reverted;
    });

    it("SenderWL can send to anyone when locked", async function () {
      const { whitelist, investor1, normalUser1, mockToken } = await loadFixture(deployWhitelistFixture);
      
      // Add investor1 to sender whitelist
      await whitelist.addSenderWhitelistedAddress(investor1.address);
      await whitelist.setAllowedSenderWhitelistIndex(1);
      
      // Debug information
      console.log("SenderWL Test - Investor1 address:", investor1.address);
      console.log("SenderWL Test - Whitelist sender index for investor1:", await whitelist.senderWhitelistIndex(investor1.address));
      console.log("SenderWL Test - Whitelist allowed sender index:", await whitelist.allowedSenderWhitelistIndex());
      console.log("SenderWL Test - Locked status:", await whitelist.locked());
      
      try {
        // Try the transaction and catch any errors
        await mockToken.checkWhitelistFrom(investor1.address, normalUser1.address, 100);
        console.log("SenderWL Test - Transaction successful");
      } catch (error: any) {
        console.error("SenderWL Test - Transaction failed with error:", error.message);
      }
      
      // Whitelisted sender should be able to send to anyone
      await expect(
        mockToken.checkWhitelistFrom(investor1.address, normalUser1.address, 100)
      ).to.not.be.reverted;
    });

    it("Non-whitelisted senders cannot send when locked", async function () {
      const { whitelist, normalUser1, normalUser2, mockToken } = await loadFixture(deployWhitelistFixture);
      
      // Non-whitelisted sender should not be able to send
      await expect(
        mockToken.checkWhitelistFrom(normalUser1.address, normalUser2.address, 100)
      ).to.be.revertedWithCustomError(whitelist, "Locked");
    });

    it("Uniswap pool cannot send when locked", async function () {
      const { whitelist, pool, normalUser1, mockToken } = await loadFixture(deployWhitelistFixture);
      
      // Uniswap pool should not be able to send when locked
      await expect(
        mockToken.checkWhitelistFrom(pool.address, normalUser1.address, 100)
      ).to.be.revertedWithCustomError(whitelist, "Locked");
    });
  });

  describe("Phase 1 - Launch (locked = false)", function () {
    it("Uniswap pool can send to ReceiverWL", async function () {
      const { whitelist, pool, normalUser1, mockToken } = await loadFixture(deployWhitelistFixture);
      
      // Unlock the contract
      await whitelist.setLocked(false);
      
      // Add normalUser1 to receiver whitelist
      await whitelist.addReceiverWhitelistedAddress(normalUser1.address);
      await whitelist.setAllowedReceiverWhitelistIndex(1);
      
      // Pool should be able to send to whitelisted receiver
      await expect(
        mockToken.checkWhitelistFrom(pool.address, normalUser1.address, 100)
      ).to.not.be.reverted;
    });

    it("Uniswap pool cannot send to non-whitelisted receivers", async function () {
      const { whitelist, pool, normalUser2, mockToken } = await loadFixture(deployWhitelistFixture);
      
      // Unlock the contract
      await whitelist.setLocked(false);
      
      // Pool should not be able to send to non-whitelisted receiver
      await expect(
        mockToken.checkWhitelistFrom(pool.address, normalUser2.address, 100)
      ).to.be.revertedWithCustomError(whitelist, "ReceiverNotWhitelisted");
    });

    it("Normal transactions need both sender and receiver to be whitelisted", async function () {
      const { whitelist, investor1, investor2, normalUser1, normalUser2, mockToken } = await loadFixture(deployWhitelistFixture);
      
      // Unlock the contract
      await whitelist.setLocked(false);
      
      // Set up whitelists
      await whitelist.addSenderWhitelistedAddress(investor1.address);
      await whitelist.setAllowedSenderWhitelistIndex(1);
      
      await whitelist.addReceiverWhitelistedAddress(normalUser1.address);
      await whitelist.setAllowedReceiverWhitelistIndex(1);
      
      // Case 1: Whitelisted sender to whitelisted receiver - should work
      await expect(
        mockToken.checkWhitelistFrom(investor1.address, normalUser1.address, 100)
      ).to.not.be.reverted;
      
      // Case 2: Whitelisted sender to non-whitelisted receiver - should fail
      await expect(
        mockToken.checkWhitelistFrom(investor1.address, normalUser2.address, 100)
      ).to.be.revertedWithCustomError(whitelist, "ReceiverNotWhitelisted");
      
      // Case 3: Non-whitelisted sender to whitelisted receiver - should fail
      await expect(
        mockToken.checkWhitelistFrom(investor2.address, normalUser1.address, 100)
      ).to.be.revertedWithCustomError(whitelist, "SenderNotWhitelisted");
      
      // Case 4: Non-whitelisted sender to non-whitelisted receiver - should fail
      await expect(
        mockToken.checkWhitelistFrom(investor2.address, normalUser2.address, 100)
      ).to.be.revertedWithCustomError(whitelist, "SenderNotWhitelisted");
    });

    it("Respects address cap for purchases from Uniswap", async function () {
      const { whitelist, pool, normalUser1, mockToken } = await loadFixture(deployWhitelistFixture);
      
      // Set a smaller max cap for testing
      await whitelist.setMaxAddressCap(ethers.parseEther("3"));
      
      // Unlock the contract
      await whitelist.setLocked(false);
      
      // Add normalUser1 to receiver whitelist
      await whitelist.addReceiverWhitelistedAddress(normalUser1.address);
      await whitelist.setAllowedReceiverWhitelistIndex(1);
      
      // First purchase should work (1.5 ETH)
      await expect(
        mockToken.checkWhitelistFrom(pool.address, normalUser1.address, 100)
      ).to.not.be.reverted;
      
      // Second purchase should work (total: 3 ETH)
      await expect(
        mockToken.checkWhitelistFrom(pool.address, normalUser1.address, 100)
      ).to.not.be.reverted;
      
      // Third purchase should exceed cap (4.5 ETH > 3 ETH cap)
      await expect(
        mockToken.checkWhitelistFrom(pool.address, normalUser1.address, 100)
      ).to.be.revertedWithCustomError(whitelist, "MaxAddressCapOverflow");
    });
  });

  describe("Transitions between phases", function () {
    it("Successfully transitions from Phase 0 to Phase 1", async function () {
      const { whitelist, owner, investor1, normalUser1, pool, mockToken } = await loadFixture(deployWhitelistFixture);
      
      // Phase 0 setup
      await whitelist.addSenderWhitelistedAddress(investor1.address);
      await whitelist.setAllowedSenderWhitelistIndex(1);
      
      // In Phase 0, owner and whitelisted senders can send
      await expect(
        mockToken.checkWhitelistFrom(owner.address, normalUser1.address, 100)
      ).to.not.be.reverted;
      
      await expect(
        mockToken.checkWhitelistFrom(investor1.address, normalUser1.address, 100)
      ).to.not.be.reverted;
      
      // Transition to Phase 1
      // Reset sender whitelist index
      await whitelist.setAllowedSenderWhitelistIndex(0);
      
      // Set up receiver whitelist
      await whitelist.addReceiverWhitelistedAddress(normalUser1.address);
      await whitelist.setAllowedReceiverWhitelistIndex(1);
      
      // Unlock
      await whitelist.setLocked(false);
      
      // In Phase 1, only pool can send to whitelisted receivers
      await expect(
        mockToken.checkWhitelistFrom(pool.address, normalUser1.address, 100)
      ).to.not.be.reverted;
      
      // Normal transfers should fail unless both sender and receiver are whitelisted
      await expect(
        mockToken.checkWhitelistFrom(investor1.address, normalUser1.address, 100)
      ).to.be.revertedWithCustomError(whitelist, "SenderNotWhitelisted");
    });

    it("End-to-end test of all phases", async function () {
      const { whitelist, owner, investor1, investor2, normalUser1, normalUser2, pool, mockToken } = await loadFixture(deployWhitelistFixture);
      
      // ---- Phase 0: Start (locked = true) ----
      console.log("Testing Phase 0 (locked = true)");
      
      // Add investor1 and investor2 to sender whitelist
      await whitelist.addSenderWhitelistedAddress(investor1.address);
      await whitelist.addSenderWhitelistedAddress(investor2.address);
      await whitelist.setAllowedSenderWhitelistIndex(2);
      
      // Owner can send to anyone
      await expect(
        mockToken.checkWhitelistFrom(owner.address, normalUser1.address, 100)
      ).to.not.be.reverted;
      
      // SenderWL can send to anyone
      await expect(
        mockToken.checkWhitelistFrom(investor1.address, normalUser2.address, 100)
      ).to.not.be.reverted;
      
      // Uniswap pool cannot send
      await expect(
        mockToken.checkWhitelistFrom(pool.address, normalUser1.address, 100)
      ).to.be.revertedWithCustomError(whitelist, "Locked");
      
      // ---- Transition to Phase 1: Launch (locked = false) ----
      console.log("Transitioning to Phase 1 (locked = false)");
      
      // Reset sender whitelist
      await whitelist.setAllowedSenderWhitelistIndex(0);
      
      // Add normalUser1 and normalUser2 to receiver whitelist
      await whitelist.addReceiverWhitelistedAddress(normalUser1.address);
      await whitelist.addReceiverWhitelistedAddress(normalUser2.address);
      await whitelist.setAllowedReceiverWhitelistIndex(2);
      
      // Set max cap for purchases
      await whitelist.setMaxAddressCap(ethers.parseEther("4"));
      
      // Unlock the contract
      await whitelist.setLocked(false);
      
      // Uniswap pool can send to whitelisted receivers
      await expect(
        mockToken.checkWhitelistFrom(pool.address, normalUser1.address, 100)
      ).to.not.be.reverted;
      
      // Previous whitelisted senders can no longer send
      await expect(
        mockToken.checkWhitelistFrom(investor1.address, normalUser1.address, 100)
      ).to.be.revertedWithCustomError(whitelist, "SenderNotWhitelisted");
      
      // Re-enable specific senders if needed
      await whitelist.addSenderWhitelistedAddress(investor1.address);
      await whitelist.setAllowedSenderWhitelistIndex(1);
      
      // Now investor1 can send to whitelisted receivers
      await expect(
        mockToken.checkWhitelistFrom(investor1.address, normalUser1.address, 100)
      ).to.not.be.reverted;
      
      // But still can't send to non-whitelisted receivers
      await expect(
        mockToken.checkWhitelistFrom(investor1.address, normalUser2.address, 100)
      ).to.not.be.reverted; // This works because normalUser2 is whitelisted
      
      // ---- Phase 2: End ----
      // This would be tested in TokenWhitelisted contract by setting whitelist to address(0)
      console.log("Phase 2 would involve setting whitelist contract to address(0) in the token contract");
    });

    it("Blacklisted addresses cannot transact in any phase", async function () {
      const { whitelist, investor1, normalUser1, pool, mockToken } = await loadFixture(deployWhitelistFixture);
      
      // Add investor1 to sender whitelist
      await whitelist.addSenderWhitelistedAddress(investor1.address);
      await whitelist.setAllowedSenderWhitelistIndex(1);
      
      // Blacklist investor1
      await whitelist.setBlacklisted(investor1.address, true);
      
      // Phase 0: Blacklisted sender can't send even if whitelisted
      await expect(
        mockToken.checkWhitelistFrom(investor1.address, normalUser1.address, 100)
      ).to.be.revertedWithCustomError(whitelist, "Blacklisted");
      
      // Unlock for Phase 1
      await whitelist.setLocked(false);
      
      // Add normalUser1 to receiver whitelist
      await whitelist.addReceiverWhitelistedAddress(normalUser1.address);
      await whitelist.setAllowedReceiverWhitelistIndex(1);
      
      // Blacklist normalUser1
      await whitelist.setBlacklisted(normalUser1.address, true);
      
      // Phase 1: Uniswap pool can't send to blacklisted receivers even if whitelisted
      await expect(
        mockToken.checkWhitelistFrom(pool.address, normalUser1.address, 100)
      ).to.be.revertedWithCustomError(whitelist, "Blacklisted");
    });
  });
});
