// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAverageVotes } from "@interfaces/IAverageVotes.sol";
import { Time } from "@openzeppelin/contracts/utils/types/Time.sol";
import { ERC20AverageVotesUpgradeable } from "@staking/ERC20AverageVotesUpgradeable.sol";
import { VoteIntegralLib } from "@staking/lib/VoteIntegralLib.sol";
import { stdError } from "forge-std/StdError.sol";
import { Test } from "forge-std/Test.sol";

contract AverageVotesTokenHarness is ERC20AverageVotesUpgradeable {
    function initializeAverageVotes() external {
        _initializeAverageVotes();
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function moveVotes(address from, address to, uint256 amount) external {
        _moveDelegateVotes(from, to, amount);
    }

    function clock() public view virtual override returns (uint48) {
        return Time.timestamp();
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }
}

contract OffsetClockAverageVotesTokenHarness is AverageVotesTokenHarness {
    function clock() public view override returns (uint48) {
        return super.clock() + 1 days;
    }
}

contract ERC20AverageVotesTest is Test {
    AverageVotesTokenHarness private token;
    address private constant ALICE = address(0xa11ce);
    address private constant BOB = address(0xb0b);
    bytes32 private constant INTEGRAL_SLOT = 0x6c8ef2534ba8916a427dbfc162fbce2a165f7cccf4d86d45f25d2b245ed73b00;

    function setUp() public {
        vm.warp(1000);
        token = new AverageVotesTokenHarness();
        token.initializeAverageVotes();
        vm.prank(ALICE);
        token.delegate(ALICE);
    }

    function test_activationAndUpdatesUseTokenClock() public {
        token = new OffsetClockAverageVotesTokenHarness();
        vm.prank(ALICE);
        token.delegate(ALICE);
        token.mint(ALICE, 10);

        vm.warp(block.timestamp + 100);
        token.initializeAverageVotes();
        uint256 start = token.clock();

        vm.warp(block.timestamp + 100);
        token.mint(ALICE, 10);
        vm.warp(block.timestamp + 100);

        assertEq(token.getPastAverageVotes(ALICE, start - 100, start), 0);
        assertEq(token.getPastAverageVotes(ALICE, start, token.clock()), 15);
        assertEq(token.getPastAverageVotes(ALICE, start - 100, token.clock()), 10);
    }

    function test_emptyHistoryAndZeroVoteIntervals() public {
        assertEq(token.getPastAverageVotes(ALICE, 0, block.timestamp), 0);
        token.mint(ALICE, 10);
        vm.warp(1100);
        token.burn(ALICE, 10);
        vm.warp(1300);
        token.mint(ALICE, 20);
        vm.warp(1400);
        assertEq(token.getPastAverageVotes(ALICE, 0, 999), 0);
        assertEq(token.getPastAverageVotes(ALICE, 0, 1000), 0);
        assertEq(token.getPastAverageVotes(ALICE, 1000, 1050), 10);
        assertEq(token.getPastAverageVotes(ALICE, 1000, 1200), 5);
        assertEq(token.getPastAverageVotes(ALICE, 1000, 1350), 5);
        assertEq(token.getPastAverageVotes(ALICE, 1000, 1400), 7);
        assertEq(token.getPastVotes(ALICE, 1200), 0);
        assertEq(token.getPastVotes(ALICE, 1350), 20);
    }

    function test_zeroAreaAndMissingHistoryBothReturnZero() public {
        token.mint(ALICE, 10);
        token.burn(ALICE, 10);
        vm.warp(1100);
        assertEq(token.getPastAverageVotes(ALICE, 0, 999), 0);
        assertEq(token.getPastAverageVotes(BOB, 0, 1100), 0);
        assertEq(token.getPastAverageVotes(ALICE, 0, 1000), 0);
        assertEq(token.getPastAverageVotes(ALICE, 0, 1100), 0);

        token.mint(ALICE, 20);
        vm.warp(1200);
        assertEq(token.getPastAverageVotes(ALICE, 1000, 1200), 10);
        assertEq(token.getPastAverageVotes(ALICE, 1100, 1200), 20);
    }

    function test_sameTimestampUpdatesPreserveCumulative() public {
        token.mint(ALICE, 10);
        vm.warp(1100);
        token.mint(ALICE, 5);
        token.burn(ALICE, 3);
        token.mint(ALICE, 8);
        assertEq(token.numCheckpoints(ALICE), 2);
        assertEq(token.getPastAverageVotes(ALICE, 1000, 1100), 10);
        vm.warp(1200);
        assertEq(token.getPastAverageVotes(ALICE, 1000, 1200), 15);
        assertEq(token.getPastVotes(ALICE, 1100), 20);
    }

    function test_noopMovementsDoNotCreateCheckpoints() public {
        token.mint(ALICE, 10);
        vm.warp(1100);
        vm.startPrank(ALICE);
        token.delegate(ALICE);
        token.transfer(BOB, 0);
        token.transfer(ALICE, 5);
        vm.stopPrank();
        vm.prank(BOB);
        token.delegate(ALICE);
        vm.prank(ALICE);
        token.transfer(BOB, 5);
        assertEq(token.numCheckpoints(ALICE), 1);
        assertEq(token.numCheckpoints(BOB), 0);
        assertEq(token.getPastAverageVotes(ALICE, 1000, 1100), 10);
    }

    function test_redelegationAndUndelegatedTransfers() public {
        token.mint(ALICE, 10);
        vm.warp(1100);
        vm.prank(ALICE);
        token.transfer(BOB, 4);
        vm.warp(1200);
        vm.prank(BOB);
        token.delegate(BOB);
        vm.warp(1300);
        vm.prank(ALICE);
        token.delegate(BOB);
        vm.warp(1400);
        assertEq(token.getVotes(ALICE), 0);
        assertEq(token.getVotes(BOB), 10);
        assertEq(token.getPastAverageVotes(ALICE, 1000, 1400), 5);
        assertEq(token.getPastAverageVotes(BOB, 1000, 1400), 3);
    }

    function test_maximumIntegralFits() public {
        vm.warp(1);
        token = new AverageVotesTokenHarness();
        token.initializeAverageVotes();
        vm.prank(ALICE);
        token.delegate(ALICE);
        token.mint(ALICE, type(uint208).max);
        vm.warp(type(uint48).max);
        uint256 expected = uint256(type(uint208).max) * (type(uint48).max - 1);
        assertEq(token.getPastAverageVotes(ALICE, 1, block.timestamp), type(uint208).max);
        token.burn(ALICE, type(uint208).max);
        token.mint(ALICE, type(uint208).max);
        assertEq(token.getPastAverageVotes(ALICE, 1, block.timestamp), type(uint208).max);
        assertEq(token.numCheckpoints(ALICE), 2);
        assertEq(uint256(vm.load(address(token), _entry(ALICE, 1))), expected);
    }

    function test_extrapolationCannotWrap() public {
        token.mint(ALICE, type(uint208).max);
        assertEq(token.getPastAverageVotes(ALICE, 1000, 1001), uint256(type(uint208).max));
        vm.expectRevert(stdError.arithmeticError);
        token.getPastAverageVotes(ALICE, 0, type(uint256).max);
    }

    function test_failedOZVoteMovementRollsBackIntegralEntries() public {
        token.mint(ALICE, 10);
        vm.warp(1100);
        vm.expectRevert(stdError.arithmeticError);
        token.moveVotes(ALICE, BOB, 11);
        assertEq(vm.load(address(token), _entry(ALICE, 1)), bytes32(0));
        assertEq(vm.load(address(token), _entry(BOB, 0)), bytes32(0));
        assertEq(token.numCheckpoints(ALICE), 1);
        assertEq(token.getPastAverageVotes(ALICE, 1000, 1100), 10);
    }

    function test_uninitializedHistoryIsZeroAndLateInitializationDoesNotBackfill() public {
        token = new AverageVotesTokenHarness();
        vm.prank(ALICE);
        token.delegate(ALICE);
        token.mint(ALICE, 10);
        vm.warp(1100);
        token.mint(ALICE, 5);

        assertEq(token.getPastAverageVotes(ALICE, 0, 1100), 0);
        assertEq(vm.load(address(token), _entry(ALICE, 1)), bytes32(0));

        token.initializeAverageVotes();
        assertEq(token.getPastAverageVotes(ALICE, 0, 1100), 0);
        vm.warp(1200);
        assertEq(token.getPastAverageVotes(ALICE, 1100, 1200), 15);

        token.burn(ALICE, 5);
        vm.warp(1300);
        assertEq(token.getPastAverageVotes(ALICE, 1100, 1300), 12);
    }

    function test_activationCannotReset() public {
        vm.warp(block.timestamp + 100);

        vm.expectRevert(VoteIntegralLib.AverageVotes__AlreadyInitialized.selector);
        token.initializeAverageVotes();
    }

    function test_rangesClipActivationAndFollowVoteChanges() public {
        token = new AverageVotesTokenHarness();
        vm.prank(ALICE);
        token.delegate(ALICE);
        token.mint(ALICE, 10);
        vm.warp(1100);
        token.initializeAverageVotes();
        vm.warp(1200);
        token.mint(ALICE, 10);
        vm.warp(1300);
        token.burn(ALICE, 20);
        vm.warp(1400);

        assertEq(token.getPastAverageVotes(ALICE, 900, 1050), 0);
        assertEq(token.getPastAverageVotes(ALICE, 900, 1100), 0);
        assertEq(token.getPastAverageVotes(ALICE, 1050, 1150), 5);
        assertEq(token.getPastAverageVotes(ALICE, 1100, 1200), 10);
        assertEq(token.getPastAverageVotes(ALICE, 1150, 1250), 15);
        assertEq(token.getPastAverageVotes(ALICE, 1200, 1300), 20);
        assertEq(token.getPastAverageVotes(ALICE, 1050, 1350), 10);
        assertEq(token.getPastAverageVotes(ALICE, 1300, 1400), 0);
    }

    function test_rangeBounds() public {
        token.mint(ALICE, type(uint208).max);
        assertEq(token.getPastAverageVotes(ALICE, 999, 999), 0);
        assertEq(token.getPastAverageVotes(ALICE, 1000, 1000), 0);
        assertEq(token.getPastAverageVotes(ALICE, type(uint256).max, type(uint256).max), 0);
        vm.expectRevert(IAverageVotes.AverageVotes__InvalidTimeRange.selector);
        token.getPastAverageVotes(ALICE, 1001, 1000);

        token = new AverageVotesTokenHarness();
        assertEq(token.getPastAverageVotes(ALICE, 1000, 1200), 0);
        vm.expectRevert(IAverageVotes.AverageVotes__InvalidTimeRange.selector);
        token.getPastAverageVotes(ALICE, 999, 998);
    }

    function test_sameTimestampActivationStoresRawZero() public {
        assertEq(vm.load(address(token), _entry(ALICE, 0)), bytes32(0));
        token.mint(ALICE, 10);
        assertEq(vm.load(address(token), _entry(ALICE, 0)), bytes32(0));
        token.mint(ALICE, 5);
        assertEq(vm.load(address(token), _entry(ALICE, 0)), bytes32(0));

        vm.warp(1001);
        assertEq(token.getPastAverageVotes(ALICE, 1000, 1001), 15);
    }

    function test_redelegationHalfwayConservesAverageWeight() public {
        token.mint(ALICE, 100);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(ALICE);
        token.delegate(BOB);
        vm.warp(block.timestamp + 6 hours);

        uint256 aliceAverage = token.getPastAverageVotes(ALICE, 1000, block.timestamp);
        uint256 bobAverage = token.getPastAverageVotes(BOB, 1000, block.timestamp);
        assertEq(aliceAverage, 50);
        assertEq(bobAverage, 50);
        assertEq(aliceAverage + bobAverage, 100);
    }

    function test_dustMovementDoesNotResetOrEraseArea() public {
        token.mint(ALICE, 100);
        vm.warp(block.timestamp + 6 hours);
        token.mint(ALICE, 1);
        token.burn(ALICE, 1);
        vm.warp(block.timestamp + 6 hours);

        assertEq(token.getPastAverageVotes(ALICE, 1000, block.timestamp), 100);
    }

    function test_firstCheckpointBoundary() public {
        vm.warp(1100);
        token.mint(BOB, 10);
        vm.prank(BOB);
        token.delegate(BOB);

        assertEq(token.getPastAverageVotes(BOB, 0, 1099), 0);
        assertEq(token.getPastAverageVotes(BOB, 0, 1100), 0);
        assertEq(token.getPastAverageVotes(BOB, 1100, 1101), 10);
    }

    function testFuzz_averageMatchesSegmentSum(uint208[12] memory values, uint32[12] memory elapsed, uint256 seed)
        public
    {
        token = new AverageVotesTokenHarness();
        vm.prank(ALICE);
        token.delegate(ALICE);

        uint256[12] memory times;
        uint256 timestamp = block.timestamp;
        uint256 activationIndex = seed % values.length;
        uint256 activation;
        for (uint256 i; i < values.length; ++i) {
            timestamp += elapsed[i] % 1 days;
            vm.warp(timestamp);
            times[i] = timestamp;
            if (i == activationIndex) {
                activation = timestamp;
                token.initializeAverageVotes();
            }
            uint256 balance = token.balanceOf(ALICE);
            if (values[i] >= balance) {
                token.mint(ALICE, values[i] - balance);
            } else {
                token.burn(ALICE, balance - values[i]);
            }
        }
        vm.warp(timestamp + 1);
        uint256 query = bound(seed, 999, timestamp);
        uint256 rangeStart = bound(uint256(keccak256(abi.encode(seed))), 0, query);
        uint256 expected;
        uint256 expectedVotes;
        for (uint256 i; i < values.length; ++i) {
            if (query < times[i]) {
                break;
            }
            uint256 end = i + 1 < values.length ? times[i + 1] : query;
            if (end > query) {
                end = query;
            }
            uint256 start = times[i] > activation ? times[i] : activation;
            if (start < rangeStart) {
                start = rangeStart;
            }
            if (end > start && query > activation) {
                expected += uint256(values[i]) * (end - start);
            }
            expectedVotes = values[i];
        }
        if (query > rangeStart) {
            expected /= query - rangeStart;
        }
        assertEq(token.getPastAverageVotes(ALICE, rangeStart, query), expected);
        assertEq(token.getPastVotes(ALICE, query), expectedVotes);
        assertEq(token.getVotes(ALICE), values[11]);
    }

    function test_averageSupplyWeightsSupplyChanges() public {
        AverageVotesTokenHarness legacy = new AverageVotesTokenHarness();
        legacy.mint(ALICE, 100);
        legacy.initializeAverageVotes();

        vm.warp(1100);
        legacy.mint(BOB, 900);
        vm.warp(1200);

        assertEq(legacy.getPastAverageSupply(900, 1200), 400);
        assertEq(legacy.getPastAverageSupply(1100, 1200), 1000);
        assertEq(legacy.getPastAverageSupply(1200, 1200), 0);

        vm.expectRevert(IAverageVotes.AverageVotes__InvalidTimeRange.selector);
        legacy.getPastAverageSupply(1201, 1200);
    }

    function test_zeroSupplyUpdatesPreserveCumulativeSupply() public {
        token.mint(ALICE, 100);

        vm.warp(1100);
        token.mint(BOB, 0);
        assertEq(token.getPastAverageSupply(1000, 1100), 100);

        vm.warp(1200);
        token.burn(ALICE, 0);
        vm.warp(1300);
        assertEq(token.getPastAverageSupply(1000, 1300), 100);
    }

    function _entry(address account, uint32 index) private pure returns (bytes32) {
        return keccak256(abi.encode(index, keccak256(abi.encode(account, INTEGRAL_SLOT))));
    }
}
