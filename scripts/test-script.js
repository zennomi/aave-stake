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

  const [owner, vault, user1, user2] = await ethers.getSigners();

  // We get the contract to deploy
  const TVBToken = await hre.ethers.getContractFactory("TVBToken");
  const token = await TVBToken.deploy();
  await token.deployed();
  console.log("TVB Token (for staking test) deployed to:", token.address);
  console.log("Total Supply: ", await token.totalSupply());

  const StakedAave = await hre.ethers.getContractFactory("StakedAave");
  const stkToken = await StakedAave.deploy(token.address, token.address, 10, 10, vault.address, owner.address, 365 * 24 * 60 * 60);
  // staked token is also reward token
  // 10s cooldown seconds
  // 10s window

  await stkToken.deployed();
  console.log("stkAave deployed to:", stkToken.address);

  // tranfer some tokens for vault and user
  await token.transfer(vault.address, 100000000);
  await token.transfer(user1.address, 2000000);
  await token.transfer(user2.address, 2000000);

  // aprove for staked contract
  await token.connect(vault).approve(stkToken.address, 10000000);
  await token.connect(user1).approve(stkToken.address, 2000000);
  await token.connect(user2).approve(stkToken.address, 2000000);
  
  // config
  await stkToken.configureAssets([{ emissionPerSecond: 1, totalStaked: 0, underlyingAsset: stkToken.address }])
  
  // start staking
  await stkToken.connect(user1).stake(user1.address, 1000000);
  await stkToken.connect(user2).stake(user2.address, 1500000);
  
  // fake time
  await ethers.provider.send("evm_increaseTime", [7 * 24 * 3600]);
  await ethers.provider.send('evm_mine');
  //
  // check reward
  console.log(await token.balanceOf(user1.address));
  const user1Reward1 = await stkToken.getTotalRewardsBalance(user1.address);
  await stkToken.connect(user2).stake(user2.address, 500000);
  const user1Reward = await stkToken.getTotalRewardsBalance(user1.address);
  console.log(user1Reward);
  await stkToken.connect(user1).claimRewards(user1.address, user1Reward);
  console.log(await token.balanceOf(user1.address));
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
