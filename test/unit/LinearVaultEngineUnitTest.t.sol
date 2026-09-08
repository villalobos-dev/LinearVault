// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LinearVaultEngine} from "../../src/LinearVaultEngine.sol";
import {DeployLinearVault} from "../../script/DeployLinearVault.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title LinearVaultEngineUnitTest
 * @author villalobos-dev
 * @notice Unit tests for {LinearVaultEngine}: stream creation (with and without `permit`),
 *         linear vesting math and withdrawals.
 * @dev The scenario is always the same: a 30 day stream of 1000 mUSDC with a 7 day lock,
 *         funded by `employer` in favour of `employee`.
 */
contract LinearVaultEngineUnitTest is Test {
    /// @dev Contract under test, redeployed for every test case.
    LinearVaultEngine public linearVaultEngine;

    /// @dev Payment token of the engine, with 6 decimals and `permit` support.
    ERC20Mock public mockToken;

    /// @dev Address that funds the streams; it has a known private key so it can sign permits.
    address public employer;

    /// @dev Private key of `employer`, used to sign EIP-2612 permits.
    uint256 public employerPk;

    /// @dev Beneficiary of the streams.
    address public employee = makeAddr("employee");

    /// @dev Duration of the streams under test, in days: the unit the creation API takes.
    uint256 public constant DURATION_IN_DAYS = 30;

    /// @dev The same duration in seconds, for warping and for the vesting math.
    uint256 public constant END_TIME = DURATION_IN_DAYS * 1 days;

    /// @dev Intermediate checkpoint used to assert partial vesting.
    uint256 public constant TEN_DAYS = 10 days;

    /// @dev Midpoint of the stream: exactly half of the total is vested there.
    uint256 public constant HALF_END_TIME = END_TIME / 2;

    /// @dev Amount deposited per stream, in token units (6 decimals).
    uint256 public constant TOTAL_AMOUNT = 1000e6;

    /// @dev Amount vested at `HALF_END_TIME`.
    uint256 public constant HALF_TOTAL_AMOUNT = TOTAL_AMOUNT / 2;

    /// @dev Lock period before any withdrawal is allowed, in days.
    uint256 public constant LOCK_IN_DAYS = 7;

    /// @dev The same lock period in seconds.
    uint256 public constant MINIMUM_DAYS_TO_WITHDRAW = LOCK_IN_DAYS * 1 days;

    /// @dev Validity window given to the permit signatures.
    uint256 public constant PERMIT_DEADLINE_DURATION = 1 hours;

    /// @dev Id of the only stream created in each test; ids start at zero.
    uint256 public constant FIRST_STREAM_ID = 0;

    /// @dev Readable zero for withdrawal assertions.
    uint256 public constant NO_AMOUNT_WITHDRAWN = 0;

    /// @dev Readable zero for allowance assertions.
    uint256 public constant NO_ALLOWANCE_LEFT = 0;

    /// @dev Readable zero for balance assertions.
    uint256 public constant NO_BALANCE_LEFT = 0;

    /// @dev EIP-2612 struct type hash, needed to build the permit digest by hand.
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /**
     * @notice Deploys the engine and its token through the deployment script and funds the employer.
     * @dev Runs before every test, so each case starts with no streams and a freshly funded employer.
     */
    function setUp() public {
        DeployLinearVault deployLinear = new DeployLinearVault();
        (linearVaultEngine, mockToken) = deployLinear.run();
        (employer, employerPk) = makeAddrAndKey("employer");
        mockToken.mint(employer, TOTAL_AMOUNT);
    }

    /**
     * @notice Builds and signs an EIP-2612 permit for the mock token.
     * @dev Reads the current nonce of `owner` from the token, so consecutive calls produce valid signatures.
     * @param privKey Private key that signs the permit.
     * @param owner Address granting the allowance.
     * @param spender Address receiving the allowance.
     * @param value Amount to approve.
     * @param deadline Timestamp until which the signature is valid.
     * @return v The v component of the signature.
     * @return r The r component of the signature.
     * @return s The s component of the signature.
     */
    function _signPermit(uint256 privKey, address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, mockToken.nonces(owner), deadline));
        bytes32 digest = MessageHashUtils.toTypedDataHash(mockToken.DOMAIN_SEPARATOR(), structHash);
        (v, r, s) = vm.sign(privKey, digest);
    }

    /// @dev Creates the reference stream using a plain `approve` + {LinearVaultEngine.createStream}.
    modifier createStreamWithoutSign() {
        vm.prank(employer);
        mockToken.approve(address(linearVaultEngine), TOTAL_AMOUNT);
        vm.prank(employer);
        linearVaultEngine.createStream(employee, DURATION_IN_DAYS, TOTAL_AMOUNT, LOCK_IN_DAYS);
        _;
    }

    /// @dev Creates the reference stream in a single transaction via {LinearVaultEngine.createStreamWithPermit}.
    modifier createStreamWithPermit() {
        uint256 deadline = block.timestamp + PERMIT_DEADLINE_DURATION;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(employerPk, employer, address(linearVaultEngine), TOTAL_AMOUNT, deadline);
        vm.prank(employer);
        linearVaultEngine.createStreamWithPermit(
            employee, DURATION_IN_DAYS, TOTAL_AMOUNT, LOCK_IN_DAYS, deadline, v, r, s
        );
        _;
    }

    /// @notice The first stream is stored with every field set from the creation arguments.
    function testCreateFirstVault() public createStreamWithoutSign {
        LinearVaultEngine.Stream memory stream = linearVaultEngine.getStream(FIRST_STREAM_ID);

        assertEq(stream.employer, employer);
        assertEq(stream.employee, employee);
        assertEq(stream.startTime, block.timestamp);
        assertEq(stream.endTime, block.timestamp + END_TIME);
        assertEq(stream.totalAmount, TOTAL_AMOUNT);
        assertEq(stream.amountWithdrawn, NO_AMOUNT_WITHDRAWN);
        assertEq(stream.withdrawableFrom, block.timestamp + MINIMUM_DAYS_TO_WITHDRAW);
    }

    /// @notice After 10 of 30 days, exactly a third of the total is available to withdraw.
    function testamountAvailableToWithdraw() public createStreamWithoutSign {
        vm.warp(block.timestamp + TEN_DAYS);
        uint256 amountAvailableToWithdraw = linearVaultEngine.amountAvailableToWithdraw(FIRST_STREAM_ID);
        uint256 expectedAmount = (TOTAL_AMOUNT * TEN_DAYS) / END_TIME;

        assertEq(amountAvailableToWithdraw, expectedAmount);
    }

    /// @notice Creating a stream moves the whole deposit into the engine.
    function testBalanceOfVaultWithOutSign() public createStreamWithoutSign {
        assertEq(mockToken.balanceOf(address(linearVaultEngine)), TOTAL_AMOUNT);
    }

    /// @notice The permit path funds the stream and leaves no leftover allowance or balance behind.
    function testCreateStreamWithPermit() public createStreamWithPermit {
        LinearVaultEngine.Stream memory stream = linearVaultEngine.getStream(FIRST_STREAM_ID);

        assertEq(stream.employer, employer);
        assertEq(stream.totalAmount, TOTAL_AMOUNT);
        assertEq(mockToken.balanceOf(address(linearVaultEngine)), TOTAL_AMOUNT);
        assertEq(mockToken.balanceOf(employer), NO_BALANCE_LEFT);

        // The allowance was fully consumed, nothing is left dangling
        assertEq(mockToken.allowance(employer, address(linearVaultEngine)), NO_ALLOWANCE_LEFT);
    }

    /// @notice At the midpoint the employee can withdraw half of the total.
    function testWithdrawn() public createStreamWithoutSign {
        vm.warp(block.timestamp + HALF_END_TIME);

        vm.prank(employee);
        linearVaultEngine.withdrawSpecificAmount(FIRST_STREAM_ID, HALF_TOTAL_AMOUNT);

        assertEq(mockToken.balanceOf(employee), HALF_TOTAL_AMOUNT);
    }

    /// @notice Once withdrawn, only what vests afterwards becomes available again.
    function testamountAvailableToWithdrawAfterWithdrawn() public createStreamWithoutSign {
        vm.warp(block.timestamp + HALF_END_TIME);

        vm.prank(employee);
        linearVaultEngine.withdrawSpecificAmount(FIRST_STREAM_ID, HALF_TOTAL_AMOUNT);
        vm.warp(block.timestamp + 3 days);
        uint256 expectedAmount = (TOTAL_AMOUNT * 3 days) / END_TIME;

        assertEq(linearVaultEngine.amountAvailableToWithdraw(FIRST_STREAM_ID), expectedAmount);
    }

    /**
     * @notice Partial withdrawals always discount what was already taken out.
     * @dev Walks the stream through day 10 and day 20, checking the available amount after a partial
     *      withdrawal, that asking for one unit more than available reverts, and that the funds not
     *      yet vested stay in the engine.
     */
    function testPartialWithdrawnInIntermediatePointDiscountsWhatWasAlreadyWithdrawn() public createStreamWithoutSign {
        // Day 10 of 30: a third of the total has vested and the employee takes only part of it
        vm.warp(block.timestamp + TEN_DAYS);

        uint256 vestedAtTenDays = (TOTAL_AMOUNT * TEN_DAYS) / END_TIME;
        assertEq(linearVaultEngine.amountAvailableToWithdraw(FIRST_STREAM_ID), vestedAtTenDays);

        uint256 firstWithdrawn = vestedAtTenDays / 2;
        vm.prank(employee);
        linearVaultEngine.withdrawSpecificAmount(FIRST_STREAM_ID, firstWithdrawn);

        // Without advancing time, only the vested half that was not withdrawn remains
        assertEq(linearVaultEngine.getAmountWithdrawn(FIRST_STREAM_ID), firstWithdrawn);
        assertEq(linearVaultEngine.amountAvailableToWithdraw(FIRST_STREAM_ID), vestedAtTenDays - firstWithdrawn);

        // Day 20 of 30: still not the end, vested is 2/3 minus what was already withdrawn
        vm.warp(block.timestamp + TEN_DAYS);

        uint256 vestedAtTwentyDays = (TOTAL_AMOUNT * (TEN_DAYS * 2)) / END_TIME;
        uint256 expectedAvaliable = vestedAtTwentyDays - firstWithdrawn;
        assertEq(linearVaultEngine.amountAvailableToWithdraw(FIRST_STREAM_ID), expectedAvaliable);

        // Asking for one unit more than available reverts: what was already withdrawn counts
        vm.prank(employee);
        vm.expectRevert(LinearVaultEngine.LinearVaultEngine__InsufficientAvailableAmount.selector);
        linearVaultEngine.withdrawSpecificAmount(FIRST_STREAM_ID, expectedAvaliable + 1);

        // Withdrawing exactly what is available works and leaves nothing available
        vm.prank(employee);
        linearVaultEngine.withdrawSpecificAmount(FIRST_STREAM_ID, expectedAvaliable);

        assertEq(mockToken.balanceOf(employee), vestedAtTwentyDays);
        assertEq(linearVaultEngine.getAmountWithdrawn(FIRST_STREAM_ID), vestedAtTwentyDays);
        assertEq(linearVaultEngine.amountAvailableToWithdraw(FIRST_STREAM_ID), NO_AMOUNT_WITHDRAWN);

        // The rest stays in the vault waiting to vest
        assertEq(mockToken.balanceOf(address(linearVaultEngine)), TOTAL_AMOUNT - vestedAtTwentyDays);
    }
    /*//////////////////////////////////////////////////////////////
                          DAY <-> SECOND CONVERSION
    //////////////////////////////////////////////////////////////*/

    /// @notice Day-denominated inputs are converted to seconds when the stream is stored.
    function testCreationInputsAreConvertedFromDaysToSeconds() public createStreamWithoutSign {
        LinearVaultEngine.Stream memory stream = linearVaultEngine.getStream(FIRST_STREAM_ID);

        assertEq(stream.endTime - stream.startTime, DURATION_IN_DAYS * 1 days);
        assertEq(stream.withdrawableFrom - stream.startTime, LOCK_IN_DAYS * 1 days);
    }

    /// @notice The day-denominated getters round-trip the values the stream was created with.
    function testGettersReturnDays() public createStreamWithoutSign {
        assertEq(linearVaultEngine.getDurationInDays(FIRST_STREAM_ID), DURATION_IN_DAYS);
        assertEq(linearVaultEngine.getLockDurationInDays(FIRST_STREAM_ID), LOCK_IN_DAYS);
    }

    /// @notice `getWithdrawableFrom` returns the absolute timestamp, not a duration.
    function testGetWithdrawableFromReturnsTimestamp() public createStreamWithoutSign {
        assertEq(
            linearVaultEngine.getWithdrawableFrom(FIRST_STREAM_ID),
            block.timestamp + MINIMUM_DAYS_TO_WITHDRAW
        );
    }

    /// @notice A one day stream is the shortest one expressible, and it vests over a full day.
    function testOneDayStreamVestsOverOneDay() public {
        vm.startPrank(employer);
        mockToken.approve(address(linearVaultEngine), TOTAL_AMOUNT);
        linearVaultEngine.createStream(employee, 1, TOTAL_AMOUNT, 0);
        vm.stopPrank();

        assertEq(linearVaultEngine.getDurationInDays(FIRST_STREAM_ID), 1);

        vm.warp(block.timestamp + 12 hours);
        assertEq(linearVaultEngine.amountAvailableToWithdraw(FIRST_STREAM_ID), TOTAL_AMOUNT / 2);
    }

    /// @notice A lock longer than the duration is rejected, now comparing days against days.
    function testRevertsIfLockIsLongerThanDuration() public {
        vm.startPrank(employer);
        mockToken.approve(address(linearVaultEngine), TOTAL_AMOUNT);
        vm.expectRevert(
            LinearVaultEngine.LinearVaultEngine__MinimumDaysNeedsToBeLessThanDuration.selector
        );
        linearVaultEngine.createStream(employee, DURATION_IN_DAYS, TOTAL_AMOUNT, DURATION_IN_DAYS + 1);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              STREAM INDEXES
    //////////////////////////////////////////////////////////////*/

    /// @notice A created stream is indexed under both its employer and its employee.
    function testStreamIsIndexedForBothParties() public createStreamWithoutSign {
        uint256[] memory byEmployer = linearVaultEngine.getStreamsByEmployer(employer);
        uint256[] memory byEmployee = linearVaultEngine.getStreamsByEmployee(employee);

        assertEq(byEmployer.length, 1);
        assertEq(byEmployee.length, 1);
        assertEq(byEmployer[0], FIRST_STREAM_ID);
        assertEq(byEmployee[0], FIRST_STREAM_ID);

        assertEq(linearVaultEngine.getStreamCountByEmployer(employer), 1);
        assertEq(linearVaultEngine.getStreamCountByEmployee(employee), 1);
    }

    /// @notice The permit path indexes the stream exactly like the plain path does.
    function testStreamCreatedWithPermitIsIndexed() public createStreamWithPermit {
        assertEq(linearVaultEngine.getStreamsByEmployer(employer)[0], FIRST_STREAM_ID);
        assertEq(linearVaultEngine.getStreamsByEmployee(employee)[0], FIRST_STREAM_ID);
    }

    /// @notice One employer funding several employees gets every id back, in creation order.
    function testEmployerWithSeveralStreams() public {
        address secondEmployee = makeAddr("secondEmployee");
        mockToken.mint(employer, TOTAL_AMOUNT);

        vm.startPrank(employer);
        mockToken.approve(address(linearVaultEngine), TOTAL_AMOUNT * 2);
        linearVaultEngine.createStream(employee, DURATION_IN_DAYS, TOTAL_AMOUNT, LOCK_IN_DAYS);
        linearVaultEngine.createStream(secondEmployee, DURATION_IN_DAYS, TOTAL_AMOUNT, LOCK_IN_DAYS);
        vm.stopPrank();

        uint256[] memory byEmployer = linearVaultEngine.getStreamsByEmployer(employer);
        assertEq(byEmployer.length, 2);
        assertEq(byEmployer[0], 0);
        assertEq(byEmployer[1], 1);

        // Each employee only sees their own stream
        assertEq(linearVaultEngine.getStreamsByEmployee(employee).length, 1);
        assertEq(linearVaultEngine.getStreamsByEmployee(employee)[0], 0);
        assertEq(linearVaultEngine.getStreamsByEmployee(secondEmployee).length, 1);
        assertEq(linearVaultEngine.getStreamsByEmployee(secondEmployee)[0], 1);
    }

    /// @notice One employee hired by two employers is indexed under both of them.
    function testEmployeeHiredByTwoEmployers() public createStreamWithoutSign {
        address secondEmployer = makeAddr("secondEmployer");
        mockToken.mint(secondEmployer, TOTAL_AMOUNT);

        vm.startPrank(secondEmployer);
        mockToken.approve(address(linearVaultEngine), TOTAL_AMOUNT);
        linearVaultEngine.createStream(employee, DURATION_IN_DAYS, TOTAL_AMOUNT, LOCK_IN_DAYS);
        vm.stopPrank();

        uint256[] memory byEmployee = linearVaultEngine.getStreamsByEmployee(employee);
        assertEq(byEmployee.length, 2);
        assertEq(byEmployee[0], 0);
        assertEq(byEmployee[1], 1);

        assertEq(linearVaultEngine.getStreamsByEmployer(employer).length, 1);
        assertEq(linearVaultEngine.getStreamsByEmployer(secondEmployer).length, 1);
    }

    /// @notice An address with no streams gets an empty list rather than a revert.
    function testAddressWithNoStreamsReturnsEmpty() public {
        address stranger = makeAddr("stranger");

        assertEq(linearVaultEngine.getStreamsByEmployer(stranger).length, 0);
        assertEq(linearVaultEngine.getStreamsByEmployee(stranger).length, 0);
        assertEq(linearVaultEngine.getStreamCountByEmployer(stranger), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            INPUT VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice An employer cannot open a stream in its own favour.
    function testRevertsIfEmployerIsAlsoTheEmployee() public {
        vm.startPrank(employer);
        mockToken.approve(address(linearVaultEngine), TOTAL_AMOUNT);
        vm.expectRevert(
            LinearVaultEngine.LinearVaultEngine__EmployerCannotBeEmployee.selector
        );
        linearVaultEngine.createStream(employer, DURATION_IN_DAYS, TOTAL_AMOUNT, LOCK_IN_DAYS);
        vm.stopPrank();

        assertEq(linearVaultEngine.getLastIdStream(), 0);
    }

    /// @notice The zero address is still rejected before the self-stream check.
    function testRevertsIfEmployeeIsZeroAddress() public {
        vm.prank(employer);
        vm.expectRevert(LinearVaultEngine.LinearVaultEngine__AddressZero.selector);
        linearVaultEngine.createStream(address(0), DURATION_IN_DAYS, TOTAL_AMOUNT, LOCK_IN_DAYS);
    }

    /*//////////////////////////////////////////////////////////////
                           NON-EXISTENT STREAMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Every per-stream getter rejects an id that was never assigned.
    function testGettersRevertOnNonExistentStream() public createStreamWithoutSign {
        uint256 ghostId = linearVaultEngine.getLastIdStream(); // the next id, not yet created
        bytes4 expected = LinearVaultEngine.LinearVaultEngine__InvalidStreamId.selector;

        vm.expectRevert(expected);
        linearVaultEngine.getStream(ghostId);

        vm.expectRevert(expected);
        linearVaultEngine.getEmployer(ghostId);

        vm.expectRevert(expected);
        linearVaultEngine.getEmployee(ghostId);

        vm.expectRevert(expected);
        linearVaultEngine.getStartTime(ghostId);

        vm.expectRevert(expected);
        linearVaultEngine.getEndTime(ghostId);

        vm.expectRevert(expected);
        linearVaultEngine.getTotalAmount(ghostId);

        vm.expectRevert(expected);
        linearVaultEngine.getAmountWithdrawn(ghostId);

        vm.expectRevert(expected);
        linearVaultEngine.getWithdrawableFrom(ghostId);

        vm.expectRevert(expected);
        linearVaultEngine.getDurationInDays(ghostId);

        vm.expectRevert(expected);
        linearVaultEngine.getLockDurationInDays(ghostId);

        vm.expectRevert(expected);
        linearVaultEngine.amountAvailableToWithdraw(ghostId);
    }

    /// @notice A far-off id reverts just the same as the next unassigned one.
    function testGettersRevertOnFarOffStreamId() public createStreamWithoutSign {
        vm.expectRevert(LinearVaultEngine.LinearVaultEngine__InvalidStreamId.selector);
        linearVaultEngine.getDurationInDays(999);
    }

    /// @notice Withdrawing from a stream that does not exist reverts with the same error.
    function testWithdrawRevertsOnNonExistentStream() public createStreamWithoutSign {
        uint256 ghostId = linearVaultEngine.getLastIdStream();

        vm.prank(employee);
        vm.expectRevert(LinearVaultEngine.LinearVaultEngine__InvalidStreamId.selector);
        linearVaultEngine.withdrawSpecificAmount(ghostId, 1);
    }

    /// @notice The existing stream keeps answering normally next to the rejected ids.
    function testValidStreamStillReadableAfterGhostChecks() public createStreamWithoutSign {
        assertEq(linearVaultEngine.getDurationInDays(FIRST_STREAM_ID), DURATION_IN_DAYS);
        assertEq(linearVaultEngine.getEmployee(FIRST_STREAM_ID), employee);
    }

    /*//////////////////////////////////////////////////////////////
                               WITHDRAW MAX
    //////////////////////////////////////////////////////////////*/

    /// @notice `withdrawMax` is a no-op while nothing has vested, instead of reverting.
    function testWithdrawMaxIsNoOpDuringLock() public createStreamWithoutSign {
        vm.warp(block.timestamp + 1 days);

        vm.prank(employee);
        linearVaultEngine.withdrawMax(FIRST_STREAM_ID);

        assertEq(mockToken.balanceOf(employee), NO_BALANCE_LEFT);
        assertEq(linearVaultEngine.getAmountWithdrawn(FIRST_STREAM_ID), NO_AMOUNT_WITHDRAWN);
    }

    /// @notice Calling `withdrawMax` again after the stream is fully paid out is idempotent.
    function testWithdrawMaxIsIdempotentOnceFullyPaid() public createStreamWithoutSign {
        vm.warp(block.timestamp + END_TIME + 1 days);

        vm.prank(employee);
        linearVaultEngine.withdrawMax(FIRST_STREAM_ID);
        assertEq(mockToken.balanceOf(employee), TOTAL_AMOUNT);

        // A second call changes nothing and does not revert
        vm.prank(employee);
        linearVaultEngine.withdrawMax(FIRST_STREAM_ID);
        assertEq(mockToken.balanceOf(employee), TOTAL_AMOUNT);
        assertEq(linearVaultEngine.getAmountWithdrawn(FIRST_STREAM_ID), TOTAL_AMOUNT);
    }

    /// @notice `withdrawMax` rejects an id that was never assigned rather than silently doing nothing.
    function testWithdrawMaxRevertsOnNonExistentStream() public createStreamWithoutSign {
        vm.prank(employee);
        vm.expectRevert(LinearVaultEngine.LinearVaultEngine__InvalidStreamId.selector);
        linearVaultEngine.withdrawMax(999);
    }

    /// @notice A stranger calling `withdrawMax` on a vested stream is rejected as unauthorised.
    function testWithdrawMaxRevertsForStranger() public createStreamWithoutSign {
        vm.warp(block.timestamp + END_TIME);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(
            LinearVaultEngine.LinearVaultEngine__OnlyEmployeeCanRequestWithdraw.selector
        );
        linearVaultEngine.withdrawMax(FIRST_STREAM_ID);
    }

}
