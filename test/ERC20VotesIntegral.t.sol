// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Time } from "@openzeppelin/contracts/utils/types/Time.sol";
import { ERC20VotesIntegralUpgradeable } from "@staking/ERC20VotesIntegralUpgradeable.sol";
import { stdError } from "forge-std/StdError.sol";
import { Test } from "forge-std/Test.sol";

contract IntegralTokenHarness is ERC20VotesIntegralUpgradeable {
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
        assertEq(token.getPastVotesIntegral(ALICE, 1000), 1);
        assertEq(token.getPastVotesIntegral(ALICE, 1050), 501);
        assertEq(token.getPastVotesIntegral(ALICE, 1200), 1001);
        assertEq(token.getPastVotesIntegral(ALICE, 1350), 2001);
        assertEq(token.getPastVotesIntegral(ALICE, 1400), 3001);
        assertEq(token.getPastVotes(ALICE, 1200), 0);
        assertEq(token.getPastVotes(ALICE, 1350), 20);
    }

    function test_trackedZeroAreaRemainsDistinctFromMissingHistory() public {
        token.mint(ALICE, 10);
        token.burn(ALICE, 10);
        vm.warp(1100);
        assertEq(token.getPastVotesIntegral(ALICE, 999), 0);
        assertEq(token.getPastVotesIntegral(BOB, 1100), 0);
        assertEq(token.getPastVotesIntegral(ALICE, 1000), 1);
        assertEq(token.getPastVotesIntegral(ALICE, 1100), 1);

        token.mint(ALICE, 20);
        vm.warp(1200);
        uint256 startIntegral = token.getPastVotesIntegral(ALICE, 1000);
        uint256 endIntegral = token.getPastVotesIntegral(ALICE, 1200);
        assertEq(endIntegral, 2001);
        assertEq(endIntegral - startIntegral, 20 * 100);
    }

    function test_sameTimestampUpdatesPreserveCumulative() public {
        token.mint(ALICE, 10);
        vm.warp(1100);
        token.mint(ALICE, 5);
        token.burn(ALICE, 3);
        token.mint(ALICE, 8);
        assertEq(token.numCheckpoints(ALICE), 2);
        assertEq(token.getPastVotesIntegral(ALICE, 1100), 1001);
        vm.warp(1200);
        assertEq(token.getPastVotesIntegral(ALICE, 1200), 3001);
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
        assertEq(token.getPastVotesIntegral(ALICE, 1100), 1001);
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
        assertEq(token.getPastVotesIntegral(ALICE, 1400), 2201);
        assertEq(token.getPastVotesIntegral(BOB, 1400), 1401);
    }

    function test_maximumIntegralWithSentinelFits() public {
        vm.warp(0);
        token.mint(ALICE, type(uint208).max);
        vm.warp(type(uint48).max);
        uint256 expected = uint256(type(uint208).max) * type(uint48).max;
        assertEq(token.getPastVotesIntegral(ALICE, block.timestamp), expected + 1);
        token.burn(ALICE, type(uint208).max);
        token.mint(ALICE, type(uint208).max);
        assertEq(token.getPastVotesIntegral(ALICE, block.timestamp), expected + 1);
        assertEq(token.numCheckpoints(ALICE), 2);
        assertEq(uint256(vm.load(address(token), _entry(ALICE, 1))), expected + 1);
    }

    function test_extrapolationCannotWrap() public {
        token.mint(ALICE, type(uint208).max);
        assertEq(token.getPastVotesIntegral(ALICE, 1001), uint256(type(uint208).max) + 1);
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
        assertEq(token.getPastVotesIntegral(ALICE, 1100), 1001);
    }

    function testFuzz_integralsMatchSegmentSum(uint208[12] memory values, uint32[12] memory elapsed, uint256 seed)
        public
    {
        uint256[12] memory times;
        uint256 timestamp = block.timestamp;
        for (uint256 i; i < values.length; ++i) {
            timestamp += elapsed[i] % 1 days;
            vm.warp(timestamp);
            times[i] = timestamp;
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
        bool tracked;
        for (uint256 i; i < values.length; ++i) {
            if (query < times[i]) {
                break;
            }
            if (values[i] != 0) {
                tracked = true;
            }
            uint256 end = i + 1 < values.length ? times[i + 1] : query;
            if (end > query) {
                end = query;
            }
            expected += uint256(values[i]) * (end - times[i]);
            expectedVotes = values[i];
        }
        assertEq(token.getPastVotesIntegral(ALICE, query), tracked ? expected + 1 : 0);
        assertEq(token.getPastVotes(ALICE, query), expectedVotes);
        assertEq(token.getVotes(ALICE), values[11]);
    }

    function _entry(address account, uint32 index) private pure returns (bytes32) {
        return keccak256(abi.encode(index, keccak256(abi.encode(account, INTEGRAL_SLOT))));
    }
}
