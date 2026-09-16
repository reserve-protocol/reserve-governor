// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Time } from "@openzeppelin/contracts/utils/types/Time.sol";
import { ERC20VotesIntegralUpgradeable } from "@staking/ERC20VotesIntegralUpgradeable.sol";
import { VoteIntegralLib } from "@staking/lib/VoteIntegralLib.sol";
import { stdError } from "forge-std/StdError.sol";
import { Test } from "forge-std/Test.sol";

contract IntegralTokenHarness is ERC20VotesIntegralUpgradeable {
    function initializeVoteIntegral() external {
        _initializeVoteIntegral();
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

    function clock() public view override returns (uint48) {
        return Time.timestamp();
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }
}

contract ERC20VotesIntegralTest is Test {
    IntegralTokenHarness private token;
    address private constant ALICE = address(0xa11ce);
    address private constant BOB = address(0xb0b);
    bytes32 private constant INTEGRAL_SLOT = 0x6c8ef2534ba8916a427dbfc162fbce2a165f7cccf4d86d45f25d2b245ed73b00;

    function setUp() public {
        vm.warp(1000);
        token = new IntegralTokenHarness();
        token.initializeVoteIntegral();
        vm.prank(ALICE);
        token.delegate(ALICE);
    }

    function test_emptyHistoryAndZeroVoteIntervals() public {
        assertEq(token.getPastVotesIntegral(ALICE, block.timestamp), 0);
        token.mint(ALICE, 10);
        vm.warp(1100);
        token.burn(ALICE, 10);
        vm.warp(1300);
        token.mint(ALICE, 20);
        vm.warp(1400);
        assertEq(token.getPastVotesIntegral(ALICE, 999), 0);
        assertEq(token.getPastVotesIntegral(ALICE, 1000), 0);
        assertEq(token.getPastVotesIntegral(ALICE, 1050), 500);
        assertEq(token.getPastVotesIntegral(ALICE, 1200), 1000);
        assertEq(token.getPastVotesIntegral(ALICE, 1350), 2000);
        assertEq(token.getPastVotesIntegral(ALICE, 1400), 3000);
        assertEq(token.getPastVotes(ALICE, 1200), 0);
        assertEq(token.getPastVotes(ALICE, 1350), 20);
    }

    function test_zeroAreaAndMissingHistoryBothReturnZero() public {
        token.mint(ALICE, 10);
        token.burn(ALICE, 10);
        vm.warp(1100);
        assertEq(token.getPastVotesIntegral(ALICE, 999), 0);
        assertEq(token.getPastVotesIntegral(BOB, 1100), 0);
        assertEq(token.getPastVotesIntegral(ALICE, 1000), 0);
        assertEq(token.getPastVotesIntegral(ALICE, 1100), 0);

        token.mint(ALICE, 20);
        vm.warp(1200);
        uint256 startIntegral = token.getPastVotesIntegral(ALICE, 1000);
        uint256 endIntegral = token.getPastVotesIntegral(ALICE, 1200);
        assertEq(endIntegral, 2000);
        assertEq(endIntegral - startIntegral, 20 * 100);
    }

    function test_sameTimestampUpdatesPreserveCumulative() public {
        token.mint(ALICE, 10);
        vm.warp(1100);
        token.mint(ALICE, 5);
        token.burn(ALICE, 3);
        token.mint(ALICE, 8);
        assertEq(token.numCheckpoints(ALICE), 2);
        assertEq(token.getPastVotesIntegral(ALICE, 1100), 1000);
        vm.warp(1200);
        assertEq(token.getPastVotesIntegral(ALICE, 1200), 3000);
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
        assertEq(token.getPastVotesIntegral(ALICE, 1100), 1000);
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
        assertEq(token.getPastVotesIntegral(ALICE, 1400), 2200);
        assertEq(token.getPastVotesIntegral(BOB, 1400), 1400);
    }

    function test_maximumIntegralFits() public {
        vm.warp(0);
        token = new IntegralTokenHarness();
        token.initializeVoteIntegral();
        vm.prank(ALICE);
        token.delegate(ALICE);
        token.mint(ALICE, type(uint208).max);
        vm.warp(type(uint48).max);
        uint256 expected = uint256(type(uint208).max) * type(uint48).max;
        assertEq(token.getPastVotesIntegral(ALICE, block.timestamp), expected);
        token.burn(ALICE, type(uint208).max);
        token.mint(ALICE, type(uint208).max);
        assertEq(token.getPastVotesIntegral(ALICE, block.timestamp), expected);
        assertEq(token.numCheckpoints(ALICE), 2);
        assertEq(uint256(vm.load(address(token), _entry(ALICE, 1))), expected);
    }

    function test_extrapolationCannotWrap() public {
        token.mint(ALICE, type(uint208).max);
        assertEq(token.getPastVotesIntegral(ALICE, 1001), uint256(type(uint208).max));
        vm.expectRevert(stdError.arithmeticError);
        token.getPastVotesIntegral(ALICE, type(uint256).max);
    }

    function test_failedOZVoteMovementRollsBackIntegralEntries() public {
        token.mint(ALICE, 10);
        vm.warp(1100);
        vm.expectRevert(stdError.arithmeticError);
        token.moveVotes(ALICE, BOB, 11);
        assertEq(vm.load(address(token), _entry(ALICE, 1)), bytes32(0));
        assertEq(vm.load(address(token), _entry(BOB, 0)), bytes32(0));
        assertEq(token.numCheckpoints(ALICE), 1);
        assertEq(token.getPastVotesIntegral(ALICE, 1100), 1000);
    }

    function test_uninitializedHistoryIsZeroAndLateInitializationDoesNotBackfill() public {
        token = new IntegralTokenHarness();
        vm.prank(ALICE);
        token.delegate(ALICE);
        token.mint(ALICE, 10);
        vm.warp(1100);
        token.mint(ALICE, 5);

        assertEq(token.getPastVotesIntegral(ALICE, 1100), 0);
        assertEq(vm.load(address(token), _entry(ALICE, 1)), bytes32(0));

        token.initializeVoteIntegral();
        assertEq(token.getPastVotesIntegral(ALICE, 1100), 0);
        vm.warp(1200);
        assertEq(token.getPastVotesIntegral(ALICE, 1200), 1500);

        token.burn(ALICE, 5);
        vm.warp(1300);
        assertEq(token.getPastVotesIntegral(ALICE, 1300), 2500);
    }

    function test_cannotResetActivationInitializedAtTimestampZero() public {
        vm.warp(0);
        token = new IntegralTokenHarness();
        token.initializeVoteIntegral();

        vm.warp(100);
        vm.expectRevert(VoteIntegralLib.VoteIntegral__AlreadyInitialized.selector);
        token.initializeVoteIntegral();
    }

    function test_sameTimestampActivationStoresRawZero() public {
        assertEq(vm.load(address(token), _entry(ALICE, 0)), bytes32(0));
        token.mint(ALICE, 10);
        assertEq(vm.load(address(token), _entry(ALICE, 0)), bytes32(0));
        token.mint(ALICE, 5);
        assertEq(vm.load(address(token), _entry(ALICE, 0)), bytes32(0));

        vm.warp(1001);
        assertEq(token.getPastVotesIntegral(ALICE, 1001), 15);
    }

    function test_redelegationHalfwayConservesVoteSeconds() public {
        token.mint(ALICE, 100);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(ALICE);
        token.delegate(BOB);
        vm.warp(block.timestamp + 6 hours);

        uint256 aliceIntegral = token.getPastVotesIntegral(ALICE, block.timestamp);
        uint256 bobIntegral = token.getPastVotesIntegral(BOB, block.timestamp);
        assertEq(aliceIntegral, 100 * 6 hours);
        assertEq(bobIntegral, 100 * 6 hours);
        assertEq(aliceIntegral + bobIntegral, 100 * 12 hours);
    }

    function test_dustMovementDoesNotResetOrEraseArea() public {
        token.mint(ALICE, 100);
        vm.warp(block.timestamp + 6 hours);
        token.mint(ALICE, 1);
        token.burn(ALICE, 1);
        vm.warp(block.timestamp + 6 hours);

        assertEq(token.getPastVotesIntegral(ALICE, block.timestamp), 100 * 12 hours);
    }

    function test_firstCheckpointBoundary() public {
        vm.warp(1100);
        token.mint(BOB, 10);
        vm.prank(BOB);
        token.delegate(BOB);

        assertEq(token.getPastVotesIntegral(BOB, 1099), 0);
        assertEq(token.getPastVotesIntegral(BOB, 1100), 0);
        assertEq(token.getPastVotesIntegral(BOB, 1101), 10);
    }

    function testFuzz_integralsMatchSegmentSum(uint208[12] memory values, uint32[12] memory elapsed, uint256 seed)
        public
    {
        token = new IntegralTokenHarness();
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
                token.initializeVoteIntegral();
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
            if (end > start && query > activation) {
                expected += uint256(values[i]) * (end - start);
            }
            expectedVotes = values[i];
        }
        assertEq(token.getPastVotesIntegral(ALICE, query), expected);
        assertEq(token.getPastVotes(ALICE, query), expectedVotes);
        assertEq(token.getVotes(ALICE), values[11]);
    }

    function _entry(address account, uint32 index) private pure returns (bytes32) {
        return keccak256(abi.encode(index, keccak256(abi.encode(account, INTEGRAL_SLOT))));
    }
}
