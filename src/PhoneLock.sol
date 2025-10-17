// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {PriceConverterLib} from "./libraries/PriceConverterLib.sol";

contract PhoneLock is Ownable, ReentrancyGuard {
    /* errors */
    error PhoneLock__StakeAmountShouldBeGreaterThanZero();
    error PhoneLock__StakeAmountLessThanMinimum();

    error PhoneLock__InvalidStartTime();
    error PhoneLock__InvalidDuration();
    error PhoneLock__LockNotActive();
    error PhoneLock__LockDoesNotBelongToUser();
    error PhoneLock__LockAlreadyExistsInPool();

    error PhoneLock__PoolIsFinalized();
    error PhoneLock__PoolNotFinalized();
    error PhoneLock__InvalidRoot();

    error PhoneLock__StakeRefundTransferFailed();
    error PhoneLock__ProtocolFeeWithdrawTransferFailed();

    error PhoneLock__NoLockFound();
    error PhoneLock__AlreadyClaimed();
    error PhoneLock__InvalidSignature();
    error PhoneLock__InvalidProof();
    error PhoneLock__MustBeWinnerToClaimReward();

    /* Type declarations */
    using PriceConverterLib for uint256;

    struct Pool {
        bytes32 rewardMerkleRoot;
        bool isFinalized;
        uint256 totalStakedAmount;
        uint256 usersCount;
    }

    struct Lock {
        address user;
        uint8 period;
        uint256 day;
        uint256 stakeAmount;
        uint256 startTime;
        uint256 duration;
        uint256 endTime;
        uint256 lockId;
        Status status;
    }

    enum Status {
        None,
        Active,
        Completed
    }

    /* State variables */
    uint256 private constant MINIMUM_STAKE_AMOUNT_IN_USD = 1 * 1e18; // 1 USD expressed with 18 decimals

    address private s_verifierSigner;
    uint256 private s_lockId;
    uint256 private s_protocolFee;

    AggregatorV3Interface private s_priceFeed; // Chainlink price feed for ETH/USD

    // Day -> Period(AM/PM) -> Pool mapping
    mapping(uint256 day => mapping(uint8 period => Pool)) private s_pools;

    // User Address -> Lock ID -> Lock mapping
    mapping(address user => mapping(uint256 lockId => Lock)) private s_userLocks;

    // User Address -> Lock ID -> Claim status mapping
    mapping(address user => mapping(uint256 lockId => bool)) private s_userHasClaimedRewards;

    // User Address -> Day -> Period(AM/PM) -> Occupancy flag (true if user has a lock in this pool)
    mapping(address user => mapping(uint256 day => mapping(uint8 period => bool))) private s_userHasLockInPool;

    /* Events */
    event LockSet(
        address indexed user, uint256 startTime, uint256 indexed duration, uint256 indexed stakeAmount, uint256 lockId
    );
    event LockRewardsClaimed(
        address indexed user, uint256 indexed lockId, bool completed, uint256 indexed totalAmountPaid
    );
    event PoolIsFinalized(uint256 indexed day, uint8 indexed period);
    event StakeRefunded(address indexed user, uint256 stakeAmount);
    event ProtocolFeeUpdated(uint256 indexed protocolFee);
    event ProtocolFeeWithdrawn(uint256 indexed protocolFee);

    /* Modifiers */

    /* constructor */
    constructor(address _priceFeed, address _verifierSigner) Ownable(msg.sender) {
        s_priceFeed = AggregatorV3Interface(_priceFeed);
        s_verifierSigner = _verifierSigner;
        s_lockId = 1; // reserve 0 for NO LOCK
        s_protocolFee = 0;
    }

    /* external */
    function setPhoneLock(uint256 _startTime, uint256 _duration) external payable nonReentrant {
        if (msg.value <= 0) {
            revert PhoneLock__StakeAmountShouldBeGreaterThanZero();
        }
        if (msg.value.getUsdValue(address(s_priceFeed)) < MINIMUM_STAKE_AMOUNT_IN_USD) {
            revert PhoneLock__StakeAmountLessThanMinimum();
        }
        if (_startTime < block.timestamp) {
            revert PhoneLock__InvalidStartTime();
        }
        if (_duration == 0) {
            revert PhoneLock__InvalidDuration();
        }

        (uint256 day, uint8 period) = _calculateDayAndPeriod(_startTime);

        // Check if the pool is already finalized.
        if (s_pools[day][period].isFinalized) {
            revert PhoneLock__PoolIsFinalized();
        }

        // Revert if a lock already exists for this user in this specific pool.
        if (s_userHasLockInPool[msg.sender][day][period]) {
            revert PhoneLock__LockAlreadyExistsInPool();
        }

        uint256 lockId = s_lockId;
        uint256 endTime = _startTime + _duration;

        s_userLocks[msg.sender][lockId] = Lock({
            user: msg.sender,
            period: period,
            day: day,
            stakeAmount: msg.value,
            startTime: _startTime,
            duration: _duration,
            endTime: endTime,
            lockId: lockId,
            status: Status.Active
        });

        s_userHasLockInPool[msg.sender][day][period] = true;

        // Update the lockId, usersCount, and totalStakedAmount for the pool
        s_lockId++;
        s_pools[day][period].usersCount++;
        s_pools[day][period].totalStakedAmount += msg.value;

        emit LockSet(msg.sender, _startTime, _duration, msg.value, lockId);
    }

    function claimLockRewards(
        uint256 _lockId,
        bool _completed,
        bytes calldata _signature,
        uint256 _rewardAmount,
        bytes32[] calldata _merkleProof
    ) external nonReentrant {
        Lock storage lockData = s_userLocks[msg.sender][_lockId];

        // Validate claim preconditions
        _validateClaimPreconditions(lockData);

        // Verify signed outcome from backend (user, startTime, duration, completed)
        _verifyOutcomeSignature(lockData.startTime, lockData.duration, _completed, _signature);

        // Verify reward claim if the user completed successfully
        if (_completed) {
            _verifyRewardClaim(lockData.day, lockData.period, _rewardAmount, _merkleProof);
        } else {
            if (_rewardAmount != 0) revert PhoneLock__MustBeWinnerToClaimReward();
        }

        // Calculate stake return
        uint256 amountToReturn = _calculateStakeReturn(lockData.stakeAmount, _completed);

        // Mark claimed and finish lock lifecycle
        s_userHasClaimedRewards[msg.sender][_lockId] = true;
        lockData.status = Status.Completed;

        uint256 totalPayout = amountToReturn + _rewardAmount;
        if (totalPayout > 0) {
            (bool sent,) = msg.sender.call{value: totalPayout}("");
            if (!sent) revert PhoneLock__StakeRefundTransferFailed();
        }

        emit StakeRefunded(msg.sender, amountToReturn);
        emit LockRewardsClaimed(msg.sender, lockData.lockId, _completed, totalPayout);
    }

    function setMerkleRootForPool(uint256 _day, uint8 _period, bytes32 _merkleRoot) external onlyOwner nonReentrant {
        if (s_pools[_day][_period].isFinalized) revert PhoneLock__PoolIsFinalized();
        if (_merkleRoot == bytes32(0)) revert PhoneLock__InvalidRoot();

        s_pools[_day][_period].rewardMerkleRoot = _merkleRoot;
        s_pools[_day][_period].isFinalized = true;

        emit PoolIsFinalized(_day, _period);
    }

    function withdrawProtocolFee() external onlyOwner nonReentrant {
        uint256 protocolFee = s_protocolFee;
        s_protocolFee = 0;
        (bool success,) = msg.sender.call{value: protocolFee}("");
        if (!success) {
            revert PhoneLock__ProtocolFeeWithdrawTransferFailed();
        }
        emit ProtocolFeeWithdrawn(protocolFee);
    }

    /* internal & private view & pure functions */
    function _calculateDayAndPeriod(uint256 _timestamp) internal pure returns (uint256 day, uint8 period) {
        day = _timestamp / 1 days;
        period = uint8((_timestamp % 1 days) / 12 hours);
    }

    function _verifyOutcomeSignature(uint256 _startTime, uint256 _duration, bool _completed, bytes calldata _signature)
        private
        view
    {
        bytes32 messageHash =
            keccak256(abi.encodePacked(keccak256(abi.encodePacked(msg.sender, _startTime, _duration, _completed))));
        address signer = ECDSA.recover(messageHash, _signature);
        if (signer != s_verifierSigner) revert PhoneLock__InvalidSignature();
    }

    function _verifyRewardClaim(uint256 _day, uint8 _period, uint256 _rewardAmount, bytes32[] calldata _merkleProof)
        private
        view
    {
        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(msg.sender, _rewardAmount))));
        bytes32 root = s_pools[_day][_period].rewardMerkleRoot;
        if (!MerkleProof.verify(_merkleProof, root, leaf)) revert PhoneLock__InvalidProof();
    }

        function _validateClaimPreconditions(Lock memory lock) private view {
        // Preconditions for claiming winnings
        //   -> Phone Lock must EXIST
        //   -> Phone Lock must BELONG to the user
        //   -> Phone Lock must BE ACTIVE
        //   -> Phone Lock must NOT HAVE BEEN CLAIMED
        //   -> Pool must BE FINALIZED

        if (lock.status == Status.None) revert PhoneLock__NoLockFound();
        if (lock.user != msg.sender) revert PhoneLock__LockDoesNotBelongToUser();
        if (lock.status != Status.Active) revert PhoneLock__LockNotActive();
        if (!s_pools[lock.day][lock.period].isFinalized) revert PhoneLock__PoolNotFinalized();
        if (s_userHasClaimedRewards[msg.sender][lock.lockId]) revert PhoneLock__AlreadyClaimed();
    }

    function _calculateStakeReturn(uint256 _stake, bool _completed) private pure returns (uint256) {
        if (_completed) {
            return _stake;
        } else {
            return 0;
        }
    }

    /* external & public view & pure functions */
    function getLock(address _user, uint256 _lockId) external view returns (Lock memory) {
        return s_userLocks[_user][_lockId];
    }

    function getPool(uint256 _day, uint8 _period) external view returns (Pool memory) {
        return s_pools[_day][_period];
    }

    function getProtocolFee() external view onlyOwner returns (uint256) {
        return s_protocolFee;
    }

    function getVerifierSigner() external view returns (address) {
        return s_verifierSigner;
    }

    function getHasClaimed(address _user, uint256 _lockId) external view returns (bool) {
        return s_userHasClaimedRewards[_user][_lockId];
    }

    function getHasLockInPool(address _user, uint256 _day, uint8 _period) external view returns (bool) {
        return s_userHasLockInPool[_user][_day][_period];
    }

    function getNextLockId() external view returns (uint256) {
        return s_lockId;
    }

    function getPriceFeed() external view returns (address) {
        return address(s_priceFeed);
    }

    function getMinimumStakeUsd() external pure returns (uint256) {
        return MINIMUM_STAKE_AMOUNT_IN_USD;
    }
}
