import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import hre, { ethers } from "hardhat";
const {BN} = require('@openzeppelin/test-helpers');


let initialSupply = new BN("750000000000000000000000000");

describe("Merge Contract", function () {
  async function deployFixture() {
    const [owner, otherAccount] = await ethers.getSigners();

    const TokenIOU = await ethers.getContractFactory("TokenIOU");
    const Tgt = await ethers.getContractFactory("TGT");

    const vult = await TokenIOU.deploy("", "");
    const mockVult = await TokenIOU.deploy("", "");

    const tgt = await Tgt.deploy();
    const mockTgt = await Tgt.deploy();

    const MergeTgt = await ethers.getContractFactory("MergeTgt");
    const mergeTgt = await MergeTgt.deploy(await tgt.getAddress(), await vult.getAddress());

    return { owner, otherAccount, vult, tgt, mergeTgt, mockTgt, mockVult };
  }

  describe("Initial Setup", function () {
    it("Should set the correct initial values", async function () {
      const { mergeTgt, vult,tgt } = await loadFixture(deployFixture);
      expect(await mergeTgt.tgt()).to.equal(await tgt.getAddress());
      expect(await mergeTgt.vult()).to.equal(await vult.getAddress());
      expect(await mergeTgt.vultBalance()).to.equal(0);
      expect(await mergeTgt.lockedStatus()).to.equal(0);
    });
  });

  describe("receiveApproval Function", function () {
    it("Should revert if called by a non-Tgt token", async function () {
        

      const { owner,mergeTgt, mockTgt } = await loadFixture(deployFixture);

      let acc = new Array(owner.address);
      let amount = new Array(initialSupply.toString());
      await mockTgt.mint(acc, amount);
      await mockTgt.mintFinish();
      await mockTgt.approve(owner, 1000);

      await expect(mockTgt.transferAndCall(mergeTgt, 1000, "0x")).to.be.revertedWithCustomError(
        mergeTgt,
        "InvalidTokenReceived",
      );
    });

    it("Should revert if locked status is Locked", async function () {
      const { owner, mergeTgt, tgt } = await loadFixture(deployFixture);

      let acc = new Array(owner.address);
      let amount = new Array(initialSupply.toString());
      await tgt.mint(acc, amount);
      await tgt.mintFinish();
      await tgt.approve(owner, 1000);

      await expect(tgt.transferAndCall(mergeTgt, 1000, "0x")).to.be.revertedWithCustomError(mergeTgt, "MergeLocked");
    });

    it("Should revert if amount is zero", async function () {
      const { owner, mergeTgt, tgt } = await loadFixture(deployFixture);
      await mergeTgt.setLockedStatus(1);

      let acc = new Array(owner.address);
      let amount = new Array(initialSupply.toString());
      await tgt.mint(acc, amount);
      await tgt.mintFinish();
      await tgt.approve(owner, 1000);

      await expect(tgt.transferAndCall(mergeTgt, 0, "0x")).to.be.revertedWithCustomError(mergeTgt, "ZeroAmount");
    });

    it("Should correctly transfer Tgt", async function () {
      const { owner, mergeTgt, otherAccount, tgt, vult } = await loadFixture(deployFixture);
      await mergeTgt.setLockedStatus(1);

      let acc = new Array(owner.address);
      let amount = new Array(initialSupply.toString());
      await tgt.mint(acc, amount);
      await tgt.mintFinish();

      const vultAmount = 1_250_000n * ethers.parseEther("1");
      const TgtDeposit = 6_570_000n * ethers.parseEther("1");

      await vult.approve(mergeTgt, vultAmount);
      await mergeTgt.deposit(vult, vultAmount);

      await tgt.transfer(otherAccount, TgtDeposit);
      await vult.setMerge(mergeTgt);

      console.log("otherAccount address:", otherAccount.address);
      console.log("MergeTgt address:", await mergeTgt.getAddress());
      console.log("VULT balance of MergeTGT before transfer:", (await vult.balanceOf(mergeTgt)).toString()); //1_250_000 x 1e18

      await tgt.connect(otherAccount).approve(otherAccount, TgtDeposit);
      
      // Perform the transfer
      await expect(tgt.connect(otherAccount).transferAndCall(mergeTgt, TgtDeposit, "0x"))
        .to.not.be.reverted;
      // Assertions
      expect(await tgt.balanceOf(mergeTgt)).to.equal(TgtDeposit);
      expect(await mergeTgt.vultBalance()).to.equal("1125000000000000000000000"); //1_125_000 x 1e18
      expect(await vult.balanceOf(otherAccount)).to.equal("125000000000000000000000");//125_000 x 1e18

    });

    it("Should correctly transfer Tgt after 4 months", async function () {
      const { owner, mergeTgt, otherAccount, tgt, vult } = await loadFixture(deployFixture);
      await mergeTgt.setLockedStatus(1);

      let acc = new Array(owner.address);
      let amount = new Array(initialSupply.toString());
      await tgt.mint(acc, amount);
      await tgt.mintFinish();

      const vultAmount = 1_250_000n * ethers.parseEther("1");
      const TgtDeposit = 6_570_000n * ethers.parseEther("1");

      await vult.approve(mergeTgt, vultAmount);
      await mergeTgt.deposit(vult, vultAmount);

      await tgt.transfer(otherAccount, TgtDeposit);
      await vult.setMerge(mergeTgt);

      // Advance time by 4 months (approximately 120 days)
      await ethers.provider.send("evm_increaseTime", [120 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");

      console.log("otherAccount address:", otherAccount.address);
      console.log("MergeTgt address:", await mergeTgt.getAddress());
      console.log("VULT balance of MergeTGT before transfer:", (await vult.balanceOf(mergeTgt)).toString());

      await tgt.connect(otherAccount).approve(otherAccount, TgtDeposit);
      
      // Perform the transfer
      await expect(tgt.connect(otherAccount).transferAndCall(mergeTgt, TgtDeposit, "0x"))
        .to.not.be.reverted;

      // Assertions
      expect(await tgt.balanceOf(mergeTgt)).to.equal(TgtDeposit);
      expect(await vult.balanceOf(mergeTgt)).to.equal("1138888937114197530864198"); //1_138_888_937_114_197_530_864_198
      expect(await vult.balanceOf(otherAccount)).to.equal("111111062885802469135802");
    });
  });


  describe("Deposit Function", function () {
    it("Should revert if token is not Tgt or VULT, not called from non-owner", async function () {
      const { mergeTgt, mockVult, vult, otherAccount } = await loadFixture(deployFixture);

      await expect(mergeTgt.deposit(mockVult, 100)).to.be.revertedWithCustomError(mergeTgt, "InvalidTokenReceived");
      await expect(mergeTgt.connect(otherAccount).deposit(vult, 100)).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );
    });

    it("Should correctly deposit VULT", async function () {
      const { owner, mergeTgt, vult, tgt } = await loadFixture(deployFixture);

      const virtualBalance = 100_000n * ethers.parseEther("1");

      // For owner-deposit function, let's keep approve and call separately because, the approve received hook only handles user interactions not for owner deposits
      
      await vult.approve(mergeTgt, virtualBalance);
      await mergeTgt.deposit(vult, virtualBalance);
      expect(await mergeTgt.vultBalance()).to.equal(virtualBalance);
    });
  });

  describe("Setters", function () {
    it("Should correctly set LockedStatus", async function () {
      const { mergeTgt, otherAccount } = await loadFixture(deployFixture);
      await mergeTgt.setLockedStatus(2); // TwoWay
      expect(await mergeTgt.lockedStatus()).to.equal(2);

      // Called from non-owner failed
      await expect(mergeTgt.connect(otherAccount).setLockedStatus(1)).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );
    });
  });
});
