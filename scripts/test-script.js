// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const hre = require("hardhat");
const ethers = hre.ethers;
async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  // await hre.run('compile');

  const [owner, vault, user1, user2, user3] = await ethers.getSigners();

  // We get the contract to deploy
  const TVBToken = await hre.ethers.getContractFactory("TVBToken");
  const token = await TVBToken.deploy();
  await token.deployed();
  console.log("TVB Token (for staking test) deployed to:", token.address);
  console.log("Total Supply: ", (await token.totalSupply()).toString());

  const StakedAave = await hre.ethers.getContractFactory("StakedTVB");
  const stkToken = await StakedAave.deploy(
    token.address,
    token.address,
    10,
    24 * 3600,
    vault.address,
    owner.address,
    365 * 24 * 60 * 60
  );
  // staked token is also reward token
  // 10s cooldown seconds
  // 24h window

  await stkToken.deployed();
  console.log("stkAave deployed to:", stkToken.address);

  // tranfer some tokens for vault and user
  await token.transfer(vault.address, 10000000000);
  await token.transfer(user1.address, 200000000);
  await token.transfer(user2.address, 200000000);
  await token.transfer(user3.address, 200000000);

  // aprove for staked contract
  await token.connect(vault).approve(stkToken.address, 1000000000);
  await token.connect(user1).approve(stkToken.address, 200000000);
  await token.connect(user2).approve(stkToken.address, 200000000);
  await token.connect(user3).approve(stkToken.address, 200000000);

  // config
  await stkToken.configureAssets([
    { emissionPerSecond: 1, totalStaked: 0, underlyingAsset: stkToken.address },
  ]);

  // start staking
  await stkToken.connect(user1).stake(user1.address, 500000);
  // await stkToken.connect(user3).stake(user1.address, 500000);
  console.log(
    "User1 staking end at ",
    (await stkToken.getUserLockEndTimestamp(user1.address)).toString()
  );
  console.log("Current userCount ", (await stkToken.userCount()).toString());
  console.log("Current emission/second ", (await stkToken.getAssetEmissionPerSecond()).toString());

  let user1Reward;
  let user2Reward;

  await ethers.provider.send("evm_increaseTime", [5 * 24 * 3600]);
  await ethers.provider.send("evm_mine");
  console.log("Next 5 days... Current timestamp is ", (await ethers.provider.getBlock((await ethers.provider.getBlockNumber()))).timestamp);

  user1Reward = await stkToken.getTotalRewardsBalance(user1.address);
  console.log("Reward of User 1: ", user1Reward.toString());

  await ethers.provider.send("evm_increaseTime", [1 * 24 * 3600]);
  await ethers.provider.send("evm_mine");
  console.log("Next 1 day... Current timestamp is ", (await ethers.provider.getBlock((await ethers.provider.getBlockNumber()))).timestamp);

  user1Reward = await stkToken.getTotalRewardsBalance(user1.address);
  console.log("Reward of User 1: ", user1Reward.toString());

  await ethers.provider.send("evm_increaseTime", [2 * 24 * 3600]);
  await ethers.provider.send("evm_mine");
  console.log("Next 1 day... Current timestamp is ", (await ethers.provider.getBlock((await ethers.provider.getBlockNumber()))).timestamp);

  user1Reward = await stkToken.getTotalRewardsBalance(user1.address);
  console.log("Reward of User 1: ", user1Reward.toString());

  await stkToken.connect(user2).stake(user2.address, 500000);
  await stkToken.connect(user3).stake(user3.address, 500000);
  console.log("Current userCount ", (await stkToken.userCount()).toString());
  console.log("Current emission/second ", (await stkToken.getAssetEmissionPerSecond()).toString());

  await ethers.provider.send("evm_increaseTime", [7 * 24 * 3600]);
  await ethers.provider.send("evm_mine");
  console.log("Next 5 days... Current timestamp is ", (await ethers.provider.getBlock((await ethers.provider.getBlockNumber()))).timestamp);

  user1Reward = await stkToken.getTotalRewardsBalance(user1.address);
  console.log("Reward of User 1: ", user1Reward.toString());
  user2Reward = await stkToken.getTotalRewardsBalance(user2.address);
  console.log("Reward of User 2: ", user2Reward.toString());

  await ethers.provider.send("evm_increaseTime", [1 * 24 * 3600]);
  await ethers.provider.send("evm_mine");
  console.log("Next 5 days... Current timestamp is ", (await ethers.provider.getBlock((await ethers.provider.getBlockNumber()))).timestamp);

  user1Reward = await stkToken.getTotalRewardsBalance(user1.address);
  console.log("Reward of User 1: ", user1Reward.toString());

  user2Reward = await stkToken.getTotalRewardsBalance(user2.address);
  console.log("Reward of User 2: ", user2Reward.toString());
  await stkToken.connect(user1).claimRewards(user1.address, user1Reward);
  await stkToken.connect(user2).claimRewards(user2.address, user2Reward);

  user1Reward = await stkToken.getTotalRewardsBalance(user1.address);
  console.log("Reward of User 1: ", user1Reward.toString());
  user2Reward = await stkToken.getTotalRewardsBalance(user2.address);
  console.log("Reward of User 2: ", user2Reward.toString());
  
  console.log("User 1 call cooldown()");
  await stkToken.connect(user1).cooldown();

  await ethers.provider.send("evm_increaseTime", [3600]);
  await ethers.provider.send("evm_mine");
  console.log("Next 30s...");

  await stkToken.connect(user1).redeem(user1.address, 500000);
  console.log("Balance of user 1: ", await token.balanceOf(user1.address));
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
