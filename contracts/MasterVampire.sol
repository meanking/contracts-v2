// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./libraries/UniswapV2Library.sol";
import "./Timelock.sol";
import "./VampireAdapter.sol";
import "./DraculaToken.sol";

contract MasterVampire is Ownable, Timelock, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using VampireAdapter for Victim;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 coolOffTime;
    }

    struct PoolInfo {
        Victim victim;
        uint256 victimPoolId;
        uint256 lastRewardBlock;
        uint256 accWethPerShare;
        uint256 wethAccumulator;
        uint256 wethDrainModifier;
    }

//     (_                   _)
//      /\                 /\
//     / \'._   (\_/)   _.'/ \
//    /_.''._'--('.')--'_.''._\
//    | \_ / `;=/ " \=;` \ _/ |
//     \/ `\__|`\___/`|__/`  \/
//   jgs`      \(/|\)/       `
//              " ` "
    DraculaToken public dracula;
    IERC20 constant weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniswapV2Pair drcWethPair;

    address public drainController;
    address public drainAddress;
    address public poolRewardUpdater;
    address public devAddress;
    uint256 public drcWethShare = 30;
    uint256 public distributionPeriod = 6519;
    uint256 public withdrawalPenalty = 10;
    uint256 public constant DEV_FEE = 8;
    uint256 public constant REWARD_START_BLOCK = 11008888; // Wed Oct 07 2020 13:28:00 UTC

    PoolInfo[] public poolInfo;

    mapping (uint256 => mapping (address => UserInfo)) public userInfo;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    modifier onlyDev() {
        require(devAddress == _msgSender(), "not dev");
        _;
    }

    modifier onlyRewardUpdater() {
        require(poolRewardUpdater == _msgSender(), "not reward updater");
        _;
    }

    constructor(
        DraculaToken _dracula,
        address _drainAddress
    ) public Timelock(msg.sender, 24 hours) {
        dracula = _dracula;
        drainAddress = _drainAddress;
        devAddress = msg.sender;
        poolRewardUpdater = msg.sender;
        IUniswapV2Factory uniswapFactory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
        drcWethPair = IUniswapV2Pair(uniswapFactory.getPair(address(weth), address(dracula)));
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function add(Victim _victim, uint256 _victimPoolId, uint256 _wethDrainModifier) external onlyOwner {
        poolInfo.push(PoolInfo({
            victim: _victim,
            victimPoolId: _victimPoolId,
            wethDrainModifier: _wethDrainModifier,
            lastRewardBlock: block.number < REWARD_START_BLOCK ? REWARD_START_BLOCK : block.number,
            accWethPerShare: 0,
            wethAccumulator: 0
        }));
    }

    function updateDistributionPeriod(uint256 _distributionPeriod) external onlyRewardUpdater {
        distributionPeriod = _distributionPeriod;
    }

    function updateDrcWethRewardShare(uint256 _drcWethShare) external onlyRewardUpdater {
        drcWethShare = _drcWethShare;
    }

    function updateWithdrawPenalty(uint256 _withdrawalPenalty) external onlyRewardUpdater {
        withdrawalPenalty = _withdrawalPenalty;
    }

    function updateVictimInfo(uint256 _pid, address _victim, uint256 _victimPoolId) external onlyOwner {
        poolInfo[_pid].victim = Victim(_victim);
        poolInfo[_pid].victimPoolId = _victimPoolId;
    }

    function updatePoolDrain(uint256 _pid, uint256 _wethDrainModifier) external onlyOwner {
        PoolInfo storage pool = poolInfo[_pid];
        pool.wethDrainModifier = _wethDrainModifier;
    }

    function updateDevAddress(address _devAddress) external onlyDev {
        devAddress = _devAddress;
    }

    function updateDrainAddress(address _drainAddress) external onlyOwner {
        drainAddress = _drainAddress;
    }

    function updateDrainController(address _drainController) external onlyOwner {
        drainController = _drainController;
    }

    function updateRewardUpdaterAddress(address _poolRewardUpdater) external onlyOwner {
        poolRewardUpdater = _poolRewardUpdater;
    }

    function pendingWeth(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accWethPerShare = pool.accWethPerShare;
        uint256 lpSupply = _pid == 0 ? drcWethPair.balanceOf(address(this)) : pool.victim.lockedAmount(pool.victimPoolId);
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 blocksToReward = block.number.sub(pool.lastRewardBlock);
            uint256 wethReward = blocksToReward.mul(pool.wethAccumulator).div(distributionPeriod);
            accWethPerShare = accWethPerShare.add(wethReward.mul(1e12).div(lpSupply));
        }

        return user.amount.mul(accWethPerShare).div(1e12).sub(user.rewardDebt);
    }

    function poolAccWeth(uint256 pid) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        return pool.wethAccumulator;
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint256 pid) public {
        PoolInfo storage pool = poolInfo[pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        uint256 lpSupply = pid == 0 ? drcWethPair.balanceOf(address(this)) : pool.victim.lockedAmount(pool.victimPoolId);
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 blocksToReward = block.number.sub(pool.lastRewardBlock);
        uint256 wethReward = blocksToReward.mul(pool.wethAccumulator).div(distributionPeriod);
        pool.accWethPerShare = pool.accWethPerShare.add(wethReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
        pool.wethAccumulator = pool.wethAccumulator.sub(wethReward);
    }

    function deposit(uint256 pid, uint256 amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];
        user.coolOffTime = block.timestamp + 24 hours;

        updatePool(pid);
        if (user.amount > 0) {
            _claim(pid);
        }

        if (amount > 0) {
            if (pid == 0) {
                IERC20(address(drcWethPair)).safeTransferFrom(address(msg.sender), address(this), amount);
            } else {
                pool.victim.lockableToken(pool.victimPoolId).safeTransferFrom(address(msg.sender), address(this), amount);
                pool.victim.deposit(pool.victimPoolId, amount);
            }

            user.amount = user.amount.add(amount);
        }

        user.rewardDebt = user.amount.mul(pool.accWethPerShare).div(1e12);
        emit Deposit(msg.sender, pid, amount);
    }

    function withdraw(uint256 pid, uint256 amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];
        require(user.amount >= amount, "withdraw: not good");
        updatePool(pid);
        _claim(pid);

        if (amount > 0) {
            user.amount = user.amount.sub(amount);
            if (pid == 0) {
                IERC20(address(drcWethPair)).safeTransfer(address(msg.sender), amount);
            } else {
                pool.victim.withdraw(pool.victimPoolId, amount);
                pool.victim.lockableToken(pool.victimPoolId).safeTransfer(address(msg.sender), amount);
            }
        }

        user.rewardDebt = user.amount.mul(pool.accWethPerShare).div(1e12);
        emit Withdraw(msg.sender, pid, amount);
    }

    function claim(uint256 pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];
        updatePool(pid);
        _claim(pid);
        user.rewardDebt = user.amount.mul(pool.accWethPerShare).div(1e12);
    }

    function emergencyWithdraw(uint256 pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];
        if (pid == 0) {
            IERC20(address(drcWethPair)).safeTransfer(address(msg.sender), user.amount);
        } else {
            pool.victim.withdraw(pool.victimPoolId, user.amount);
            pool.victim.lockableToken(pool.victimPoolId).safeTransfer(address(msg.sender), user.amount);
        }
        emit EmergencyWithdraw(msg.sender, pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    function drain(uint256 pid) external {
        require(pid != 0, "Can't drain from myself");
        require(drainController == _msgSender(), "not drainctrl");
        PoolInfo storage pool = poolInfo[pid];
        Victim victim = pool.victim;
        uint256 victimPoolId = pool.victimPoolId;
        victim.claimReward(victimPoolId);
        IERC20 rewardToken = victim.rewardToken();
        uint256 claimedReward = rewardToken.balanceOf(address(this));

        if (claimedReward == 0) {
            return;
        }

        uint256 wethReward = victim.sellRewardForWeth(claimedReward, address(this));
        uint256 wethDrainAmount = wethReward.mul(pool.wethDrainModifier).div(1000);
        if (wethDrainAmount > 0) {
            require(drcWethShare < pool.wethDrainModifier, "drcWethShare !< wethDrainModifier");
            weth.transfer(drainAddress, wethDrainAmount);
            wethReward = wethReward.sub(wethDrainAmount);
        }

        PoolInfo storage drcWethPool = poolInfo[0];
        uint256 drcWethPoolAmount = wethReward.mul(drcWethShare).div(1000);
        drcWethPool.wethAccumulator = drcWethPool.wethAccumulator.add(drcWethPoolAmount);
        wethReward = wethReward.sub(drcWethPoolAmount);

        pool.wethAccumulator = pool.wethAccumulator.add(wethReward);
    }

    /// Claim rewards from pool
    function _claim(uint256 pid) internal {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 pending = user.amount.mul(pool.accWethPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            if (withdrawalPenalty > 0 && block.timestamp < user.coolOffTime) {
                uint256 fee = pending.mul(withdrawalPenalty).div(1000);
                pending = pending.sub(fee);
                pool.wethAccumulator = pool.wethAccumulator.add(fee);
            }
            _safeWethTransfer(msg.sender, pending);
        }
    }

    function _safeWethTransfer(address to, uint256 amount) internal {
        uint256 balance = weth.balanceOf(address(this));
        if (amount > balance) {
            weth.transfer(to, balance);
        } else {
            weth.transfer(to, amount);
        }
    }
}
