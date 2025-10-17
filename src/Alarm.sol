// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {PriceConverterLib} from "./libraries/PriceConverterLib.sol";

contract AlarmContract is Ownable, ReentrancyGuard {
    /* errors */
    error AlarmContract__StakeAmountShouldBeGreaterThanZero();
    error AlarmContract__StakeAmountLessThanMinimum();

    error AlarmContract__InvalidWakeUpTime();
    error AlarmContract__AlarmNotActive();
    error AlarmContract__AlarmDoesNotBelongToUser();
    error AlarmContract__AlarmAlreadyExistsInPool();

    error AlarmContract__PoolIsFinalized();
    error AlarmContract__PoolNotFinalized();
    error AlarmContract__InvalidRoot();

    error AlarmContract__StakeRefundTransferFailed();
    error AlarmContract__ProtocolFeeWithdrawTransferFailed();

    error AlarmContract__NoAlarmFound();
    error AlarmContract__AlreadyClaimed();
    error AlarmContract__AlarmDeleted();
    error AlarmContract__InvalidSignature();
    error AlarmContract__InvalidProof();
    error AlarmContract__MustBeWinnerToClaimReward();

    /* Type declarations */
    using PriceConverterLib for uint256;

    struct Pool {
        bytes32 rewardMerkleRoot;
        bool isFinalized;
        uint256 totalStakedAmount;
        uint256 usersCount;
    }

    struct Alarm {
        address user;
        uint8 period;
        uint256 day;
        uint256 stakeAmount;
        uint256 wakeUpTime;
        uint256 alarmId;
        Status status;
    }

    enum Status {
        None,
        Active,
        Completed,
        Deleted
    }

    /* State variables */
    uint256 private constant MINIMUM_STAKE_AMOUNT_IN_USD = 1 * 1e18; // 1 USD expressed with 18 decimals
    uint256 private constant SLASH_TWENTY = 20;
    uint256 private constant SLASH_FIFTY = 50;
    uint256 private constant SLASH_EIGHTY = 80;
    uint256 private constant PERCENTAGE_DIVISION_PRECISION = 100;

    address private s_verifierSigner;
    uint256 private s_alarmId;
    uint256 private s_protocolFee;

    AggregatorV3Interface private s_priceFeed; // Chainlink price feed for ETH/USD

    // Day -> Period(AM/PM) -> Pool mapping
    mapping(uint256 day => mapping(uint8 period => Pool)) private s_pools;

    // User Address -> Alarm ID -> Alarm mapping
    mapping(address user => mapping(uint256 alarmId => Alarm)) private s_userAlarms;

    // User Address -> Alarm ID -> Claim status mapping
    mapping(address user => mapping(uint256 alarmId => bool)) private s_userHasClaimedWinnings;

    // User Address -> Day -> Period(AM/PM) -> Occupancy flag (true if user has an alarm in this pool)
    mapping(address user => mapping(uint256 day => mapping(uint8 period => bool))) private s_userHasAlarmInPool;

    /* Events */
    event AlarmSet(address indexed user, uint256 wakeUpTime, uint256 indexed stakeAmount, uint256 indexed alarmId);
    event AlarmEdited(address indexed user, uint256 indexed newWakeUpTime, uint256 indexed newStakeAmount);
    event AlarmDeleted(address indexed user, uint256 wakeUpTime, uint256 indexed stakeAmount);
    event WinningsClaimed(
        address indexed user, uint256 indexed alarmId, uint8 snoozeCount, uint256 indexed totalAmountPaid
    );
    event PoolIsFinalized(uint256 indexed day, uint8 indexed period);
    event StakeRefunded(address indexed user, uint256 stakeAmount);
    event ProtocolFeeUpdated(uint256 indexed protocolFee);
    event ProtocolFeeWithdrawn(uint256 indexed protocolFee);

    /* Modifiers */
    modifier amountIsValid(uint256 amount) {
        _amountIsValid(amount);
        _;
    }

    modifier validWakeUpTime(uint256 wakeUpTime) {
        _wakeUpTimeInFuture(wakeUpTime);
        _;
    }

    /* constructor */
    constructor(address _priceFeed, address _verifierSigner) Ownable(msg.sender) {
        s_priceFeed = AggregatorV3Interface(_priceFeed);
        s_verifierSigner = _verifierSigner;
        s_alarmId = 1; // reserve 0 for NO ALARM
        s_protocolFee = 0;
    }

    /* receive function (if exists) */
    /* fallback function (if exists) */

    /* external */
    function setAlarm(uint256 _wakeUpTime)
        external
        payable
        nonReentrant
        amountIsValid(msg.value)
        validWakeUpTime(_wakeUpTime)
    {
        (uint256 day, uint8 period) = _calculateDayAndPeriod(_wakeUpTime);

        // Check if the pool is already finalized.
        if (s_pools[day][period].isFinalized) {
            revert AlarmContract__PoolIsFinalized();
        }

        // Revert if an alarm already exists for this user in this specific pool.
        if (s_userHasAlarmInPool[msg.sender][day][period]) {
            revert AlarmContract__AlarmAlreadyExistsInPool();
        }

        uint256 alarmId = s_alarmId;

        s_userAlarms[msg.sender][alarmId] = Alarm({
            user: msg.sender,
            period: period,
            day: day,
            stakeAmount: msg.value,
            wakeUpTime: _wakeUpTime,
            alarmId: alarmId,
            status: Status.Active
        });

        s_userHasAlarmInPool[msg.sender][day][period] = true;

        // Update the alarmId, usersCount, and totalStakedAmount for the pool
        s_alarmId++;
        s_pools[day][period].usersCount++;
        s_pools[day][period].totalStakedAmount += msg.value;

        emit AlarmSet(msg.sender, _wakeUpTime, msg.value, alarmId);
    }

    function editAlarm(uint256 alarmId, uint256 newWakeUpTime)
        external
        payable
        nonReentrant
        amountIsValid(msg.value)
        validWakeUpTime(newWakeUpTime)
    {
        Alarm storage oldAlarm = s_userAlarms[msg.sender][alarmId];
        // Validate if the alarm can be edited.
        _validateIfAlarmCanBeEditedOrDeleted(oldAlarm);

        (uint256 newDay, uint8 newPeriod) = _calculateDayAndPeriod(newWakeUpTime);

        // Check if the new pool is already finalized
        if (s_pools[newDay][newPeriod].isFinalized) {
            revert AlarmContract__PoolIsFinalized();
        }

        // If moving pools, ensure user has no alarm there
        if (
            (newDay != oldAlarm.day || newPeriod != oldAlarm.period)
                && s_userHasAlarmInPool[msg.sender][newDay][newPeriod]
        ) {
            revert AlarmContract__AlarmAlreadyExistsInPool();
        }

        uint256 oldStakeAmount = oldAlarm.stakeAmount;

        // Calculate the 20% slashed stake amount & the return stake amount
        uint256 slashedStakeAmount = (oldStakeAmount * SLASH_TWENTY) / PERCENTAGE_DIVISION_PRECISION;
        uint256 returnStakeAmount = oldStakeAmount - slashedStakeAmount;

        s_protocolFee += slashedStakeAmount;

        if (newDay == oldAlarm.day && newPeriod == oldAlarm.period) {
            _editSamePool(oldAlarm, newWakeUpTime, msg.value);
        } else {
            _moveToNewPool(oldAlarm, newDay, newPeriod, newWakeUpTime, msg.value);
        }

        // Refund the slashed stake amount
        (bool success,) = msg.sender.call{value: returnStakeAmount}("");
        if (!success) {
            revert AlarmContract__StakeRefundTransferFailed();
        }

        emit ProtocolFeeUpdated(s_protocolFee);
        emit StakeRefunded(msg.sender, returnStakeAmount);
        emit AlarmEdited(msg.sender, newWakeUpTime, msg.value);
    }

    function deleteAlarm(uint256 _alarmId) external nonReentrant {
        Alarm storage alarm = s_userAlarms[msg.sender][_alarmId];
        // Validate if the alarm can be deleted
        _validateIfAlarmCanBeEditedOrDeleted(alarm);

        uint256 day = alarm.day;
        uint8 period = alarm.period;

        uint256 oldStakeAmount = alarm.stakeAmount;
        uint256 oldWakeUpTime = alarm.wakeUpTime;
        uint256 slashedStakeAmount = (oldStakeAmount * SLASH_FIFTY) / PERCENTAGE_DIVISION_PRECISION;
        uint256 returnStakeAmount = oldStakeAmount - slashedStakeAmount;

        // Update protocol fee with slashed amount
        s_protocolFee += slashedStakeAmount;

        // Update pool totals and user count
        s_pools[day][period].totalStakedAmount -= oldStakeAmount;
        s_pools[day][period].usersCount--;

        // Clear occupancy in this pool
        s_userHasAlarmInPool[msg.sender][day][period] = false;

        // Emit deletion details with original values
        emit AlarmDeleted(msg.sender, oldWakeUpTime, oldStakeAmount);

        // Mark alarm as deleted and clear stake
        alarm.status = Status.Deleted;
        alarm.stakeAmount = 0;

        // Refund remaining stake
        (bool success,) = msg.sender.call{value: returnStakeAmount}("");
        if (!success) {
            revert AlarmContract__StakeRefundTransferFailed();
        }

        emit ProtocolFeeUpdated(s_protocolFee);
        emit StakeRefunded(msg.sender, returnStakeAmount);
    }

    function claimWinnings(
        uint256 _alarmId,
        uint8 _snoozeCount,
        bytes calldata _signature,
        uint256 _rewardAmount,
        bytes32[] calldata _merkleProof
    ) external nonReentrant {
        Alarm storage alarm = s_userAlarms[msg.sender][_alarmId];

        // Validate the claim preconditions
        _validateClaimPreconditions(alarm);

        // Verify signed outcome from backend
        _verifyOutcomeSignature(alarm.wakeUpTime, _snoozeCount, _signature);

        // Verify reward claim if the user was a winner
        if (_snoozeCount == 0) {
            _verifyRewardClaim(alarm.day, alarm.period, _rewardAmount, _merkleProof);
        } else {
            if (_rewardAmount != 0) revert AlarmContract__MustBeWinnerToClaimReward();
        }

        // Calculate stake return based on snooze count
        uint256 amountToReturn = _calculateStakeReturn(alarm.stakeAmount, _snoozeCount);

        // Mark claimed and finish alarm lifecycle
        s_userHasClaimedWinnings[msg.sender][_alarmId] = true;
        alarm.status = Status.Completed;

        uint256 totalPayout = amountToReturn + _rewardAmount;
        if (totalPayout > 0) {
            (bool sent,) = msg.sender.call{value: totalPayout}("");
            if (!sent) revert AlarmContract__StakeRefundTransferFailed();
        }

        emit WinningsClaimed(msg.sender, alarm.alarmId, _snoozeCount, totalPayout);
    }

    function setMerkleRootForPool(uint256 _day, uint8 _period, bytes32 _merkleRoot) external onlyOwner nonReentrant {
        if (s_pools[_day][_period].isFinalized) revert AlarmContract__PoolIsFinalized();
        if (_merkleRoot == bytes32(0)) revert AlarmContract__InvalidRoot();

        s_pools[_day][_period].rewardMerkleRoot = _merkleRoot;
        s_pools[_day][_period].isFinalized = true;

        emit PoolIsFinalized(_day, _period);
    }

    function withdrawProtocolFee() external onlyOwner nonReentrant {
        uint256 protocolFee = s_protocolFee;
        s_protocolFee = 0;
        (bool success,) = msg.sender.call{value: protocolFee}("");
        if (!success) {
            revert AlarmContract__ProtocolFeeWithdrawTransferFailed();
        }
        emit ProtocolFeeWithdrawn(protocolFee);
    }

    /* public */

    /* internal */
    function _amountIsValid(uint256 amount) internal view {
        _amountGreaterThanZero(amount);
        _amountGreaterThanMinimum(amount);
    }

    /* private */
    function _editSamePool(Alarm storage alarm, uint256 newWakeUpTime, uint256 newStakeAmount) private {
        uint256 oldDay = alarm.day;
        uint8 oldPeriod = alarm.period;
        uint256 oldStakeAmount = alarm.stakeAmount;

        // update the same pool -> Total Staked Amount
        s_pools[oldDay][oldPeriod].totalStakedAmount =
            (s_pools[oldDay][oldPeriod].totalStakedAmount - oldStakeAmount) + newStakeAmount;

        // update alarm while keeping the same day and period
        alarm.wakeUpTime = newWakeUpTime;
        alarm.stakeAmount = newStakeAmount;
    }

    function _moveToNewPool(
        Alarm storage alarm,
        uint256 newDay,
        uint8 newPeriod,
        uint256 newWakeUpTime,
        uint256 newStakeAmount
    ) private {
        uint256 oldDay = alarm.day;
        uint8 oldPeriod = alarm.period;
        uint256 oldStakeAmount = alarm.stakeAmount;

        // update the old pool -> User Count & Total Staked Amount
        s_pools[oldDay][oldPeriod].totalStakedAmount -= oldStakeAmount;
        s_pools[oldDay][oldPeriod].usersCount--;

        // update the new pool -> User Count & Total Staked Amount
        s_pools[newDay][newPeriod].totalStakedAmount += newStakeAmount;
        s_pools[newDay][newPeriod].usersCount++;

        // set pool occupancy flags
        s_userHasAlarmInPool[msg.sender][oldDay][oldPeriod] = false;
        s_userHasAlarmInPool[msg.sender][newDay][newPeriod] = true;

        // move alarm in-place
        alarm.period = newPeriod;
        alarm.day = newDay;
        alarm.stakeAmount = newStakeAmount;
        alarm.wakeUpTime = newWakeUpTime;
        alarm.status = Status.Active;
    }

    /* internal & private view & pure functions */
        function _amountGreaterThanMinimum(uint256 amount) private view{
        if (amount.getUsdValue(address(s_priceFeed)) < MINIMUM_STAKE_AMOUNT_IN_USD) {
            revert AlarmContract__StakeAmountLessThanMinimum();
        }
    }
        function _amountGreaterThanZero(uint256 amount) private pure {
        if (amount <= 0) {
            revert AlarmContract__StakeAmountShouldBeGreaterThanZero();
        }
    }

    function _wakeUpTimeInFuture(uint256 wakeUpTime) private view {
        if (wakeUpTime <= block.timestamp) {
            revert AlarmContract__InvalidWakeUpTime();
        }
    }

    function _verifyOutcomeSignature(uint256 _wakeUpTime, uint8 _snoozeCount, bytes calldata _signature) private view {
        bytes32 messageHash =
            keccak256(abi.encodePacked(keccak256(abi.encodePacked(msg.sender, _wakeUpTime, _snoozeCount))));
        address signer = ECDSA.recover(messageHash, _signature);
        if (signer != s_verifierSigner) revert AlarmContract__InvalidSignature();
    }

    function _verifyRewardClaim(uint256 _day, uint8 _period, uint256 _rewardAmount, bytes32[] calldata _merkleProof)
        private
        view
    {
        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(msg.sender, _rewardAmount))));
        bytes32 root = s_pools[_day][_period].rewardMerkleRoot;
        if (!MerkleProof.verify(_merkleProof, root, leaf)) revert AlarmContract__InvalidProof();
    }

    function _validateIfAlarmCanBeEditedOrDeleted(Alarm storage alarm) private view {
        // Preconditions for editing or deleting an alarm
        //   -> Alarm must BELONG to the user
        //   -> Alarm must EXIST
        //   -> Alarm must BE ACTIVE
        //   -> Pool must NOT BE FINALIZED

        if (alarm.user != msg.sender) revert AlarmContract__AlarmDoesNotBelongToUser();
        if (alarm.status == Status.None) revert AlarmContract__NoAlarmFound();
        if (alarm.status == Status.Deleted) revert AlarmContract__AlarmDeleted();
        if (alarm.status != Status.Active) revert AlarmContract__AlarmNotActive();
        if (s_pools[alarm.day][alarm.period].isFinalized) revert AlarmContract__PoolIsFinalized();
    }

    function _validateClaimPreconditions(Alarm storage alarm) private view {
        // Preconditions for claiming winnings
        //   -> Alarm must EXIST
        //   -> Alarm must BELONG to the user
        //   -> Alarm must BE ACTIVE
        //   -> Alarm must NOT HAVE BEEN CLAIMED
        //   -> Pool must BE FINALIZED

        if (alarm.status == Status.None) revert AlarmContract__NoAlarmFound();
        if (alarm.user != msg.sender) revert AlarmContract__AlarmDoesNotBelongToUser();
        if (alarm.status == Status.Deleted) revert AlarmContract__AlarmDeleted();
        if (alarm.status != Status.Active) revert AlarmContract__AlarmNotActive();
        if (s_userHasClaimedWinnings[msg.sender][alarm.alarmId]) revert AlarmContract__AlreadyClaimed();
        if (!s_pools[alarm.day][alarm.period].isFinalized) revert AlarmContract__PoolNotFinalized();
    }

    function _calculateStakeReturn(uint256 _stake, uint8 _snoozeCount) private pure returns (uint256) {
        if (_snoozeCount == 0) {
            // Success, return full stake
            return _stake;
        } else if (_snoozeCount == 1) {
            // 20% slash, return 80%
            return (_stake * SLASH_EIGHTY) / PERCENTAGE_DIVISION_PRECISION;
        } else if (_snoozeCount == 2) {
            // 50% slash, return 50%
            return (_stake * SLASH_FIFTY) / PERCENTAGE_DIVISION_PRECISION;
        } else {
            // 100% slash for 3 or more snoozes, return 0
            return 0;
        }
    }

    /* external & public view & pure functions */

    function _calculateDayAndPeriod(uint256 _wakeUpTime) public pure returns (uint256 day, uint8 period) {
        day = _wakeUpTime / 1 days;
        period = uint8((_wakeUpTime % 1 days) / 12 hours);
    }

    function getAlarm(address _user, uint256 _alarmId) external view returns (Alarm memory) {
        return s_userAlarms[_user][_alarmId];
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

    function getHasClaimed(address _user, uint256 _alarmId) external view returns (bool) {
        return s_userHasClaimedWinnings[_user][_alarmId];
    }

    function getHasAlarmInPool(address _user, uint256 _day, uint8 _period) external view returns (bool) {
        return s_userHasAlarmInPool[_user][_day][_period];
    }

    function getNextAlarmId() external view returns (uint256) {
        return s_alarmId;
    }

    function getPriceFeed() external view returns (address) {
        return address(s_priceFeed);
    }

    function getMinimumStakeUsd() external pure returns (uint256) {
        return MINIMUM_STAKE_AMOUNT_IN_USD;
    }
}
