// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title LinearVaultEngine
 * @author villalobos-dev
 * @notice Linear payment streaming contract: an employer deposits a total amount that is
 *         released proportionally to the time elapsed until maturity.
 * @dev Every stream shares the same ERC20 token (`i_token`), set in the constructor.
 */
contract LinearVaultEngine is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a received address is the zero address.
    error LinearVaultEngine__AddressZero();

    /// @notice Thrown when the stream duration is not valid (zero).
    error LinearVaultEngine__RequiredValidTime();

    /// @notice Thrown when the stream amount is not valid (zero).
    error LinearVaultEngine__RequiredValidAmount();

    /// @notice Thrown when the withdrawal is requested by an address other than the stream beneficiary.
    error LinearVaultEngine__OnlyEmployeeCanRequestWithdraw();

    /// @notice Thrown when the requested amount exceeds the amount currently available to withdraw.
    error LinearVaultEngine__InsufficientAvailableAmount();

    /// @notice Thrown when withdrawing before the stream's minimum lock period has elapsed.
    error LinearVaultEngine__MinimumNumbersOfDaysNotExceeded();

    /// @notice Thrown when the given `streamId` does not correspond to an existing stream.
    error LinearVaultEngine__InvalidStreamId();

    /// @notice Thrown when the minimum lock period is longer than the stream duration, which would
    ///         make the funds unreachable for part of the vesting.
    error LinearVaultEngine__MinimumDaysNeedsToBeLessThanDuration();

    /// @notice Thrown when the employer sets itself as the beneficiary of the stream. Such a stream
    ///         would only return the funds to whoever deposited them, so it is rejected as a
    ///         caller mistake rather than stored.
    error LinearVaultEngine__EmployerCannotBeEmployee();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev Seconds in a day, used to convert the day-denominated inputs into the seconds the
    ///      vesting math works with.
    uint256 private constant SECONDS_PER_DAY = 1 days; // 60*60*24 -- Is the same

    /// @dev ERC20 token in which every stream of the contract is paid.
    IERC20 private immutable i_token;

    /**
     * @notice Data of a linear payment stream.
     * @dev Every time field is stored in seconds, even though the creation API takes days.
     * @param employer Address that creates and funds the stream.
     * @param employee Address that receives the funds.
     * @param startTime Timestamp at which vesting starts.
     * @param endTime Timestamp at which the total amount is fully vested.
     * @param totalAmount Total amount deposited for the stream.
     * @param amountWithdrawn Amount already withdrawn by the beneficiary.
     * @param withdrawableFrom Timestamp before which withdrawing is not allowed.
     */
    struct Stream {
        address employer;
        address employee;
        uint256 startTime;
        uint256 endTime;
        uint256 totalAmount;
        uint256 amountWithdrawn;
        uint256 withdrawableFrom;
    }

    /// @dev Registry of streams indexed by their incremental id.
    mapping(uint256 streamId => Stream stream) private s_streams;

    /// @dev Ids of the streams funded by each employer, in creation order.
    mapping(address employer => uint256[] streamIds) private s_streamsByEmployer;

    /// @dev Ids of the streams each employee is the beneficiary of, in creation order.
    mapping(address employee => uint256[] streamIds) private s_streamsByEmployee;

    /// @dev Next id to assign; equals the number of streams created.
    uint256 private s_lastIdStream;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a new stream is created and funded.
     * @param streamId Id assigned to the new stream.
     * @param employer Address that creates and funds the stream.
     * @param employee Address that receives the funds.
     * @param totalAmount Total amount deposited for the stream.
     * @param startTime Timestamp at which vesting starts.
     * @param endTime Timestamp at which the total amount is fully vested.
     * @param withdrawableFrom Timestamp before which withdrawing is not allowed.
     */
    event StreamCreated(
        uint256 indexed streamId,
        address indexed employer,
        address indexed employee,
        uint256 totalAmount,
        uint256 startTime,
        uint256 endTime,
        uint256 withdrawableFrom
    );

    /**
     * @notice Emitted when a beneficiary withdraws vested funds from a stream.
     * @param streamId Id of the stream funds were withdrawn from.
     * @param employee Address that received the funds.
     * @param amount Amount withdrawn in this call, in token units.
     * @param totalWithdrawn Cumulative amount withdrawn from the stream after this call.
     */
    event Withdrawn(uint256 indexed streamId, address indexed employee, uint256 amount, uint256 totalWithdrawn);

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Reverts if `streamId` does not correspond to a stream that has been created.
     * @dev Ids are assigned incrementally from zero, so any id below `s_lastIdStream` exists.
     *      Without this check the mapping would return a zeroed `Stream` and the getters would
     *      report a stream of zero days rather than signalling the wrong id.
     * @param streamId Id of the stream to validate.
     */
    modifier streamExists(uint256 streamId) {
        if (streamId >= s_lastIdStream) {
            revert LinearVaultEngine__InvalidStreamId();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the stream engine for a specific ERC20 token.
     * @dev The token is immutable: it cannot be changed after deployment.
     * @param token Address of the ERC20 token used by every stream.
     */
    constructor(address token) {
        if (token == address(0)) revert LinearVaultEngine__AddressZero();
        i_token = IERC20(token);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a stream approving the funds with an EIP-2612 signature in the same transaction.
     * @dev The `permit` call is wrapped in a try/catch: the signature is visible in the mempool and if a
     *      third party executes it first, `permit` would revert. By catching the error, execution continues
     *      with the stream creation, which will fail anyway if the allowance is not enough.
     * @param _employee Address that receives the stream funds.
     * @param _durationInDays Stream duration in days, starting from the current moment.
     * @param _totalAmount Total amount to deposit and to vest linearly.
     * @param _lockDurationInDays Days that must pass before the beneficiary can withdraw.
     * @param deadline Timestamp until which the permit signature is valid.
     * @param v The v component of the permit signature.
     * @param r The r component of the permit signature.
     * @param s The s component of the permit signature.
     */
    function createStreamWithPermit(
        address _employee,
        uint256 _durationInDays,
        uint256 _totalAmount,
        uint256 _lockDurationInDays,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        try IERC20Permit(address(i_token)).permit(msg.sender, address(this), _totalAmount, deadline, v, r, s) {}
            catch {} // The signature is visible in the mempool, so if someone else executes it first this reverts and is useless; in that case just carry on
        createStream(_employee, _durationInDays, _totalAmount, _lockDurationInDays);
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a new linear payment stream and deposits the funds into the contract.
     * @dev Follows the Check-Effects-Interactions pattern: validates, writes the state and finally
     *      performs the `safeTransferFrom`. The caller must have approved `_totalAmount`
     *      beforehand (or use {createStreamWithPermit}).
     *
     *      Both time parameters are expressed in **days** and converted to seconds on the way in, so
     *      the stored stream and the vesting math always work in seconds. Sub-day granularity is
     *      therefore not expressible: the shortest possible stream is one day.
     *
     *      Only plain ERC20 tokens are supported. A fee-on-transfer or rebasing token would make the
     *      contract insolvent, since `totalAmount` is recorded as the requested amount rather than
     *      the amount actually received.
     * @param _employee Address that receives the stream funds.
     * @param _durationInDays Stream duration in days, starting from the current moment.
     * @param _totalAmount Total amount to deposit and to vest linearly.
     * @param _lockDurationInDays Days that must pass before the beneficiary can withdraw.
     */
    function createStream(address _employee, uint256 _durationInDays, uint256 _totalAmount, uint256 _lockDurationInDays)
        public
    {
        if (_employee == address(0)) {
            revert LinearVaultEngine__AddressZero();
        }

        if (_employee == msg.sender) {
            revert LinearVaultEngine__EmployerCannotBeEmployee();
        }

        if (_durationInDays == 0) {
            revert LinearVaultEngine__RequiredValidTime();
        }

        if (_totalAmount == 0) {
            revert LinearVaultEngine__RequiredValidAmount();
        }

        if (_lockDurationInDays > _durationInDays) {
            revert LinearVaultEngine__MinimumDaysNeedsToBeLessThanDuration();
        }

        uint256 endTime = block.timestamp + (_durationInDays * SECONDS_PER_DAY);
        uint256 withdrawableFrom = block.timestamp + (_lockDurationInDays * SECONDS_PER_DAY);
        uint256 streamId = s_lastIdStream;

        s_streams[streamId] = Stream({
            employer: msg.sender,
            employee: _employee,
            startTime: block.timestamp,
            endTime: endTime,
            totalAmount: _totalAmount,
            amountWithdrawn: 0,
            withdrawableFrom: withdrawableFrom
        });

        s_streamsByEmployer[msg.sender].push(streamId);
        s_streamsByEmployee[_employee].push(streamId);

        emit StreamCreated(streamId, msg.sender, _employee, _totalAmount, block.timestamp, endTime, withdrawableFrom);

        s_lastIdStream++;

        i_token.safeTransferFrom(msg.sender, address(this), _totalAmount);
    }

    /**
     * @notice Withdraws a specific amount of already vested funds from a stream.
     * @dev Only the stream beneficiary can call it, and only after `withdrawableFrom` has passed.
     *      Follows the Check-Effects-Interactions pattern and is protected with `nonReentrant`:
     *      the withdrawn amount is written to storage before transferring the tokens out.
     * @param streamId Id of the stream to withdraw from.
     * @param amount Amount to withdraw, which must not exceed {amountAvailableToWithdraw}.
     */
    function withdrawSpecificAmount(uint256 streamId, uint256 amount) public nonReentrant streamExists(streamId) {
        if (amount == 0) {
            revert LinearVaultEngine__RequiredValidAmount();
        }

        Stream storage stream = s_streams[streamId];

        if (msg.sender != stream.employee) {
            revert LinearVaultEngine__OnlyEmployeeCanRequestWithdraw();
        }

        if (block.timestamp < stream.withdrawableFrom) {
            revert LinearVaultEngine__MinimumNumbersOfDaysNotExceeded();
        }

        uint256 avaliableToWithdraw = _amountAvailableToWithdraw(streamId);

        if (avaliableToWithdraw < amount) {
            revert LinearVaultEngine__InsufficientAvailableAmount();
        }

        stream.amountWithdrawn += amount;

        emit Withdrawn(streamId, stream.employee, amount, stream.amountWithdrawn);

        i_token.safeTransfer(stream.employee, amount);
    }

    /**
     * @notice Withdraws every vested and not yet withdrawn token from a stream.
     * @dev Convenience wrapper that forwards {amountAvailableToWithdraw} to {withdrawSpecificAmount},
     *      so it inherits all of its checks (caller, lock period and stream id).
     * @param streamId Id of the stream to withdraw from.
     */
    function withdrawMax(uint256 streamId) public streamExists(streamId) {
        uint256 available = _amountAvailableToWithdraw(streamId);
        if (available == 0) return;
        withdrawSpecificAmount(streamId, available);
    }

    /**
     * @notice Returns the amount the beneficiary can withdraw right now from a stream.
     * @dev Public wrapper around {_amountAvailableToWithdraw}. An employee finds the ids of their
     *      own streams with {getStreamsByEmployee}.
     * @param streamId Id of the stream to query.
     * @return Amount vested and not yet withdrawn, in token units.
     */
    function amountAvailableToWithdraw(uint256 streamId) public view streamExists(streamId) returns (uint256) {
        return _amountAvailableToWithdraw(streamId);
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Computes the amount available to withdraw from a stream.
     * @dev If `endTime` has already been reached it returns the whole remainder; otherwise it vests
     *      proportionally to the time elapsed and subtracts what has already been withdrawn.
     *      A non-existent `streamId` returns an empty `Stream` and therefore zero.
     * @param streamId Id of the stream to query.
     * @return Amount vested and not yet withdrawn, in token units.
     */
    function _amountAvailableToWithdraw(uint256 streamId) private view returns (uint256) {
        Stream memory stream = s_streams[streamId];

        if (block.timestamp < stream.withdrawableFrom) {
            return 0;
        }

        if (block.timestamp >= stream.endTime) {
            return stream.totalAmount - stream.amountWithdrawn;
        }

        uint256 elapsed = block.timestamp - stream.startTime;
        uint256 duration = stream.endTime - stream.startTime;
        uint256 vested = (stream.totalAmount * elapsed) / duration;

        return vested - stream.amountWithdrawn;
    }

    /*//////////////////////////////////////////////////////////////
                            GETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns all the data of a stream.
     * @param streamId Id of the stream to query.
     * @return The complete {Stream} struct; zeroed fields if the id does not exist.
     */
    function getStream(uint256 streamId) external view streamExists(streamId) returns (Stream memory) {
        return s_streams[streamId];
    }

    /**
     * @notice Returns the employer that funded a stream.
     * @param streamId Id of the stream to query.
     * @return The employer address.
     */
    function getEmployer(uint256 streamId) external view streamExists(streamId) returns (address) {
        return s_streams[streamId].employer;
    }

    /**
     * @notice Returns the beneficiary of a stream.
     * @param streamId Id of the stream to query.
     * @return The employee address.
     */
    function getEmployee(uint256 streamId) external view streamExists(streamId) returns (address) {
        return s_streams[streamId].employee;
    }

    /**
     * @notice Returns the timestamp at which the vesting of a stream starts.
     * @param streamId Id of the stream to query.
     * @return The start timestamp in seconds.
     */
    function getStartTime(uint256 streamId) external view streamExists(streamId) returns (uint256) {
        return s_streams[streamId].startTime;
    }

    /**
     * @notice Returns the timestamp at which a stream becomes fully vested.
     * @param streamId Id of the stream to query.
     * @return The end timestamp in seconds.
     */
    function getEndTime(uint256 streamId) external view streamExists(streamId) returns (uint256) {
        return s_streams[streamId].endTime;
    }

    /**
     * @notice Returns the total amount deposited into a stream.
     * @param streamId Id of the stream to query.
     * @return The total amount in token units.
     */
    function getTotalAmount(uint256 streamId) external view streamExists(streamId) returns (uint256) {
        return s_streams[streamId].totalAmount;
    }

    /**
     * @notice Returns the amount already withdrawn from a stream.
     * @param streamId Id of the stream to query.
     * @return The withdrawn amount in token units.
     */
    function getAmountWithdrawn(uint256 streamId) external view streamExists(streamId) returns (uint256) {
        return s_streams[streamId].amountWithdrawn;
    }

    /**
     * @notice Returns the timestamp from which a stream can be withdrawn from.
     * @dev This is an absolute timestamp in seconds, not a duration. For the lock expressed in days
     *      use {getLockDurationInDays}.
     * @param streamId Id of the stream to query.
     * @return The timestamp in seconds before which withdrawing reverts.
     */
    function getWithdrawableFrom(uint256 streamId) external view streamExists(streamId) returns (uint256) {
        return s_streams[streamId].withdrawableFrom;
    }

    /**
     * @notice Returns the lock period of a stream, in days.
     * @dev Derived from the stored timestamps rather than kept as its own field. Since streams are
     *      always created from a whole number of days, the division is exact.
     * @param streamId Id of the stream to query.
     * @return The number of days that must pass from `startTime` before withdrawing is allowed.
     */
    function getLockDurationInDays(uint256 streamId) external view streamExists(streamId) returns (uint256) {
        Stream memory stream = s_streams[streamId];
        return (stream.withdrawableFrom - stream.startTime) / SECONDS_PER_DAY;
    }

    /**
     * @notice Returns the total duration of a stream, in days.
     * @dev Derived from the stored timestamps. Since streams are always created from a whole number
     *      of days, the division is exact.
     * @param streamId Id of the stream to query.
     * @return The number of days between `startTime` and `endTime`.
     */
    function getDurationInDays(uint256 streamId) external view streamExists(streamId) returns (uint256) {
        Stream memory stream = s_streams[streamId];
        return (stream.endTime - stream.startTime) / SECONDS_PER_DAY;
    }

    /**
     * @notice Returns every stream funded by an employer.
     * @param employer Address that funded the streams.
     * @return The ids of the employer's streams, in creation order.
     */
    function getStreamsByEmployer(address employer) external view returns (uint256[] memory) {
        return s_streamsByEmployer[employer];
    }

    /**
     * @notice Returns every stream an employee is the beneficiary of.
     * @param employee Address that receives the funds.
     * @return The ids of the employee's streams, in creation order.
     */
    function getStreamsByEmployee(address employee) external view returns (uint256[] memory) {
        return s_streamsByEmployee[employee];
    }

    /**
     * @notice Returns how many streams an employer has funded.
     * @dev Lets a caller page through {getStreamsByEmployer} instead of fetching the whole array.
     * @param employer Address that funded the streams.
     * @return The number of streams created by the employer.
     */
    function getStreamCountByEmployer(address employer) external view returns (uint256) {
        return s_streamsByEmployer[employer].length;
    }

    /**
     * @notice Returns how many streams an employee is the beneficiary of.
     * @dev Lets a caller page through {getStreamsByEmployee} instead of fetching the whole array.
     * @param employee Address that receives the funds.
     * @return The number of streams the employee is the beneficiary of.
     */
    function getStreamCountByEmployee(address employee) external view returns (uint256) {
        return s_streamsByEmployee[employee].length;
    }

    /**
     * @notice Returns the next stream id to be assigned.
     * @dev Equals the total number of streams created; valid ids range from 0 to this value - 1.
     * @return The next available id.
     */
    function getLastIdStream() external view returns (uint256) {
        return s_lastIdStream;
    }
}
