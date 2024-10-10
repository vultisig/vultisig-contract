const {expect} = require("chai");
//const {network, upgrades} = require("hardhat");
import hre, { ethers, upgrades } from "hardhat";

const someAmount = ethers.parseEther("1.0");

const {loadFixture} = require("@nomicfoundation/hardhat-network-helpers");

//const hre = require("hardhat");
const {utils} = require("ethers");
import { parseEther, formatEther, formatUnits } from "ethers";

describe("TokenIOU Staking", function () {

    async function deployFixture() {
        const TokenIOUStaking = await ethers.getContractFactory("TokenIOUStaking");
        const TokenIOUStakingBasic = await ethers.getContractFactory("TokenIOUStakingBasic");
        const TokenIOUFactory = await ethers.getContractFactory("TokenIOU"); //replaced mock tgt with mocked iou
        const StableJoeStaking = await ethers.getContractFactory("StableJoeStaking");
        const USDC = await ethers.getContractFactory("USDC");
        const signers = await ethers.getSigners();
        const dev = signers[0];
        const alice = signers[1];
        const bob = signers[2];
        const carol = signers[3];
        const tokenIOUMaker = signers[4];
        const joe = signers[5];
        const treasury = signers[6];
        const rewardToken = await USDC.deploy();
        const tokenIOU = await TokenIOUFactory.deploy("", "");
        //console.log("ethers:", ethers);

        const accounts = [alice.address, bob.address, carol.address, dev.address, tokenIOUMaker.address, joe.address];
        const amounts = [parseEther("1000"),
            parseEther("1000"),
            parseEther("1000"),
            parseEther("0"),
            parseEther("1500000"),
            parseEther("10000")];
        /*for (let i = 0; i < accounts.length; i++) {
            await tokenIOU.mint(accounts[i], amounts[i]);
            console.log(`Minted ${ethers.formatEther(amounts[i])} tokens to ${accounts[i]}`);
        }*/
        //await tokenIOU.mint(accounts, amounts);
        //await tokenIOU.mint(parseEther("1000"));
        for (let i = 0; i < accounts.length; i++) {
            await tokenIOU.transfer(accounts[i], amounts[i]);
            console.log(`Transferred ${ethers.formatEther(amounts[i])} tokens to ${accounts[i]}`);
        }

        await rewardToken.mint(
            tokenIOUMaker.address,
            parseEther("1000000")
        ); // 1_000_000 tokens

        const tokenIOUStaking = await TokenIOUStaking.deploy(
            rewardToken.getAddress(),
            tokenIOU.getAddress()
        );
        console.log("tokenIOUStaking deployed");

        const tokenIOUStakingBasic = await upgrades.deployProxy(TokenIOUStakingBasic,
            [await tokenIOU.getAddress(), await rewardToken.getAddress(), treasury.address, 0]
        );

        console.log("tokenIOUStakingBasic deployed");

        const joeStaking = await upgrades.deployProxy(StableJoeStaking, [await rewardToken.getAddress(), await joe.getAddress(), 0],
            {
                unsafeAllow: ["constructor", "state-variable-immutable"],
                constructorArgs: [await tokenIOU.getAddress()],
            });

        console.log("USDC decimals is: " + (await rewardToken.decimals()).toString());

        await tokenIOU.connect(alice).approve(tokenIOUStaking.getAddress(), parseEther("360000"));
        await tokenIOU.connect(bob).approve(tokenIOUStaking.getAddress(), parseEther("360000"));
        await tokenIOU.connect(carol).approve(tokenIOUStaking.getAddress(), parseEther("100000"));
        await tokenIOU.connect(joe).approve(tokenIOUStaking.getAddress(), parseEther("100000"));

        await tokenIOU.connect(alice).approve(tokenIOUStakingBasic.getAddress(), parseEther("360000"));
        await tokenIOU.connect(bob).approve(tokenIOUStakingBasic.getAddress(), parseEther("360000"));
        await tokenIOU.connect(carol).approve(tokenIOUStakingBasic.getAddress(), parseEther("100000"));
        await tokenIOU.connect(joe).approve(tokenIOUStakingBasic.getAddress(), parseEther("100000"));

        await tokenIOU.connect(alice).approve(joeStaking.getAddress(), parseEther("100000"));
        await tokenIOU.connect(bob).approve(joeStaking.getAddress(), parseEther("100000"));
        await tokenIOU.connect(carol).approve(joeStaking.getAddress(), parseEther("100000"));
        await tokenIOU.connect(joe).approve(joeStaking.getAddress(), parseEther("100000"));

        await tokenIOU.setLocked(false);

        return {
            tokenIOUStaking,
            tokenIOU,
            rewardToken,
            dev,
            alice,
            bob,
            carol,
            tokenIOUMaker,
            USDC,
            joe,
            joeStaking,
            tokenIOUStakingBasic
        };
    }

    describe("should allow deposits and withdraws", function () {

        it("should allow deposits and withdraws of multiple users", async function () {
            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                dev,
                alice,
                bob,
                carol
            } = await loadFixture(deployFixture);

            await tokenIOUStaking.connect(alice).deposit(parseEther("100"));

            expect(await tokenIOU.balanceOf(alice.address)).to.be.equal(parseEther("900"));
            console.log("PRINT1");
            expect(
                await tokenIOU.balanceOf(await tokenIOUStaking.getAddress())
            ).to.be.equal(parseEther("100"));
            // 100 * 0.97 = 97
            expect((await tokenIOUStaking.getUserInfo(
                alice.address,
                await tokenIOU.getAddress()))[0]
            ).to.be.equal(parseEther("100"));
            await tokenIOUStaking.connect(bob).deposit(parseEther("200"));
            expect(await tokenIOU.balanceOf(bob.address)).to.be.equal(
                parseEther("800")
                // 97 + 200 * 0.97 = 291
            );
            expect(await tokenIOU.balanceOf(await tokenIOUStaking.getAddress())).to.be.equal(parseEther("300"));
            expect((await tokenIOUStaking.getUserInfo(await bob.getAddress(), await tokenIOU.getAddress()))[0]).to.be.equal(parseEther("200"));

            await tokenIOUStaking
                .connect(carol)
                .deposit(parseEther("300"));
            expect(await tokenIOU.balanceOf(carol.address)).to.be.equal(
                parseEther("700")
            );
            // 291 + 300 * 0.97
            expect(await tokenIOU.balanceOf(await tokenIOUStaking.getAddress())
            ).to.be.equal(parseEther("600"));
            expect((await tokenIOUStaking.getUserInfo(carol.address, await tokenIOU.getAddress()))[0]
            ).to.be.equal(parseEther("300"));
            await tokenIOUStaking.connect(alice).withdraw(parseEther("100"));
            expect(await tokenIOU.balanceOf(alice.address)).to.be.equal(
                parseEther("1000")
            );
            expect(await tokenIOU.balanceOf(await tokenIOUStaking.getAddress())).to.be.equal(parseEther("500"));
            expect((await tokenIOUStaking.getUserInfo(alice.address,await tokenIOU.getAddress()))[0]).to.be.equal(0);


            await tokenIOUStaking.connect(carol).withdraw(parseEther("100"));
            expect(await tokenIOU.balanceOf(carol.address)).to.be.equal(parseEther("800"));
            expect(await tokenIOU.balanceOf(await tokenIOUStaking.getAddress())).to.be.equal(parseEther("400"));
            expect((await tokenIOUStaking.getUserInfo(carol.address, await tokenIOU.getAddress()))[0]).to.be.equal(parseEther("200"));
            await tokenIOUStaking.connect(bob).withdraw("1");

            expect(await tokenIOU.balanceOf(bob.address)).to.be.closeTo(
                parseEther("800"), parseEther("0.0001")
            );
            expect(await tokenIOU.balanceOf(await tokenIOUStaking.getAddress())).to.be.closeTo(
                parseEther("400"), parseEther("0.0001")
            );
            expect((await tokenIOUStaking.getUserInfo(bob.address, await tokenIOU.getAddress()))[0]).to.be.closeTo(
                parseEther("200"), parseEther("0.0001")
            );

        });

        it("should update variables accordingly", async function () {
            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                tokenIOUMaker
            } = await loadFixture(deployFixture);

            await tokenIOUStaking.connect(alice).deposit("1");

            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("1"));

            expect(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).to.be.equal(parseEther("1"));
            expect(await tokenIOUStaking.lastRewardBalance(await rewardToken.getAddress())).to.be.equal("0");

            console.log("1");


            //increase to 7 days, as staking multiplier is 1x then.
            await increase(86400 * 7);

            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())).to.be.closeTo(
                parseEther("0.5"),
                parseEther("0.0001")
            );


            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("1"));

            expect(
                await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())
            ).to.be.closeTo(parseEther("1"), parseEther("0.0001"));

        });

        it("should return rewards with staking multiplier accordingly", async function () {
            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                tokenIOUMaker
            } = await loadFixture(deployFixture);

            await tokenIOUStaking.connect(alice).deposit("1");

            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("1"));

            expect(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).to.be.equal(parseEther("1"));
            expect(await tokenIOUStaking.lastRewardBalance(await rewardToken.getAddress())).to.be.equal("0");

            //increase to 7 days, as staking multiplier is 1x then.
            await increase(86400 * 7);
            console.log("Staking multiplier is now: " + (await tokenIOUStaking.getStakingMultiplier(alice.address)).toString());
            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())).to.be.closeTo(parseEther("0.5"), parseEther("0.0001"));

            // Making sure that `pendingReward` still return the accurate tokens even after updating pools
            expect(
                await tokenIOUStaking.pendingReward(
                    alice.address,
                    await rewardToken.getAddress()
                )
            ).to.be.closeTo(parseEther("0.5"), parseEther("0.0001"));

            //increase to 6 months, as staking multiplier is 1.5x then.
            await increase((86400 * 30 * 6) - (86400 * 7));

            console.log("2");

            // console.log("Staking multiplier is now: " + (await tokenIOUStaking.getStakingMultiplier(alice.address)).toString());
            expect(await tokenIOUStaking.pendingReward(alice.address,await  rewardToken.getAddress())).to.be.closeTo(parseEther("0.75"), parseEther("0.0001"));

            //increase to 1 year, as staking multiplier is 2x then.
            await increase(86400 * 185);

            console.log("2");

            // console.log("Staking multiplier is now: " + (await tokenIOUStaking.getStakingMultiplier(alice.address)).toString());
            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())).to.be.closeTo(parseEther("1"), parseEther("0.0001"));

            // Making sure that `pendingReward` still return the accurate tokens even after updating pools
            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())
            ).to.be.closeTo(parseEther("1"), parseEther("0.0001"));

        });

        it("should allow deposits and withdraws of multiple users and distribute rewards accordingly", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                carol,
                tokenIOUMaker,
            } = await loadFixture(deployFixture);

            console.log("3");

            await tokenIOUStaking.connect(alice).deposit(parseEther("100"));
            await tokenIOUStaking.connect(bob).deposit(parseEther("200"));
            await tokenIOUStaking.connect(carol).deposit(parseEther("300"));
            // console.log("Staking multiplier is now: " + (await tokenIOUStaking.getStakingMultiplier(alice.address)).toString());
            await increase(86400 * 7);
            // console.log("Staking multiplier is now: " + (await tokenIOUStaking.getStakingMultiplier(alice.address)).toString());

            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("6"));
            // console.log("Reward pool balance: " + (await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).toString());
            console.log("Alice reward balance before claiming: " + (await rewardToken.balanceOf(alice.address)).toString());
            await tokenIOUStaking.connect(alice).withdraw(parseEther("97"));
            // console.log("Alice reward after: " + (await rewardToken.balanceOf(alice.address)).toString());

            // accRewardBalance = rewardBalance * PRECISION / totalStaked
            //                  = 6e18 * 1e24 / 582e18
            //                  = 0.010309278350515463917525e24
            // reward = accRewardBalance * aliceShare / PRECISION
            //        = accRewardBalance * 97e18 / 1e24
            //        = 0.999999999999999999e18*

            console.log("3");


            expect(await rewardToken.balanceOf(alice.address)).to.be.closeTo(
                parseEther("0.5"),
                parseEther("0.0001")
            );

            console.log("3");


            await tokenIOUStaking.connect(carol).withdraw(parseEther("100"));
            expect(await tokenIOU.balanceOf(carol.address)).to.be.equal(parseEther("800"));
            // reward = accRewardBalance * carolShare / PRECISION
            //        = accRewardBalance * 291e18 / 1e24
            //        = 2.999999999999999999e18

            console.log("3");

            expect(
                await rewardToken.balanceOf(carol.address)
            ).to.be.closeTo(
                parseEther("1.5"),
                parseEther("0.001")
            );

            console.log("3");


            await tokenIOUStaking.connect(bob).withdraw("0");
            // reward = accRewardBalance * carolShare / PRECISION
            //        = accRewardBalance * 194e18 / 1e24
            //        = 1.999999999999999999e18
            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("1"),
                parseEther("0.001")
            );
        });

        it("should distribute token accordingly even if update isn't called every day", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                tokenIOUMaker,
            } = await loadFixture(deployFixture);

            await tokenIOUStaking.connect(alice).deposit(1);
            expect(await rewardToken.balanceOf(alice.address)).to.be.equal(0);

            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("1"));
            await increase(7 * 86400);
            await tokenIOUStaking.connect(alice).withdraw(0);
            expect(await rewardToken.balanceOf(alice.address)).to.be.closeTo(parseEther("0.5"), parseEther("0.0001"));

            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("1"));
            await tokenIOUStaking.connect(alice).withdraw(0);
            expect(await rewardToken.balanceOf(alice.address)).to.be.closeTo(parseEther("1"), parseEther("0.0001"));
        });

        it("should allow deposits and withdraws of multiple users and distribute rewards accordingly even if someone enters or leaves", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                carol,
                tokenIOUMaker,
            } = await loadFixture(deployFixture);

            await tokenIOUStaking.connect(alice).deposit(parseEther("100"));
            await tokenIOUStaking.connect(carol).deposit(parseEther("100"));

            console.log("4");

            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));

            await increase(86400 * 7);

            console.log("4");

            await tokenIOUStaking.connect(bob).deposit(parseEther("1000")); // Bob enters

            console.log("Reward pool balance: " + (await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).toString());
            console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Pending reward for Alice: " + formatEther((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))));
            console.log("--------------------------------------");
            console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending reward for Bob: " + formatEther(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");
            console.log("Staking multiplier for Carol: " + formatEther(await tokenIOUStaking.getStakingMultiplier(carol.address)));
            console.log("Pending reward for Carol: " + formatEther(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress())));

            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())).to.be.closeTo(
                parseEther("25"),
                parseEther("0.001")
            );

            console.log("4");

            await tokenIOUStaking.connect(carol).withdraw(parseEther("100"));

            expect(await rewardToken.balanceOf(carol.address)).to.be.closeTo(
                parseEther("25"),
                parseEther("0.0001")
            );

            console.log("4");

            console.log("Reward pool balance: " + formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).toString());
            console.log("Pending reward for Alice: " + formatEther(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())));

            // Alice enters again to try to get more rewards
            await tokenIOUStaking.connect(alice).deposit(parseEther("100"));

            console.log("Pending reward for Alice: " + formatEther(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())));
            console.log("Reward pool balance: " + formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).toString());

            await tokenIOUStaking.connect(alice).withdraw(parseEther("200"));
            // She gets the same reward as Carol
            const lastAliceBalance = await rewardToken.balanceOf(alice.address);

            console.log("4");

            expect(lastAliceBalance).to.be.closeTo(
                parseEther("25"),
                parseEther("0.001")
            );
            await increase(86400 * 7);

            console.log("Reward pool balance: " + formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).toString());
            console.log("Pending reward for Bob: " + formatEther(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^-");
            // Reward pool should have enough tokens to pay Bob
            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.lte(await rewardToken.balanceOf(await tokenIOUStaking.getAddress()));

            console.log("Staking deposit for Alice: " + (await tokenIOUStaking.getUserInfo(alice.address, await rewardToken.getAddress()))[0]);
            console.log("Staking deposit for Carol: " + (await tokenIOUStaking.getUserInfo(carol.address, await rewardToken.getAddress()))[0]);
            console.log("Staking deposit for Bob: " + (await tokenIOUStaking.getUserInfo(bob.address, await rewardToken.getAddress()))[0]);

            console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Staking multiplier for Carol: " + formatEther(await tokenIOUStaking.getStakingMultiplier(carol.address)));

            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));

            console.log("Pending reward for Bob: " + formatEther(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("Reward pool balance: " + formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).toString());

            await tokenIOUStaking.connect(bob).withdraw("0");

            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("50"),
                parseEther("0.001")
            );

            // Alice shouldn't receive any token of the last reward
            await tokenIOUStaking.connect(alice).withdraw("0");
            // reward = accRewardBalance * aliceShare / PRECISION - aliceRewardDebt
            //        = accRewardBalance * 0 / PRECISION - 0
            //        = 0      (she withdrew everything, so her share is 0)
            expect(await rewardToken.balanceOf(alice.address)).to.be.equal(lastAliceBalance);

            console.log("--------------------------------------");
            console.log("Reward pool balance at the end: " + formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).toString());
            console.log("--------------------------------------");
            console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Staking deposit for Alice: " + (await tokenIOUStaking.getUserInfo(alice.address, await rewardToken.getAddress()))[0]);
            console.log("Reward balance for Alice at the end: " + formatEther(await rewardToken.balanceOf(alice.address)).toString());
            console.log("Pending reward for Alice: " + formatEther(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");
            console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Staking deposit for Bob: " + (await tokenIOUStaking.getUserInfo(bob.address, await rewardToken.getAddress()))[0]);
            console.log("Reward balance for Bob at the end: " + formatEther(await rewardToken.balanceOf(bob.address)).toString());
            console.log("Pending reward for Bob: " + formatEther(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");
            console.log("Staking multiplier for Carol: " + formatEther(await tokenIOUStaking.getStakingMultiplier(carol.address)));
            console.log("Staking deposit for Carol: " + (await tokenIOUStaking.getUserInfo(carol.address, await rewardToken.getAddress()))[0]);
            console.log("Reward balance for Carol at the end: " + formatEther(await rewardToken.balanceOf(carol.address)).toString());
            console.log("Pending reward for Carol: " + formatEther(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress())));

            increase(86400 * 365);
            console.log("*** 1 year passed ***");
            console.log("Pending reward for Bob: " + formatEther(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("Reward pool balance before last withdraw: " + formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).toString());

            // Reward pool should have enough tokens to pay Bob but there should still be a reward to pay to Bob
            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.lte(await rewardToken.balanceOf(await tokenIOUStaking.getAddress()));

            await tokenIOUStaking.connect(bob).withdraw(0);

            console.log("Pending reward for Bob: " + formatEther(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("Reward pool balance at the end: " + formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).toString());
            console.log("Reward balance for Bob at the end: " + formatEther(await rewardToken.balanceOf(bob.address)).toString());

            //FIXME TODO there are funds to be redistributed in this case
            expect(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).to.be.eq(parseEther("50"));
            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("100"),
                parseEther("0.001")
            );

        });

        it("pending tokens function should return the same number of token that user actually receive", async function () {
            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
            } = await loadFixture(deployFixture);

            await tokenIOUStaking.connect(alice).deposit(parseEther("300"));

            expect(await tokenIOU.balanceOf(alice.address)).to.be.equal(parseEther("700"));
            expect(await tokenIOU.balanceOf(await tokenIOUStaking.getAddress())).to.be.equal(parseEther("300"));

            await rewardToken.mint(await tokenIOUStaking.getAddress(), parseEther("100")); // We send 100 Tokens to sJoe's address

            await increase(86400 * 7);

            const pendingReward = await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress());
            // console.log("pendingReward", pendingReward.toString());
            // console.log("rewardToken.balanceOf(alice.address)", (await rewardToken.balanceOf(alice.address)).toString());
            await tokenIOUStaking.connect(alice).withdraw(0); // Alice shouldn't receive any token of the last reward
            // console.log("rewardToken.balanceOf(alice.address)", (await rewardToken.balanceOf(alice.address)).toString());
            expect(await tokenIOU.balanceOf(alice.address)).to.be.equal(parseEther("700"));
            expect(await rewardToken.balanceOf(alice.address)).to.be.equal(pendingReward);
            expect(await tokenIOU.balanceOf(await tokenIOUStaking.getAddress())).to.be.equal(parseEther("300"));
        });

        it("should allow rewards in tokenIOU and USDC", async function () {
            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                carol,
            } = await loadFixture(
                deployFixture,
            );

            await tokenIOUStaking.connect(alice).deposit(parseEther("1000"));
            console.log("7");

            await tokenIOUStaking.connect(bob).deposit(parseEther("1000"));
            console.log("7");

            await tokenIOUStaking.connect(carol).deposit(parseEther("1000"));
            console.log("7");

            increase(86400 * 7);
            console.log("7");
            await rewardToken.mint(await tokenIOUStaking.getAddress(), parseEther("3"));
            console.log("7");

            await tokenIOUStaking.connect(alice).withdraw(0);
            // accRewardBalance = rewardBalance * PRECISION / totalStaked
            //                  = 3e18 * 1e24 / 291e18
            //                  = 0.001030927835051546391752e24
            // reward = accRewardBalance * aliceShare / PRECISION
            //        = accRewardBalance * 970e18 / 1e24
            //        = 0.999999999999999999e18
            // aliceRewardDebt = 0.999999999999999999e18
            const aliceRewardBalance = await rewardToken.balanceOf(alice.address);
            expect(aliceRewardBalance).to.be.closeTo(
                parseEther("0.5"),
                parseEther("0.0001")
            );
            // accJoeBalance = 0
            // reward = 0
            expect(await tokenIOU.balanceOf(alice.address)).to.be.equal(0);
            console.log("7");

            await tokenIOUStaking.addRewardToken(await tokenIOU.getAddress());
            await tokenIOU.transfer(await tokenIOUStaking.getAddress(), parseEther("6"));
            //await tokenIOU.mint([await tokenIOUStaking.getAddress()], [parseEther("6")]);

            await tokenIOUStaking.connect(bob).withdraw(0);
            // reward = accRewardBalance * bobShare / PRECISION
            //        = accRewardBalance * 970e18 / 1e24
            //        = 0.999999999999999999e18
            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("0.5"),
                parseEther("0.0001")
            );

            console.log("7");

            // accJoeBalance = tokenIOUBalance * PRECISION / totalStaked
            //                  = 6e18 * 1e24 / 291e18
            //                  = 0.002061855670103092783505e24
            // reward = accJoeBalance * aliceShare / PRECISION
            //        = accJoeBalance * 970e18 / 1e24
            //        = 1.999999999999999999e18
            expect(await tokenIOU.balanceOf(bob.address)).to.be.closeTo(
                parseEther("1"),
                parseEther("0.0001")
            );

            console.log("7");


            await tokenIOUStaking.connect(alice).withdraw(parseEther("0"));
            // reward = accRewardBalance * aliceShare / PRECISION - aliceRewardDebt
            //        = accRewardBalance * 970e18 / 1e24 - 0.999999999999999999e18
            //        = 0
            // so she has the same balance as previously
            expect(await rewardToken.balanceOf(alice.address)).to.be.equal(aliceRewardBalance);
            // reward = accJoeBalance * aliceShare / PRECISION
            //        = accJoeBalance * 970e18 / 1e24
            //        = 1.999999999999999999e18
            expect(await tokenIOU.balanceOf(alice.address)).to.be.closeTo(
                parseEther("1"),
                parseEther("0.0001")
            );
        });

        it("should linearly increase staking multiplier after 7 days", async function () {
            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                USDC
            } = await loadFixture(deployFixture,);
            let usdc = await USDC.deploy();
            /*console.log("Starting test");
            await tokenIOUStaking.addRewardToken(await usdc.getAddress());
            console.log("Added reward token");
            await usdc.mint(await tokenIOUStaking.getAddress(), parseEther("100"));
            console.log("Minted USDC to staking contract");
            expect(await tokenIOUStaking.pendingReward(await alice.getAddress(), await usdc.getAddress())).to.be.equal(parseEther("0"));
            console.log("Checked initial pending reward");
            await tokenIOUStaking.connect(alice).deposit(1);
            console.log("Alice deposited");
            increase(86400 * 7);
            console.log("Increased time by 7 days");
            expect(await tokenIOUStaking.pendingReward(await alice.getAddress(), await usdc.getAddress())).to.be.equal(parseEther("50"));
            console.log("Checked pending reward after 7 days");
            increase(86400 * 30);
            console.log("Increased time by 30 days");
            expect(await tokenIOUStaking.pendingReward(await alice.getAddress(), await usdc.getAddress())).to.be.equal(parseEther("54.335"));
            console.log("Checked pending reward after 37 days");
            increase(86400 * 60);
            console.log("Increased time by 60 days");
            expect(await tokenIOUStaking.pendingReward(await alice.getAddress(), await usdc.getAddress())).to.be.equal(parseEther("63.005"));
            console.log("Checked pending reward after 97 days");
            increase(86400 * 83);
            console.log("Increased time by 83 days");
            expect(await tokenIOUStaking.pendingReward(await alice.getAddress(), await usdc.getAddress())).to.be.equal(parseEther("75"));
            console.log("Checked pending reward after 180 days");
            increase(86400 * 90);
            console.log("Increased time by 90 days");
            expect(await tokenIOUStaking.pendingReward(await alice.getAddress(), await usdc.getAddress())).to.be.equal(parseEther("87.16"));
            console.log("Checked pending reward after 270 days");
            increase(86400 * 95);
            console.log("Increased time by 95 days");
            expect(await tokenIOUStaking.pendingReward(await alice.getAddress(), await usdc.getAddress())).to.be.equal(parseEther("100"));
            console.log("Checked final pending reward after 365 days");*/

            await tokenIOUStaking.addRewardToken(await usdc.getAddress());
            await usdc.mint(await tokenIOUStaking.getAddress(), parseEther("100"));
            expect(await tokenIOUStaking.pendingReward(await alice.getAddress(), await usdc.getAddress())).to.be.equal(parseEther("0"));
            await tokenIOUStaking.connect(alice).deposit(1);
            increase(86400 * 7);
            expect(await tokenIOUStaking.pendingReward(await alice.getAddress(), await usdc.getAddress())).to.be.equal(parseEther("50"));
            increase(86400 * 30);
            expect(await tokenIOUStaking.pendingReward(await alice.getAddress(), await usdc.getAddress())).to.be.equal(parseEther("54.335"));
            increase(86400 * 60);
            expect(await tokenIOUStaking.pendingReward(await alice.getAddress(), await usdc.getAddress())).to.be.equal(parseEther("63.005"));
            increase(86400 * 83);
            expect(await tokenIOUStaking.pendingReward(await alice.getAddress(), await usdc.getAddress())).to.be.equal(parseEther("75"));
            increase(86400 * 90);
            expect(await tokenIOUStaking.pendingReward(await alice.getAddress(), await usdc.getAddress())).to.be.equal(parseEther("87.16"));
            increase(86400 * 95);
            expect(await tokenIOUStaking.pendingReward(await alice.getAddress(), await usdc.getAddress())).to.be.equal(parseEther("100"));
        });

        it("rewardDebt should be updated as expected, alice deposits before last reward is sent", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                USDC
            } = await loadFixture(deployFixture);

            let usdc = await USDC.deploy();
            await tokenIOUStaking.addRewardToken(await usdc.getAddress());
            await tokenIOUStaking.connect(alice).deposit(1);
            await tokenIOUStaking.connect(bob).deposit(1);
            increase(86400 * 365);

            await usdc.mint(await tokenIOUStaking.getAddress(), parseEther("100"));

            await tokenIOUStaking.connect(alice).withdraw(1);

            let balAlice = await usdc.balanceOf(await alice.getAddress());
            let balBob = await usdc.balanceOf(await bob.getAddress());
            expect(balAlice).to.be.closeTo(parseEther("50"), parseEther("0.0001"));
            expect(balBob).to.be.equal(0);

            await usdc.mint(await tokenIOUStaking.getAddress(), parseEther("100"));
            console.log("USDC Staking balance: ", formatEther(await usdc.balanceOf(await tokenIOUStaking.getAddress())));
            const pendingRewardBob = await tokenIOUStaking.pendingReward(await bob.getAddress(), await usdc.getAddress())
            console.log("Pending reward for Bob: " + formatEther(pendingRewardBob));

            await tokenIOUStaking.connect(bob).withdraw(0);
            balBob = await usdc.balanceOf(await bob.getAddress());
            expect(balBob).to.be.closeTo(pendingRewardBob, parseEther("0.0001"));

            await tokenIOUStaking.connect(alice).deposit(1);
            increase(86400 * 7);

            balBob = await usdc.balanceOf(await bob.getAddress());
            expect(await usdc.balanceOf(await alice.getAddress())).to.be.equal(balAlice);
            expect(balBob).to.be.closeTo(parseEther("150"), parseEther("0.0001"));

            await usdc.mint(await tokenIOUStaking.getAddress(), parseEther("100"));

            console.log('step 3 ------------------------------------------------------------------');

            console.log("USDC Alice balance: ", formatEther(await usdc.balanceOf(alice.address)));
            console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            let userInfo = await tokenIOUStaking.getUserInfo(alice.address, await rewardToken.getAddress());
            console.log("Staking deposit for Alice: " + userInfo[0]);
            console.log("Pending reward for Alice: " + formatEther(await tokenIOUStaking.pendingReward(alice.address, await usdc.getAddress())));
            console.log("--------------------------------------");
            console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending reward for Bob: " + formatEther(await tokenIOUStaking.pendingReward(bob.address, await usdc.getAddress())));
            console.log("USDC Bob balance: ", formatEther(await usdc.balanceOf(bob.address)));
            userInfo = await tokenIOUStaking.getUserInfo(bob.address, await rewardToken.getAddress());
            console.log("Staking deposit for Bob: " + userInfo[0]);

            console.log("USDC Staking balance: ", formatEther(await usdc.balanceOf(await tokenIOUStaking.getAddress())));

            await tokenIOUStaking.connect(bob).withdraw(0);
            await tokenIOUStaking.connect(alice).withdraw(0);

            balAlice = await usdc.balanceOf(alice.address);
            balBob = await usdc.balanceOf(bob.address);

            expect(balAlice).to.be.closeTo(parseEther("75"), parseEther("0.0001"));
            expect(balBob).to.be.closeTo(parseEther("200"), parseEther("0.0001"));

            await tokenIOUStaking.removeRewardToken(await usdc.getAddress());
        });

        it("rewardDebt should be updated as expected, alice deposits after last reward is sent", async function () {
            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                USDC
            } = await loadFixture(deployFixture);

            let usdc = await USDC.deploy();
            await tokenIOUStaking.addRewardToken(await usdc.getAddress());

            await tokenIOUStaking.connect(alice).deposit(1);
            await tokenIOUStaking.connect(bob).deposit(1);
            increase(86400 * 7);

            await usdc.mint(await tokenIOUStaking.getAddress(), parseEther("1"));

            await tokenIOUStaking.connect(alice).withdraw(1);

            let balAlice = await usdc.balanceOf(await alice.getAddress());
            let balBob = await usdc.balanceOf(await bob.getAddress());
            expect(balAlice).to.be.equal(parseEther("0.25"));
            expect(balBob).to.be.equal(0);

            await usdc.mint(tokenIOUStaking.getAddress(), parseEther("1"));
            await tokenIOUStaking.connect(bob).withdraw(0);

            balBob = await usdc.balanceOf(await bob.getAddress());
            expect(await usdc.balanceOf(await alice.getAddress())).to.be.equal(balAlice);
            expect(balBob).to.be.closeTo(parseEther("0.75"), parseEther("0.0001"));

            await usdc.mint(await tokenIOUStaking.getAddress(), parseEther("1"));

            await tokenIOUStaking.connect(alice).deposit(1);
            await tokenIOUStaking.connect(bob).withdraw(0);
            await tokenIOUStaking.connect(alice).withdraw(0);

            balAlice = await usdc.balanceOf(await alice.getAddress());
            balBob = await usdc.balanceOf(await bob.getAddress());
            expect(balAlice).to.be.equal(parseEther("0.25"));
            expect(balBob).to.be.equal(parseEther("1.25"));
        });

        it("should allow adding and removing a rewardToken, only by owner", async function () {
            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                dev,
                alice,
                USDC
            } = await loadFixture(deployFixture);

            let token1 = await USDC.deploy();
            await expect(
                tokenIOUStaking.connect(alice).addRewardToken(await token1.getAddress())
            ).to.be.revertedWith("Ownable: caller is not the owner");
            expect(
                await tokenIOUStaking.isRewardToken(await token1.getAddress())
            ).to.be.equal(false);
            expect(await tokenIOUStaking.rewardTokensLength()).to.be.equal(1);

            await tokenIOUStaking
                .connect(dev)
                .addRewardToken(await token1.getAddress());
            await expect(
                tokenIOUStaking.connect(dev).addRewardToken(await token1.getAddress())
            ).to.be.revertedWith("tokenIOUStaking: token can't be added");
            expect(
                await tokenIOUStaking.isRewardToken(await token1.getAddress())
            ).to.be.equal(true);
            expect(await tokenIOUStaking.rewardTokensLength()).to.be.equal(2);

            await tokenIOUStaking
                .connect(dev)
                .removeRewardToken(await token1.getAddress());
            expect(
                await tokenIOUStaking.isRewardToken(await token1.getAddress())
            ).to.be.equal(false);
            expect(await tokenIOUStaking.rewardTokensLength()).to.be.equal(1);
        });

        it("should allow emergency withdraw", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
            } = await loadFixture(
                deployFixture,
            );

            await tokenIOUStaking.connect(alice).deposit(parseEther("300"));
            expect(await tokenIOU.balanceOf(alice.address)).to.be.equal(parseEther("700"));
            expect(await tokenIOU.balanceOf(await tokenIOUStaking.getAddress())).to.be.equal(parseEther("300"));

            await rewardToken.mint(await tokenIOUStaking.getAddress(), parseEther("100")); // We send 100 Tokens to sJoe's address

            await tokenIOUStaking.connect(alice).emergencyWithdraw(); // Alice shouldn't receive any token of the last reward
            expect(await tokenIOU.balanceOf(alice.address)).to.be.equal(
                parseEther("1000")
            );
            expect(await rewardToken.balanceOf(alice.address)).to.be.equal(0);
            expect(await tokenIOU.balanceOf(await tokenIOUStaking.getAddress())).to.be.equal(0);
            const userInfo = await tokenIOUStaking.getUserInfo(alice.address, await rewardToken.getAddress());
            expect(userInfo[0]).to.be.equal(0);
            expect(userInfo[1]).to.be.equal(0);
        });

        it("should properly calculate and distribute rewards for multiple users in different time periods ", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                dev,
                bob,
                carol,
                tokenIOUMaker
            } = await loadFixture(
                deployFixture,
            );

            await tokenIOUStaking.connect(alice).deposit(parseEther("100"));
            await tokenIOUStaking.connect(carol).deposit(parseEther("100"));

            await increase(86400 * 365);
            await tokenIOUStaking.connect(bob).deposit(parseEther("100")); // Bob enters
            await increase(86400 * 7);
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));

            // alice = 100 1 year = 2x
            // bob= 100 7 days = 1x
            // carol = 100 7 days = 1x
            // share = totalRewardBalance 100 / 4x = 25
            // alice = 2 x share = 50

            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));
            console.log("accRewardPerShare: ", formatEther(await tokenIOUStaking.accRewardPerShare(await rewardToken.getAddress())));

            // console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Pending reward for Alice: " + formatEther((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))));
            console.log("--------------------------------------");
            // console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending reward for Bob: " + formatEther(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");
            // console.log("Staking multiplier for Carol: " + formatEther(await tokenIOUStaking.getStakingMultiplier(carol.address)));
            console.log("Pending reward for Carol: " + formatEther(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");

            await tokenIOUStaking.connect(alice).withdraw(parseEther("0"));
            expect(await rewardToken.balanceOf(alice.address)).to.be.closeTo(
                parseEther("33.3333"),
                parseEther("0.0001")
            );
            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));
            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("16.6666"),
                parseEther("0.0001")
            );
            await tokenIOUStaking.connect(carol).withdraw(parseEther("0"));
            expect(await rewardToken.balanceOf(carol.address)).to.be.closeTo(
                parseEther("33.3333"),
                parseEther("0.0001")
            )

            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())).to.be.equal(parseEther("0"));
            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.equal(parseEther("0"));
            expect(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress())).to.be.equal(parseEther("0"));

            await increase(86400 * 365);
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));


            // console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Pending reward for Alice: " + formatEther((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))));
            console.log("--------------------------------------");
            // console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending reward for Bob: " + formatEther(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");
            // console.log("Staking multiplier for Carol: " + formatEther(await tokenIOUStaking.getStakingMultiplier(carol.address)));
            console.log("Pending reward for Carol: " + formatEther(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");

            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));
            await tokenIOUStaking.connect(alice).withdraw(parseEther("0"));
            await tokenIOUStaking.connect(carol).withdraw(parseEther("0"));

            expect(await rewardToken.balanceOf(alice.address)).to.be.closeTo(
                parseEther("66.66"),
                parseEther("0.01")
            );
            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("66.66"),
                parseEther("0.01")
            );
            expect(await rewardToken.balanceOf(carol.address)).to.be.closeTo(
                parseEther("66.66"),
                parseEther("0.01")
            )
            console.log("Reward balance after all withdrawals: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));
            console.log("Reward balance Alice: ", formatEther(await rewardToken.balanceOf(alice.address)));
            console.log("Reward balance Bob: ", formatEther(await rewardToken.balanceOf(bob.address)));
            console.log("Reward balance Carol: ", formatEther(await rewardToken.balanceOf(carol.address)));

        });

        it.skip("should calculate rewards correctly when the number of depositors is >= 200", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                dev,
                bob,
                carol,
                tokenIOUMaker
            } = await loadFixture(deployFixture);

            for (let i = 0; i < 200; i++) {
                const signer = ethers.Wallet.createRandom().connect(ethers.provider);
                await dev.sendTransaction({to: signer.address, value: parseEther("0.1")});
                await tokenIOU.connect(dev).mint2(signer.address, parseEther("100"));
                await tokenIOU.connect(signer).approve(await tokenIOUStaking.getAddress(), parseEther("1000"));
                await tokenIOUStaking.connect(signer).deposit(parseEther("100"));
            }

            await tokenIOUStaking.connect(alice).deposit(parseEther("100"));
            await tokenIOUStaking.connect(carol).deposit(parseEther("100"));

            await increase(86400 * 365);
            await tokenIOUStaking.connect(bob).deposit(parseEther("100"));
            await increase(86400 * 10);
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));

            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));

            // console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Pending reward for Alice: " + formatEther((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))));
            console.log("--------------------------------------");
            // console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending reward for Bob: " + formatEther(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");
            // console.log("Staking multiplier for Carol: " + formatEther(await tokenIOUStaking.getStakingMultiplier(carol.address)));
            console.log("Pending reward for Carol: " + formatEther(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");

            await tokenIOUStaking.connect(alice).withdraw(parseEther("0"));
            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));
            await tokenIOUStaking.connect(carol).withdraw(parseEther("0"));

            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())).to.be.equal(parseEther("0"));
            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.equal(parseEther("0"));
            expect(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress())).to.be.equal(parseEther("0"));

        }).timeout(1000000);

        it("pending reward should be updated for all stakers when there is a new deposit of reward tokens", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                tokenIOUMaker
            } = await loadFixture(deployFixture);

            await tokenIOUStaking.connect(alice).deposit(parseEther("100"));
            await tokenIOUStaking.connect(bob).deposit(parseEther("100"));
            await increase(86400 * 365);
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));

            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));
            console.log("accRewardPerShare: ", formatEther(await tokenIOUStaking.accRewardPerShare(await rewardToken.getAddress())));

            // console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Pending reward for Alice: " + formatEther((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))));
            console.log("--------------------------------------");
            // console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending reward for Bob: " + formatEther(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");

            await tokenIOUStaking.connect(alice).withdraw(parseEther("50"));
            expect(await rewardToken.balanceOf(alice.address)).to.be.closeTo(
                parseEther("50"),
                parseEther("0.0001")
            );
            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));
            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("50"),
                parseEther("0.0001")
            );

            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())).to.be.equal(parseEther("0"));
            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.equal(parseEther("0"));

            increase(86400 * 365);

            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));

            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));
            // console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Pending reward for Alice: " + formatEther((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))));
            console.log("--------------------------------------");
            // console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending reward for Bob: " + formatEther(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");

            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())).to.be.equal(parseEther("33.333333333333333333"));
            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.equal(parseEther("66.666666666666666666"));

            await tokenIOUStaking.connect(alice).withdraw(parseEther("50"));
            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));

            expect(await rewardToken.balanceOf(alice.address)).to.be.closeTo(
                parseEther("83.333"),
                parseEther("0.001")
            );
            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("116.666"),
                parseEther("0.001")
            );

            console.log("Reward balance after all withdrawals: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));
            console.log("Reward balance Alice: ", formatEther(await rewardToken.balanceOf(alice.address)));
            console.log("Reward balance Bob: ", formatEther(await rewardToken.balanceOf(bob.address)));

        });

        it("extra rewards should be distributed to community plus stakers", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                tokenIOUMaker
            } = await loadFixture(deployFixture);

            await tokenIOUStaking.connect(alice).deposit(parseEther("100"));
            await tokenIOUStaking.connect(bob).deposit(parseEther("100"));
            await increase(86400 * 7);
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));

            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));

            console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Pending reward for Alice: " + formatEther((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))));
            console.log("--------------------------------------");
            console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending reward for Bob: " + formatEther(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");
            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.equal(parseEther("25"));

            await tokenIOUStaking.connect(alice).withdraw(parseEther("50")); // unclaimed rewards so far = 25
            expect(await tokenIOUStaking.forgoneRewardsPool(await rewardToken.getAddress())).to.be.equal(parseEther("25"));

            expect(await rewardToken.balanceOf(alice.address)).to.be.closeTo(
                parseEther("25"),
                parseEther("0.0001")
            );

            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));
            console.log("Total staked balance: ", formatEther(await tokenIOU.balanceOf(await tokenIOUStaking.getAddress())));

            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.equal(
                parseEther("25")
            );

            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));

            expect(await tokenIOUStaking.forgoneRewardsPool(await rewardToken.getAddress())).to.be.equal(parseEther("25"));

            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("25"),
                parseEther("0.001")
            );

            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())).to.be.equal(parseEther("0"));
            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.equal(parseEther("0"));

            increase(86400 * 7);

            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));

            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));
            console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Pending reward for Alice: " + formatEther((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))));
            console.log("--------------------------------------");
            console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending reward for Bob: " + formatEther(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");

            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())).to.be.equal(parseEther("16.666666666666666666"));
            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.equal(parseEther("34.511666666666666666"));

            await tokenIOUStaking.connect(alice).withdraw(parseEther("50"));
            expect(await tokenIOUStaking.forgoneRewardsPool(await rewardToken.getAddress())).to.be.closeTo(parseEther("41.666"), parseEther("0.001"));

            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));


            expect(await rewardToken.balanceOf(alice.address)).to.be.closeTo(
                parseEther("41.666"),
                parseEther("0.001")
            );
            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("59.5116"),
                parseEther("0.001")
            );

            increase(86400 * 365);
            console.log("-------------breakpoint-------------------------");

            await tokenIOUStaking.connect(alice).withdraw(parseEther("0"));
            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));

            console.log("Reward balance after all withdrawals: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));
            console.log("Reward balance Alice: ", formatEther(await rewardToken.balanceOf(alice.address)));
            console.log("Reward balance Bob: ", formatEther(await rewardToken.balanceOf(bob.address)));

            //these funds are to be redistributed to community plus stakers
            expect(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).to.be.closeTo(parseEther("41.6666"), parseEther("0.0001"));

            // Extra rewards claim redistribution

            await expect(tokenIOUStaking.connect(alice).withdrawAndClaimExtraRewards(0)).to.be.revertedWith("tokenIOUStaking: not eligible for extra rewards");
            let userInfo = await tokenIOUStaking.getUserInfo(alice.address, await rewardToken.getAddress());
            console.log("Staking deposit for Alice: " + formatEther(userInfo[0]));

            await tokenIOU.connect(tokenIOUMaker).transfer(alice.address, parseEther("350000"));
            await tokenIOUStaking.connect(alice).deposit(parseEther("350000"));
            increase(86400 * 365);
            userInfo = await tokenIOUStaking.getUserInfo(alice.address, await rewardToken.getAddress());
            console.log("Staking deposit for Alice: " + formatEther(userInfo[0]));
            console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Reward balance before Alice: ", formatEther(await rewardToken.balanceOf(alice.address)));

            await tokenIOUStaking.connect(alice).withdrawAndClaimExtraRewards(0);
            console.log("Reward balance after extra rewards Alice: ", formatEther(await rewardToken.balanceOf(alice.address)));

        });

        it("claimExtraRewards should not underflow", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                tokenIOUMaker
            } = await loadFixture(deployFixture);

            await tokenIOUStaking.connect(alice).deposit(parseEther("100"));
            await tokenIOUStaking.connect(bob).deposit(parseEther("100"));
            await increase(86400 * 7);
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));

            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.equal(parseEther("25"));

            await tokenIOUStaking.connect(alice).withdraw(parseEther("50")); // unclaimed rewards so far = 25
            expect(await tokenIOUStaking.forgoneRewardsPool(await rewardToken.getAddress())).to.be.equal(parseEther("25"));

            expect(await rewardToken.balanceOf(alice.address)).to.be.closeTo(
                parseEther("25"),
                parseEther("0.0001")
            );

            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.equal(
                parseEther("25")
            );

            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));

            expect(await tokenIOUStaking.forgoneRewardsPool(await rewardToken.getAddress())).to.be.equal(parseEther("25"));

            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("25"),
                parseEther("0.001")
            );

            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())).to.be.equal(parseEther("0"));
            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.equal(parseEther("0"));

            increase(86400 * 7);

            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));

            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())).to.be.equal(parseEther("16.666666666666666666"));
            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.equal(parseEther("34.511666666666666666"));

            await tokenIOUStaking.connect(alice).withdraw(parseEther("50"));
            expect(await tokenIOUStaking.forgoneRewardsPool(await rewardToken.getAddress())).to.be.equal(parseEther("41.666666666666666667"));

            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));

            expect(await rewardToken.balanceOf(alice.address)).to.be.closeTo(
                parseEther("41.666"),
                parseEther("0.001")
            );
            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("59.5116"),
                parseEther("0.001")
            );

            increase(86400 * 365);

            await tokenIOUStaking.connect(alice).withdraw(parseEther("0"));
            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));

            //these funds are to be redistributed to community plus stakers
            expect(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).to.be.closeTo(parseEther("41.6666"), parseEther("0.0001"));

            // Extra rewards claim redistribution
            await expect(tokenIOUStaking.connect(alice).withdrawAndClaimExtraRewards(0)).to.be.revertedWith("tokenIOUStaking: not eligible for extra rewards");
            expect(await tokenIOUStaking.connect(alice).pendingExtraRewards(alice.address, await rewardToken.getAddress())).to.be.equal(0);
            let userInfo = await tokenIOUStaking.getUserInfo(alice.address, await rewardToken.getAddress());
            console.log("Staking deposit for Alice: " + formatEther(userInfo[0]));

            await tokenIOU.connect(tokenIOUMaker).transfer(alice.address, parseEther("350000"));
            await tokenIOU.connect(tokenIOUMaker).transfer(bob.address, parseEther("350000"));
            await tokenIOUStaking.connect(alice).deposit(parseEther("350000"));
            await tokenIOUStaking.connect(bob).deposit(parseEther("350000"));
            increase(86400 * 365);
            userInfo = await tokenIOUStaking.getUserInfo(alice.address, await rewardToken.getAddress());
            console.log("Staking deposit for Alice: " + formatEther(userInfo[0]));
            console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Reward balance before Alice: ", formatEther(await rewardToken.balanceOf(alice.address)));
            expect(await tokenIOUStaking.connect(alice).pendingExtraRewards(alice.address, await rewardToken.getAddress())).to.be.closeTo(parseEther("20.83"), parseEther("0.001"));

            await tokenIOUStaking.connect(alice).withdrawAndClaimExtraRewards(0);

            await tokenIOUStaking.connect(bob).withdrawAndClaimExtraRewards(0);
            await tokenIOUStaking.connect(alice).withdrawAndClaimExtraRewards(0);
            await tokenIOUStaking.connect(alice).withdrawAndClaimExtraRewards(0);
            await tokenIOUStaking.connect(bob).withdrawAndClaimExtraRewards(0);
            console.log("Reward balance after extra rewards Alice: ", formatEther(await rewardToken.balanceOf(alice.address)));
        });

        //This test is invalid as we don't allow redistribution now
        it.skip("unclaimed rewards should be redistributed to other stakers", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                carol,
                tokenIOUMaker
            } = await loadFixture(deployFixture);

            await tokenIOUStaking.connect(alice).deposit(parseEther("100"));
            await tokenIOUStaking.connect(bob).deposit(parseEther("100"));
            await increase(86400 * 7);
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));

            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));
            console.log("accRewardPerShare: ", formatEther(await tokenIOUStaking.accRewardPerShare(await rewardToken.getAddress())));

            console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Pending reward for Alice: " + formatEther((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))));
            console.log("--------------------------------------");
            console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending reward for Bob: " + formatEther(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");

            await tokenIOUStaking.connect(alice).withdraw(parseEther("100"));
            expect(await rewardToken.balanceOf(alice.address)).to.be.closeTo(
                parseEther("25"),
                parseEther("0.0001")
            );
            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));
            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("25"),
                parseEther("0.0001")
            );

            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())).to.be.equal(parseEther("0"));
            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.equal(parseEther("0"));

            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));

            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));
            console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Pending reward for Alice: " + formatEther((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))));
            console.log("--------------------------------------");
            console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending reward for Bob: " + formatEther(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");

            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())).to.be.equal(parseEther("0"));
            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.equal(parseEther("50"));

            await tokenIOUStaking.connect(alice).withdraw(parseEther("0"));
            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));

            expect(await rewardToken.balanceOf(alice.address)).to.be.closeTo(
                parseEther("25"),
                parseEther("0.001")
            );
            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("87.5"),
                parseEther("0.001")
            );

            await increase(86400 * 365);

            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));

            console.log("Reward balance after all withdrawals: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));
            console.log("Reward balance Alice: ", formatEther(await rewardToken.balanceOf(alice.address)));
            console.log("Reward balance Bob: ", formatEther(await rewardToken.balanceOf(bob.address)));

            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("175"),
                parseEther("0.001")
            );

            expect(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).to.be.closeTo(parseEther("0"), parseEther("0.00001"));
        });

        it("redistribution of rewards after an early withdrawal", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                dev,
                bob,
                carol,
                tokenIOUMaker
            } = await loadFixture(deployFixture);

            await tokenIOUStaking.connect(alice).deposit(parseEther("100"));
            await tokenIOUStaking.connect(bob).deposit(parseEther("100"));
            await increase(86400 * 7);
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("200"));

            await tokenIOUStaking.connect(alice).withdraw(parseEther("50"));
            expect(await rewardToken.balanceOf(alice.address)).to.be.closeTo(
                parseEther("50"),
                parseEther("0.0001")
            );

            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));
            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("50"),
                parseEther("0.001")
            );

            console.log("Reward balance after all withdrawals: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));

            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())).to.be.equal(parseEther("0"));
            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.equal(parseEther("0"));

            increase(86400 * 365);

            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("3"));

            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())).to.be.equal(parseEther("51"));
            expect(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.equal(parseEther("52"));

            await tokenIOUStaking.connect(alice).withdraw(parseEther("0"));
            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));

            expect(await rewardToken.balanceOf(alice.address)).to.be.closeTo(
                parseEther("101"),
                parseEther("0.001")
            );
            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("102"),
                parseEther("0.001")
            );

            console.log("Reward balance after all withdrawals: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));
            console.log("Reward balance Alice: ", formatEther(await rewardToken.balanceOf(alice.address)));
            console.log("Reward balance Bob: ", formatEther(await rewardToken.balanceOf(bob.address)));

            expect(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).to.be.closeTo(parseEther("0"), parseEther("0.00001"));
        });

        it("Pending rewards can't exceed the reward pool when remittance is sent after large depositors", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                carol,
                tokenIOUMaker,
                joe
            } = await loadFixture(deployFixture);

            await tokenIOU.connect(joe).transfer(carol.address, parseEther("3000"));
            await tokenIOU.connect(joe).transfer(bob.address, parseEther("1100"));

            await tokenIOUStaking.connect(alice).deposit(parseEther("10"));
            await tokenIOUStaking.connect(bob).deposit(parseEther("10"));
            await tokenIOUStaking.connect(carol).deposit(parseEther("10"));
            await tokenIOUStaking.connect(carol).deposit(parseEther("2858"));
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("10"));
            await increase(86400 * 10);
            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));

            await tokenIOUStaking.connect(bob).deposit(parseEther("1100"));

            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));

            // console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Pending reward for Alice: " + formatUnits(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()), 18));
            console.log("--------------------------------------");
            // console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending reward for Bob: " + formatUnits(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress()), 18));
            console.log("--------------------------------------");
            // console.log("Staking multiplier for Carol: " + formatEther(await tokenIOUStaking.getStakingMultiplier(carol.address)));
            console.log("Pending reward for Carol: " + formatUnits(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress()), 18));

            //Total pending reward amount can't exceed the reward pool balance
            const alicePendingReward = await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress());
            const bobPendingReward = await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress());
            const carolPendingReward = await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress());

            const totalPendingReward = ethers.BigNumber.from(alicePendingReward)
                .add(bobPendingReward)
                .add(carolPendingReward);

            const stakingBalance = await rewardToken.balanceOf(await tokenIOUStaking.getAddress());

            expect(totalPendingReward).to.be.lte(stakingBalance);

        });

        it("Pending rewards can't exceed the reward pool when remittance is sent before large depositors", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                carol,
                tokenIOUMaker,
                joe
            } = await loadFixture(deployFixture);

            await tokenIOU.connect(joe).transfer(carol.address, parseEther("3000"));
            await tokenIOU.connect(joe).transfer(bob.address, parseEther("1100"));

            await tokenIOUStaking.connect(alice).deposit(parseEther("10"));
            await tokenIOUStaking.connect(bob).deposit(parseEther("10"));
            await tokenIOUStaking.connect(carol).deposit(parseEther("10"));
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("10"));
            await tokenIOUStaking.connect(carol).deposit(parseEther("2858"));
            await increase(86400 * 10);

            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));

            // await tokenIOUStaking.connect(bob).deposit(parseEther("1100"));

            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));

            // console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Pending reward for Alice: " + formatUnits(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()), 18));
            console.log("--------------------------------------");
            // console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending reward for Bob: " + formatUnits(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress()), 18));
            console.log("--------------------------------------");
            // console.log("Staking multiplier for Carol: " + formatEther(await tokenIOUStaking.getStakingMultiplier(carol.address)));
            console.log("Pending reward for Carol: " + formatUnits(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress()), 18));

            //Total pending reward amount can't exceed the reward pool balance
            expect((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress()))
            ).to.be.lte(await rewardToken.balanceOf(await tokenIOUStaking.getAddress()));

        });

        it("Pending rewards can't exceed the reward pool in realistic scenario", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                carol,
                tokenIOUMaker,
                joe
            } = await loadFixture(deployFixture);

            await tokenIOU.connect(joe).transfer(carol.address, parseEther("3300"));
            await tokenIOU.connect(joe).transfer(bob.address, parseEther("2000"));

            await tokenIOUStaking.connect(alice).deposit(parseEther("100"));
            await tokenIOUStaking.connect(bob).deposit(parseEther("200"));
            await tokenIOUStaking.connect(carol).deposit(parseEther("300"));
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("300"));
            await tokenIOUStaking.connect(carol).deposit(parseEther("3000"));
            await increase(86400 * 10);
            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("200"));

            await tokenIOUStaking.connect(bob).deposit(parseEther("2000"));

            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));

            // console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Pending reward for Alice: " + formatUnits(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()), 18));
            console.log("--------------------------------------");
            // console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending reward for Bob: " + formatUnits(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress()), 18));
            console.log("--------------------------------------");
            // console.log("Staking multiplier for Carol: " + formatEther(await tokenIOUStaking.getStakingMultiplier(carol.address)));
            console.log("Pending reward for Carol: " + formatUnits(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress()), 18));

            //Total pending reward amount can't exceed the reward pool balance
            expect((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress()))
            ).to.be.lte(await rewardToken.balanceOf(await tokenIOUStaking.getAddress()));

            await tokenIOUStaking.connect(bob).deposit(parseEther("200"));

            expect((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress()))
            ).to.be.lte(await rewardToken.balanceOf(await tokenIOUStaking.getAddress()));

            await tokenIOUStaking.connect(alice).deposit(parseEther("300"));
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));
            increase(86400 * 5);

            expect((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress()))
            ).to.be.lte(await rewardToken.balanceOf(await tokenIOUStaking.getAddress()));

            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));
            increase(86400 * 5);
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("200"));

            expect((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress()))
            ).to.be.lte(await rewardToken.balanceOf(await tokenIOUStaking.getAddress()));

        });

        it("Pending rewards can't exceed the reward pool when remittance is sent before large depositors on original contract implementation", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                carol,
                tokenIOUMaker,
                joe,
                joeStaking
            } = await loadFixture(deployFixture);

            await tokenIOU.connect(joe).transfer(carol.address, parseEther("3000"));
            await tokenIOU.connect(joe).transfer(bob.address, parseEther("1100"));

            await joeStaking.connect(alice).deposit(parseEther("10"));
            await joeStaking.connect(bob).deposit(parseEther("10"));
            await joeStaking.connect(carol).deposit(parseEther("10"));
            await joeStaking.connect(carol).deposit(parseEther("1"));
            await rewardToken.connect(tokenIOUMaker).transfer(joeStaking.address, parseEther("10"));
            await joeStaking.connect(carol).deposit(parseEther("3000"));
            await increase(86400 * 10);
            await rewardToken.connect(tokenIOUMaker).transfer(joeStaking.address, parseEther("10"));

            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(joeStaking.address)));

            // await joeStaking.connect(bob).deposit(parseEther("1100"));

            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(joeStaking.address)));

            console.log("Pending reward for Alice: " + formatUnits(await joeStaking.pendingReward(alice.address, await rewardToken.getAddress()), 18));
            console.log("--------------------------------------");
            console.log("Pending reward for Bob: " + formatUnits(await joeStaking.pendingReward(bob.address, await rewardToken.getAddress()), 18));
            console.log("--------------------------------------");
            console.log("Pending reward for Carol: " + formatUnits(await joeStaking.pendingReward(carol.address, await rewardToken.getAddress()), 18));

            //Total pending reward amount can't exceed the reward pool balance
            expect((await joeStaking.pendingReward(alice.address, await rewardToken.getAddress()))
                .add(await joeStaking.pendingReward(bob.address, await rewardToken.getAddress()))
                .add(await joeStaking.pendingReward(carol.address, await rewardToken.getAddress()))
            ).to.be.lte(await rewardToken.balanceOf(joeStaking.address));

        });

        it("Pending rewards can't exceed the reward pool when remittance is sent before large depositors with existing stakers with multipliers", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                carol,
                tokenIOUMaker,
                joe
            } = await loadFixture(deployFixture);

            await tokenIOU.connect(joe).transfer(carol.address, parseEther("3000"));
            await tokenIOU.connect(joe).transfer(bob.address, parseEther("1100"));

            await tokenIOUStaking.connect(alice).deposit(parseEther("10"));
            await tokenIOUStaking.connect(bob).deposit(parseEther("10"));
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));

            await increase(86400 * 10);

            await tokenIOUStaking.connect(bob).deposit(parseEther("100"));

            await tokenIOUStaking.connect(carol).deposit(parseEther("10"));
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));
            await tokenIOUStaking.connect(carol).deposit(parseEther("2858"));

            await increase(86400 * 10);

            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));


            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));

            // console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Pending reward for Alice: " + formatUnits(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()), 18));
            console.log("--------------------------------------");
            // console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending reward for Bob: " + formatUnits(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress()), 18));
            console.log("--------------------------------------");
            // console.log("Staking multiplier for Carol: " + formatEther(await tokenIOUStaking.getStakingMultiplier(carol.address)));
            console.log("Pending reward for Carol: " + formatUnits(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress()), 18));

            //Total pending reward amount can't exceed the reward pool balance
            expect((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress()))
            ).to.be.lte(await rewardToken.balanceOf(await tokenIOUStaking.getAddress()));

        });


        it("Special case logic exploit can't exceed reward pool balance", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                carol,
                tokenIOUMaker,
                joe
            } = await loadFixture(deployFixture);

            await tokenIOU.connect(joe).transfer(carol.address, parseEther("3000"));
            await tokenIOU.connect(joe).transfer(bob.address, parseEther("1100"));

            await tokenIOUStaking.connect(alice).deposit(parseEther("10"));
            await tokenIOUStaking.connect(bob).deposit(parseEther("10"));
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));

            await increase(86400 * 10);

            await tokenIOUStaking.connect(bob).deposit(parseEther("1000"));

            await tokenIOUStaking.connect(carol).deposit(parseEther("10"));
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));
            await tokenIOUStaking.connect(carol).deposit(parseEther("1000"));

            await increase(86400 * 10);

            console.log("Reward pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));

            console.log("--------------------------------------");
            let userInfo = await tokenIOUStaking.getUserInfo(alice.address, await rewardToken.getAddress());
            console.log("Staking deposit for Alice: " + formatEther(userInfo[0]));
            // console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Pending reward for Alice: " + formatUnits(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()), 18));
            console.log("Reward debt for Alice: " + formatEther(userInfo[1]));

            console.log("--------------------------------------");
            userInfo = await tokenIOUStaking.getUserInfo(bob.address, await rewardToken.getAddress());
            console.log("Staking deposit for Bob: " + formatEther(userInfo[0]));
            // console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending reward for Bob: " + formatUnits(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress()), 18));
            console.log("Reward debt for Bob: " + formatEther(userInfo[1]));

            console.log("--------------------------------------");
            userInfo = await tokenIOUStaking.getUserInfo(carol.address, await rewardToken.getAddress());
            console.log("Staking deposit for Carol: " + formatEther(userInfo[0]));
            // console.log("Staking multiplier for Carol: " + formatEther(await tokenIOUStaking.getStakingMultiplier(carol.address)));
            console.log("Pending reward for Carol: " + formatUnits(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress()), 18));
            console.log("Reward debt for Carol: " + formatEther(userInfo[1]));

            // Total pending reward amount can't exceed the reward pool balance
            expect((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress()))
            ).to.be.lte(await rewardToken.balanceOf(await tokenIOUStaking.getAddress()));

        });

        it("original protocol reward distribution test", async function () {

            const {
                joeStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                carol,
                tokenIOUMaker,
            } = await loadFixture(deployFixture);

            await joeStaking.connect(alice).deposit(parseEther("100"));
            await joeStaking.connect(carol).deposit(parseEther("100"));

            await rewardToken.connect(tokenIOUMaker).transfer(joeStaking.address, parseEther("100"));

            /// now Bob enters, and he will only receive the rewards deposited after he entered
            await joeStaking.connect(bob).deposit(parseEther("500"));

            console.log("Reward pool balance: " + (await rewardToken.balanceOf(joeStaking.address)).toString());
            console.log("Pending reward for Alice: " + formatEther((await joeStaking.pendingReward(alice.address, await rewardToken.getAddress()))));
            console.log("--------------------------------------");
            console.log("Pending reward for Bob: " + formatEther(await joeStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");
            console.log("Pending reward for Carol: " + formatEther(await joeStaking.pendingReward(carol.address, await rewardToken.getAddress())));

            await joeStaking.connect(carol).withdraw(parseEther("100"));

            expect(await rewardToken.balanceOf(carol.address)).to.be.closeTo(
                parseEther("50"),
                parseEther("0.0001")
            );

            console.log("Reward pool balance: " + (await rewardToken.balanceOf(joeStaking.address)).toString());

            await joeStaking.connect(alice).deposit(parseEther("100")); // Alice enters again to try to get more rewards
            await joeStaking.connect(alice).withdraw(parseEther("200"));
            // She gets the same reward as Carol
            const lastAliceBalance = await rewardToken.balanceOf(alice.address);

            expect(lastAliceBalance).to.be.closeTo(
                parseEther("50"),
                parseEther("0.001")
            );

            console.log("Reward pool balance: " + formatEther(await rewardToken.balanceOf(joeStaking.address)).toString());
            console.log("Pending reward for Bob: " + formatEther(await joeStaking.pendingReward(bob.address, await rewardToken.getAddress())));

            // Reward pool should have enough tokens to pay Bob
            expect(await joeStaking.pendingReward(bob.address, await rewardToken.getAddress())).to.be.lte(await rewardToken.balanceOf(joeStaking.address));

            console.log("Staking deposit for Alice: " + (await joeStaking.getUserInfo(alice.address, await rewardToken.getAddress()))[0]);
            console.log("Staking deposit for Carol: " + (await joeStaking.getUserInfo(carol.address, await rewardToken.getAddress()))[0]);
            console.log("Staking deposit for Bob: " + (await joeStaking.getUserInfo(bob.address, await rewardToken.getAddress()))[0]);

            await rewardToken.connect(tokenIOUMaker).transfer(joeStaking.address, parseEther("100"));

            console.log("Pending reward for Bob: " + formatEther(await joeStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("Reward pool balance: " + formatEther(await rewardToken.balanceOf(joeStaking.address)).toString());

            await joeStaking.connect(bob).withdraw("0");

            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("100"),
                parseEther("0.001")
            );

            // Alice shouldn't receive any token of the last reward
            await joeStaking.connect(alice).withdraw("0");
            // reward = accRewardBalance * aliceShare / PRECISION - aliceRewardDebt
            //        = accRewardBalance * 0 / PRECISION - 0
            //        = 0      (she withdrew everything, so her share is 0)
            expect(await rewardToken.balanceOf(alice.address)).to.be.equal(lastAliceBalance);

            console.log("--------------------------------------");
            console.log("Reward pool balance at the end: " + (await rewardToken.balanceOf(joeStaking.address)).toString());
            console.log("--------------------------------------");
            console.log("Staking deposit for Alice: " + (await joeStaking.getUserInfo(alice.address, await rewardToken.getAddress()))[0]);
            console.log("Reward balance for Alice at the end: " + formatEther(await rewardToken.balanceOf(alice.address)).toString());
            console.log("Pending reward for Alice: " + formatEther(await joeStaking.pendingReward(alice.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");
            console.log("Staking deposit for Bob: " + (await joeStaking.getUserInfo(bob.address, await rewardToken.getAddress()))[0]);
            console.log("Reward balance for Bob at the end: " + formatEther(await rewardToken.balanceOf(bob.address)).toString());
            console.log("Pending reward for Bob: " + formatEther(await joeStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("--------------------------------------");
            console.log("Staking deposit for Carol: " + (await joeStaking.getUserInfo(carol.address, await rewardToken.getAddress()))[0]);
            console.log("Reward balance for Carol at the end: " + formatEther(await rewardToken.balanceOf(carol.address)).toString());
            console.log("Pending reward for Carol: " + formatEther(await joeStaking.pendingReward(carol.address, await rewardToken.getAddress())));
        });

        it("Staking rewards redistribution to community plus users", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                carol,
                tokenIOUMaker,
                joe
            } = await loadFixture(deployFixture);

            await tokenIOUStaking.connect(alice).deposit(parseEther("20"));
            increase(86400 * 365);
            await tokenIOUStaking.connect(bob).deposit(parseEther("30"));
            increase(86400 * 7);
            await tokenIOUStaking.connect(carol).deposit(parseEther("50"));

            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("1000"));

            console.log("-- -- - Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));

            console.log("Reward pool balance: " + (await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).toString());
            console.log("Pending reward for Alice: " + formatEther((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))));
            console.log("--------------------------------------");
            expect(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress())).to.be.equal(parseEther("200"));

            await tokenIOUStaking.connect(alice).withdraw(parseEther("0"));
            await tokenIOUStaking.connect(bob).withdraw(parseEther("0"));
            await tokenIOUStaking.connect(carol).withdraw(parseEther("0"));

            console.log("Pending reward for Alice: " + formatEther((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))));
            console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Reward balance for Alice: " + formatEther(await rewardToken.balanceOf(alice.address)));
            console.log("--------------------------------------");
            console.log("Pending reward for Bob: " + formatEther(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress())));
            console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Reward balance for Bob: " + formatEther(await rewardToken.balanceOf(bob.address)));
            console.log("--------------------------------------");
            console.log("Pending reward for Carol: " + formatEther(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress())));
            console.log("Reward balance for Carol: " + formatEther(await rewardToken.balanceOf(carol.address)));

            console.log("Reward pool balance: " + (await rewardToken.balanceOf(await tokenIOUStaking.getAddress())).toString());

            expect(await rewardToken.balanceOf(alice.address)).to.be.equal(parseEther("200"));
            expect(await rewardToken.balanceOf(bob.address)).to.be.equal(parseEther("150"));
            expect(await rewardToken.balanceOf(carol.address)).to.be.equal(parseEther("0"));

            increase(86400 * 365);
            console.log("Staking multiplier for Carol: " + formatEther(await tokenIOUStaking.getStakingMultiplier(carol.address)));
            console.log("Pending reward for Carol: " + formatEther(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress())));
            expect(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress())).to.be.equal(parseEther("500"));
            await tokenIOUStaking.connect(carol).withdraw(parseEther("0"));
            expect(await rewardToken.balanceOf(carol.address)).to.be.equal(parseEther("500"));

        });

        it("Production test case simulation, ensures no funds end up unclaimable", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                carol,
                tokenIOUMaker,
                joe
            } = await loadFixture(deployFixture);


            await tokenIOUStaking.connect(alice).deposit(parseEther("10"));
            await tokenIOUStaking.connect(bob).deposit(parseEther("50"));
            await tokenIOUStaking.connect(carol).deposit(parseEther("20"));
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("10"));

            await increase(86400 * 10);

            await tokenIOUStaking.connect(bob).withdraw(parseEther("50"));

            console.log("Reward balance for Bob: " + formatEther(await rewardToken.balanceOf(bob.address)));
            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("3.150937"),
                parseEther("0.01")
            );

            await tokenIOUStaking.connect(bob).deposit(parseEther("50"));
            expect(await tokenIOUStaking.getStakingMultiplier(bob.address)).to.be.equal(parseEther("0.0"));

            await tokenIOU.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));
            await tokenIOUStaking.addRewardToken(await tokenIOU.getAddress());

            await tokenIOUStaking.connect(bob).withdraw(parseEther("50"));
            await tokenIOU.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));

            await tokenIOUStaking.connect(bob).deposit(parseEther("50"));
            await tokenIOU.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("100"));
            await tokenIOUStaking.connect(bob).withdraw(parseEther("50"));

            console.log("Forgone USDC reward pool balance: " + formatEther(await tokenIOUStaking.forgoneRewardsPool(await rewardToken.getAddress())));
            console.log("Forgone tokenIOU reward pool balance: " + formatEther(await tokenIOUStaking.forgoneRewardsPool(await tokenIOU.getAddress())));

            console.log("Reward USDC pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));
            console.log("Total tokenIOU pool balance: ", formatEther(await tokenIOU.balanceOf(await tokenIOUStaking.getAddress())));
            console.log("--------------------------------------");
            console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Pending USDC reward for Alice: " + formatUnits(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()), 18));
            console.log("Pending tokenIOU reward for Alice: " + formatUnits(await tokenIOUStaking.pendingReward(alice.address, await tokenIOU.getAddress()), 18));
            console.log("--------------------------------------");
            console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending USDC reward for Bob: " + formatUnits(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress()), 18));
            console.log("Pending tokenIOU reward for Bob: " + formatUnits(await tokenIOUStaking.pendingReward(bob.address, await tokenIOU.getAddress()), 18));
            console.log("--------------------------------------");
            console.log("Staking multiplier for Carol: " + formatEther(await tokenIOUStaking.getStakingMultiplier(carol.address)));
            console.log("Pending USDC reward for Carol: " + formatUnits(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress()), 18));
            console.log("Pending tokenIOU reward for Carol: " + formatUnits(await tokenIOUStaking.pendingReward(carol.address, await tokenIOU.getAddress()), 18));

            console.log("- - - END -- STATE- -- - - -- -");

            //Forgone rewards from Bob should equal 125 tokenIOU
            expect(await tokenIOUStaking.forgoneRewardsPool(await tokenIOU.getAddress())).to.be.equal(parseEther("125"));

            //Total pending reward amount can't exceed the reward pool balance
            expect((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress()))
            ).to.be.lte(await rewardToken.balanceOf(await tokenIOUStaking.getAddress()));

        });


        it("Ensure forgoneRewardsPool never goes over the available amount of tokens", async function () {

            const {
                tokenIOUStaking,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                carol,
                tokenIOUMaker,
                joe
            } = await loadFixture(deployFixture);


            await tokenIOUStaking.connect(alice).deposit(parseEther("100"));
            await tokenIOUStaking.connect(bob).deposit(parseEther("200"));
            await tokenIOUStaking.connect(carol).deposit(parseEther("100"));
            await rewardToken.connect(tokenIOUMaker).transfer(await tokenIOUStaking.getAddress(), parseEther("1000"));

            await increase(86400 * 30);

            await tokenIOUStaking.connect(carol).withdraw(parseEther("100"));

            console.log("Reward balance for Carol: " + formatEther(await rewardToken.balanceOf(carol.address)));
            expect(await rewardToken.balanceOf(carol.address)).to.be.closeTo(
                parseEther("133.30"),
                parseEther("0.01")
            );

            await increase(86400 * 365);
            expect(await tokenIOUStaking.getStakingMultiplier(bob.address)).to.be.equal(parseEther("1"));

            await tokenIOUStaking.connect(bob).withdraw(parseEther("200"));
            expect(await tokenIOUStaking.getStakingMultiplier(bob.address)).to.be.equal(parseEther("0.0"));

            console.log("Reward balance for Bob: " + formatEther(await rewardToken.balanceOf(bob.address)));
            expect(await rewardToken.balanceOf(bob.address)).to.be.closeTo(
                parseEther("500"),
                parseEther("0.01")
            );

            console.log("Forgone USDC reward pool balance: " + formatEther(await tokenIOUStaking.forgoneRewardsPool(await rewardToken.getAddress())));

            console.log("Reward USDC pool balance: ", formatEther(await rewardToken.balanceOf(await tokenIOUStaking.getAddress())));
            console.log("Total tokenIOU pool balance: ", formatEther(await tokenIOU.balanceOf(await tokenIOUStaking.getAddress())));
            console.log("--------------------------------------");
            console.log("Staking multiplier for Alice: " + formatEther(await tokenIOUStaking.getStakingMultiplier(alice.address)));
            console.log("Pending USDC reward for Alice: " + formatUnits(await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()), 18));
            console.log("--------------------------------------");
            console.log("Staking multiplier for Bob: " + formatEther(await tokenIOUStaking.getStakingMultiplier(bob.address)));
            console.log("Pending USDC reward for Bob: " + formatUnits(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress()), 18));
            console.log("--------------------------------------");
            console.log("Staking multiplier for Carol: " + formatEther(await tokenIOUStaking.getStakingMultiplier(carol.address)));
            console.log("Pending USDC reward for Carol: " + formatUnits(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress()), 18));

            console.log("- - - END -- STATE- -- - - -- -");

            //Forgone rewards for Alice should equal 125 USDC
            expect(await tokenIOUStaking.forgoneRewardsPool(await rewardToken.getAddress())).to.be.closeTo(parseEther("116.693"), parseEther("0.001"));

            //Total pending reward amount can't exceed the reward pool balance
            expect((await tokenIOUStaking.pendingReward(alice.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(bob.address, await rewardToken.getAddress()))
                .add(await tokenIOUStaking.pendingReward(carol.address, await rewardToken.getAddress()))
            ).to.be.lte(await rewardToken.balanceOf(await tokenIOUStaking.getAddress()));

        });

        it("Auto staking", async function () {

            const {
                tokenIOUStakingBasic,
                tokenIOU,
                rewardToken,
                alice,
                bob,
                carol,
                tokenIOUMaker,
            } = await loadFixture(deployFixture);

            await tokenIOUStakingBasic.connect(alice).deposit(parseEther("100"));
            await tokenIOUStakingBasic.connect(bob).deposit(parseEther("200"));
            await rewardToken.connect(tokenIOUMaker).transfer(tokenIOUStakingBasic.address, parseEther("100"));
            await increase(86400 * 365);

            console.log("Reward USDC pool balance: ", formatEther(await rewardToken.balanceOf(tokenIOUStakingBasic.address)));
            console.log("Before Total tokenIOU pool balance: ", formatEther(await tokenIOU.balanceOf(tokenIOUStakingBasic.address)));
            console.log("--------------------------------------");
            console.log("Pending USDC reward for Alice: " + formatUnits(await tokenIOUStakingBasic.pendingReward(alice.address, await rewardToken.getAddress()), 18));
            console.log("Pending USDC reward for Bob: " + formatUnits(await tokenIOUStakingBasic.pendingReward(bob.address, await rewardToken.getAddress()), 18));

            console.log("Reward balance of Alice: " + formatEther(await rewardToken.balanceOf(alice.address)));
            console.log("Reward balance of Bob: " + formatEther(await rewardToken.balanceOf(bob.address)));
            console.log("--------------------------------------");

            // await rewardToken.connect(tokenIOUMaker).transfer(tokenIOUStakingBasic.address, parseEther("100"));
            await tokenIOUStakingBasic.connect(bob).restakeRewards();

            console.log("Reward USDC pool balance: ", formatEther(await rewardToken.balanceOf(tokenIOUStakingBasic.address)));
            console.log("After Total tokenIOU pool balance: ", formatEther(await tokenIOU.balanceOf(tokenIOUStakingBasic.address)));
            console.log("--------------------------------------");
            console.log("Pending USDC reward for Alice: " + formatUnits(await tokenIOUStakingBasic.pendingReward(alice.address, await rewardToken.getAddress()), 18));
            console.log("Pending USDC reward for Bob: " + formatUnits(await tokenIOUStakingBasic.pendingReward(bob.address, await rewardToken.getAddress()), 18));

            console.log("Reward balance of Alice: " + formatEther(await rewardToken.balanceOf(alice.address)));
            console.log("Reward balance of Bob: " + formatEther(await rewardToken.balanceOf(bob.address)));
            console.log("--------------------------------------");
        });

    });

    // after(async function () {
    //     await network.provider.request({
    //         method: "hardhat_reset",
    //         params: [],
    //     });
    // });
})
;

const increase = (seconds: number) => {
    ethers.provider.send("evm_increaseTime", [seconds]);
    ethers.provider.send("evm_mine", []);
};