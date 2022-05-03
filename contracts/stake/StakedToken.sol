// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.5;
pragma experimental ABIEncoderV2;
import "hardhat/console.sol";

import {IERC20} from "../interfaces/IERC20.sol";
import {IStakedAave} from "../interfaces/IStakedAave.sol";
import {ITransferHook} from "../interfaces/ITransferHook.sol";
import {ERC20WithSnapshot} from "../lib/ERC20WithSnapshot.sol";
import {SafeERC20} from "../lib/SafeERC20.sol";
import {VersionedInitializable} from "../utils/VersionedInitializable.sol";
import {DistributionTypes} from "../lib/DistributionTypes.sol";
import {AaveDistributionManager} from "./AaveDistributionManager.sol";
import {SafeMath} from "../lib/SafeMath.sol";

/**
 * @title StakedToken
 * @notice Contract to stake Aave token, tokenize the position and get rewards, inheriting from a distribution manager contract
 * @author Aave
 **/
contract StakedToken is
    IStakedAave,
    ERC20WithSnapshot,
    VersionedInitializable,
    AaveDistributionManager
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant REVISION = 1;

    IERC20 public immutable STAKED_TOKEN;
    IERC20 public immutable REWARD_TOKEN;
    uint256 public immutable COOLDOWN_SECONDS;
    uint256 public immutable LOCK_SECONDS = 7 * 24 * 3600; // LOCK IN 7 DAYS

    /// @notice Seconds available to redeem once the cooldown period is fullfilled
    uint256 public immutable UNSTAKE_WINDOW;

    /// @notice Address to pull from the rewards, needs to have approved this contract
    address public immutable REWARDS_VAULT;

    mapping(address => uint256) public stakerRewardsToClaim;
    mapping(address => uint256) public stakersCooldowns;
    mapping(address => uint256) public stakersLockEndTimestamp;
    mapping(uint256 => uint256) public indexAtTimestamp;
    mapping(uint256 => uint256) public subSupplyAtTimestamp;

    uint256 public userCount;

    uint256[] stakeEndTimestamps;
    uint256 public currentSupply; // except users whose staking ended

    uint256 private timestampsStartIndex;
    uint256 private subSupplyStartIndex;

    event Staked(
        address indexed from,
        address indexed onBehalfOf,
        uint256 amount
    );
    event Redeem(address indexed from, address indexed to, uint256 amount);

    event RewardsAccrued(address user, uint256 amount);
    event RewardsClaimed(
        address indexed from,
        address indexed to,
        uint256 amount
    );

    event Cooldown(address indexed user);

    constructor(
        IERC20 stakedToken,
        IERC20 rewardToken,
        uint256 cooldownSeconds,
        uint256 unstakeWindow,
        address rewardsVault,
        address emissionManager,
        uint128 distributionDuration,
        string memory name,
        string memory symbol,
        uint8 decimals
    )
        public
        ERC20WithSnapshot(name, symbol, decimals)
        AaveDistributionManager(emissionManager, distributionDuration)
    {
        STAKED_TOKEN = stakedToken;
        REWARD_TOKEN = rewardToken;
        COOLDOWN_SECONDS = cooldownSeconds;
        UNSTAKE_WINDOW = unstakeWindow;
        REWARDS_VAULT = rewardsVault;
    }

    /**
     * @dev Called by the proxy contract
     **/
    function initialize(
        ITransferHook aaveGovernance,
        string calldata name,
        string calldata symbol,
        uint8 decimals
    ) external initializer {
        _setName(name);
        _setSymbol(symbol);
        _setDecimals(decimals);
        _setAaveGovernance(aaveGovernance);
    }

    function stake(address onBehalfOf, uint256 amount) external override {
        require(amount != 0, "INVALID_ZERO_AMOUNT");
        uint256 balanceOfUser = balanceOf(onBehalfOf);
        require(stakersLockEndTimestamp[msg.sender] == 0, "USER_STAKED");

        userCount = userCount.add(1);

        uint256 accruedRewards = _updateUserAssetInternal(
            onBehalfOf,
            address(this),
            balanceOfUser,
            currentSupply
        );
        if (accruedRewards != 0) {
            emit RewardsAccrued(onBehalfOf, accruedRewards);
            stakerRewardsToClaim[onBehalfOf] = stakerRewardsToClaim[onBehalfOf]
                .add(accruedRewards);
        }

        stakersCooldowns[onBehalfOf] = getNextCooldownTimestamp(
            0,
            amount,
            onBehalfOf,
            balanceOfUser
        );

        _mint(onBehalfOf, amount);
        IERC20(STAKED_TOKEN).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        uint256 lockEndTimestamp = block.timestamp.add(LOCK_SECONDS);

        stakersLockEndTimestamp[msg.sender] = lockEndTimestamp;

        stakeEndTimestamps.push(lockEndTimestamp);

        currentSupply = currentSupply.add(amount);

        subSupplyAtTimestamp[lockEndTimestamp] = subSupplyAtTimestamp[
            lockEndTimestamp
        ].add(amount);

        emit Staked(msg.sender, onBehalfOf, amount);
    }

    /**
     * @dev Redeems staked tokens, and stop earning rewards
     * @param to Address to redeem to
     * @param amount Amount to redeem
     **/
    function redeem(address to, uint256 amount) external override {
        require(amount != 0, "INVALID_ZERO_AMOUNT");
        //solium-disable-next-line
        uint256 cooldownStartTimestamp = stakersCooldowns[msg.sender];
        require(
            block.timestamp > cooldownStartTimestamp.add(COOLDOWN_SECONDS),
            "INSUFFICIENT_COOLDOWN"
        );
        require(
            block.timestamp.sub(cooldownStartTimestamp.add(COOLDOWN_SECONDS)) <=
                UNSTAKE_WINDOW,
            "UNSTAKE_WINDOW_FINISHED"
        );
        uint256 balanceOfMessageSender = balanceOf(msg.sender);

        uint256 amountToRedeem = (amount > balanceOfMessageSender)
            ? balanceOfMessageSender
            : amount;

        _updateCurrentUnclaimedRewards(
            msg.sender,
            balanceOfMessageSender,
            true
        );

        _burn(msg.sender, amountToRedeem);

        if (balanceOfMessageSender.sub(amountToRedeem) == 0) {
            stakersCooldowns[msg.sender] = 0;
        }

        IERC20(STAKED_TOKEN).safeTransfer(to, amountToRedeem);

        delete stakersLockEndTimestamp[msg.sender];

        emit Redeem(msg.sender, to, amountToRedeem);
    }

    /**
     * @dev Activates the cooldown period to unstake
     * - It can't be called if the user is not staking
     **/
    function cooldown() external override {
        require(balanceOf(msg.sender) != 0, "INVALID_BALANCE_ON_COOLDOWN");
        //solium-disable-next-line
        stakersCooldowns[msg.sender] = block.timestamp;

        emit Cooldown(msg.sender);
    }

    /**
     * @dev Claims an `amount` of `REWARD_TOKEN` to the address `to`
     * @param to Address to stake for
     * @param amount Amount to stake
     **/
    function claimRewards(address to, uint256 amount) external override {
        uint256 newTotalRewards = _updateCurrentUnclaimedRewards(
            msg.sender,
            balanceOf(msg.sender),
            false
        );
        uint256 amountToClaim = (amount == type(uint256).max)
            ? newTotalRewards
            : amount;

        stakerRewardsToClaim[msg.sender] = newTotalRewards.sub(
            amountToClaim,
            "INVALID_AMOUNT"
        );

        REWARD_TOKEN.safeTransferFrom(REWARDS_VAULT, to, amountToClaim);

        emit RewardsClaimed(msg.sender, to, amountToClaim);
    }

    /**
     * @dev Internal ERC20 _transfer of the tokenized staked tokens
     * @param from Address to transfer from
     * @param to Address to transfer to
     * @param amount Amount to transfer
     **/
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        uint256 balanceOfFrom = balanceOf(from);
        // Sender
        _updateCurrentUnclaimedRewards(from, balanceOfFrom, true);
        // Recipient
        if (from != to) {
            uint256 balanceOfTo = balanceOf(to);
            _updateCurrentUnclaimedRewards(to, balanceOfTo, true);

            uint256 previousSenderCooldown = stakersCooldowns[from];
            stakersCooldowns[to] = getNextCooldownTimestamp(
                previousSenderCooldown,
                amount,
                to,
                balanceOfTo
            );
            // if cooldown was set and whole balance of sender was transferred - clear cooldown
            if (balanceOfFrom == amount && previousSenderCooldown != 0) {
                stakersCooldowns[from] = 0;
            }
        }

        super._transfer(from, to, amount);
    }

    /**
     * @dev Updates the user state related with his accrued rewards
     * @param user Address of the user
     * @param userBalance The current balance of the user
     * @param updateStorage Boolean flag used to update or not the stakerRewardsToClaim of the user
     * @return The unclaimed rewards that were added to the total accrued
     **/
    function _updateCurrentUnclaimedRewards(
        address user,
        uint256 userBalance,
        bool updateStorage
    ) internal returns (uint256) {
        uint256 accruedRewards = _updateUserAssetInternal(
            user,
            address(this),
            userBalance,
            currentSupply
        );
        uint256 unclaimedRewards = stakerRewardsToClaim[user].add(
            accruedRewards
        );

        if (accruedRewards != 0) {
            if (updateStorage) {
                stakerRewardsToClaim[user] = unclaimedRewards;
            }
            emit RewardsAccrued(user, accruedRewards);
        }

        return unclaimedRewards;
    }

    // rewrite some functions
    function _getEmissionPerSecond(uint256 userCount)
        internal
        pure
        returns (uint128)
    {
        // return 1;
        // formula: y = (Ax)/(Bx^2+C) + D
        uint256 A = 10000; // 1800000
        uint256 B = 1; // 
        uint256 C = 5000; // 1000000
        uint256 D = 5; // 100
        uint256 numerator = userCount.mul(A);
        uint256 denominator = (B.mul(userCount).mul(userCount)).add(C);
        uint256 emissionPerSecond = (numerator.div(denominator)).add(D);

        return uint128(emissionPerSecond);
    }

    function _updateAssetStateInternal(
        address underlyingAsset,
        AssetData storage assetConfig,
        uint256 totalStaked
    ) internal override returns (uint256) {
        uint256 oldIndex = assetConfig.index;
        uint128 lastUpdateTimestamp = assetConfig.lastUpdateTimestamp;

        if (block.timestamp == lastUpdateTimestamp) {
            return oldIndex;
        }

        // update emission/second
        assetConfig.emissionPerSecond = _getEmissionPerSecond(userCount);

        // update asset index, usercount, current supply with timestamp
        uint256 i;
        for (i = timestampsStartIndex; i < stakeEndTimestamps.length; i++) {
            if (stakeEndTimestamps[i] <= block.timestamp) {
                indexAtTimestamp[
                    stakeEndTimestamps[i]
                ] = _getAssetIndexWithTimestamp(
                    oldIndex,
                    assetConfig.emissionPerSecond,
                    lastUpdateTimestamp,
                    totalStaked,
                    stakeEndTimestamps[i]
                );

                userCount = userCount.sub(1);
                currentSupply = currentSupply.sub(
                    subSupplyAtTimestamp[stakeEndTimestamps[i]]
                );
            } else {
                break;
            }
        }
        timestampsStartIndex = i;

        uint256 newIndex = _getAssetIndex(
            oldIndex,
            assetConfig.emissionPerSecond,
            lastUpdateTimestamp,
            currentSupply
        );

        if (newIndex != oldIndex) {
            assetConfig.index = newIndex;
            emit AssetIndexUpdated(underlyingAsset, newIndex);
        }

        assetConfig.lastUpdateTimestamp = uint128(block.timestamp);

        return newIndex;
    }

    function _getAssetIndexWithTimestamp(
        uint256 currentIndex,
        uint256 emissionPerSecond,
        uint128 lastUpdateTimestamp,
        uint256 totalBalance,
        uint256 timestamp
    ) internal view returns (uint256) {
        if (
            emissionPerSecond == 0 ||
            totalBalance == 0 ||
            lastUpdateTimestamp == timestamp ||
            lastUpdateTimestamp >= DISTRIBUTION_END
        ) {
            return currentIndex;
        }
        uint256 currentTimestamp = timestamp > DISTRIBUTION_END
            ? DISTRIBUTION_END
            : timestamp;
        uint256 timeDelta = currentTimestamp.sub(lastUpdateTimestamp);
        return
            emissionPerSecond
                .mul(timeDelta)
                .mul(10**uint256(PRECISION))
                .div(totalBalance)
                .add(currentIndex);
    }

    function _updateUserAssetInternal(
        address user,
        address asset,
        uint256 stakedByUser,
        uint256 totalStaked
    ) internal override returns (uint256) {
        AssetData storage assetData = assets[asset];
        uint256 userIndex = assetData.users[user];
        uint256 accruedRewards = 0;

        uint256 newIndex = _updateAssetStateInternal(
            asset,
            assetData,
            totalStaked
        );
        if (
            stakersLockEndTimestamp[user] != 0 &&
            stakersLockEndTimestamp[user] <= block.timestamp
        ) {
            newIndex = indexAtTimestamp[stakersLockEndTimestamp[user]];
        }

        if (userIndex != newIndex) {
            if (stakedByUser != 0) {
                accruedRewards = _getRewards(stakedByUser, newIndex, userIndex);
            }

            assetData.users[user] = newIndex;
            emit UserIndexUpdated(user, asset, newIndex);
        }

        return accruedRewards;
    }

    /**
     * @dev Calculates the how is gonna be a new cooldown timestamp depending on the sender/receiver situation
     *  - If the timestamp of the sender is "better" or the timestamp of the recipient is 0, we take the one of the recipient
     *  - Weighted average of from/to cooldown timestamps if:
     *    # The sender doesn't have the cooldown activated (timestamp 0).
     *    # The sender timestamp is expired
     *    # The sender has a "worse" timestamp
     *  - If the receiver's cooldown timestamp expired (too old), the next is 0
     * @param fromCooldownTimestamp Cooldown timestamp of the sender
     * @param amountToReceive Amount
     * @param toAddress Address of the recipient
     * @param toBalance Current balance of the receiver
     * @return The new cooldown timestamp
     **/
    function getNextCooldownTimestamp(
        uint256 fromCooldownTimestamp,
        uint256 amountToReceive,
        address toAddress,
        uint256 toBalance
    ) public view returns (uint256) {
        uint256 toCooldownTimestamp = stakersCooldowns[toAddress];
        if (toCooldownTimestamp == 0) {
            return 0;
        }

        uint256 minimalValidCooldownTimestamp = block
            .timestamp
            .sub(COOLDOWN_SECONDS)
            .sub(UNSTAKE_WINDOW);

        if (minimalValidCooldownTimestamp > toCooldownTimestamp) {
            toCooldownTimestamp = 0;
        } else {
            uint256 fromCooldownTimestamp = (minimalValidCooldownTimestamp >
                fromCooldownTimestamp)
                ? block.timestamp
                : fromCooldownTimestamp;

            if (fromCooldownTimestamp < toCooldownTimestamp) {
                return toCooldownTimestamp;
            } else {
                toCooldownTimestamp = (
                    amountToReceive.mul(fromCooldownTimestamp).add(
                        toBalance.mul(toCooldownTimestamp)
                    )
                ).div(amountToReceive.add(toBalance));
            }
        }
        return toCooldownTimestamp;
    }

    /**
     * @dev Return the total rewards pending to claim by an staker
     * @param staker The staker address
     * @return The rewards
     */
    function getTotalRewardsBalance(address staker)
        external
        view
        returns (uint256)
    {
        AssetData storage assetConfig = assets[address(this)];
        uint256 assetIndex = indexAtTimestamp[
            stakersLockEndTimestamp[staker]
        ] != 0
            ? indexAtTimestamp[stakersLockEndTimestamp[staker]]
            : _getAssetIndexWithTimestamp(
                assetConfig.index,
                assetConfig.emissionPerSecond,
                assetConfig.lastUpdateTimestamp,
                currentSupply,
                block.timestamp <= stakersLockEndTimestamp[staker]
                    ? block.timestamp
                    : stakersLockEndTimestamp[staker]
            );
        uint256 accruedRewards = _getRewards(
            balanceOf(staker),
            assetIndex,
            assetConfig.users[staker]
        );
        return stakerRewardsToClaim[staker].add(accruedRewards);
    }

    /**
     * @dev returns the revision of the implementation contract
     * @return The revision
     */
    function getRevision() internal pure override returns (uint256) {
        return REVISION;
    }

    function getUserLockEndTimestamp(address user)
        public
        view
        returns (uint256)
    {
        return stakersLockEndTimestamp[user];
    }

    function getAssetEmissionPerSecond() public view returns (uint256) {
        return assets[address(this)].emissionPerSecond;
    }
}
