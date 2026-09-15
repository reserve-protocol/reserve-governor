// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { VoteIntegralLib } from "@staking/lib/VoteIntegralLib.sol";

contract VoteIntegralLibTest is Test {
    address private constant ACCOUNT = address(1);
    VoteIntegralLib.Storage private store;

    function testFuzz_integralMatchesSegmentSum(uint208[4] memory values, uint48[4] memory times, uint48 query) public {
        // Sort timestamps; equal times exercise coalescing with independently varying values.
        for (uint256 i = 1; i < times.length; ++i) {
            for (uint256 j = i; j > 0 && times[j] < times[j - 1]; --j) {
                (times[j - 1], times[j]) = (times[j], times[j - 1]);
            }
        }

        uint208 previous;
        for (uint256 i; i < times.length; ++i) {
            _setVotes(previous, values[i], times[i]);
            previous = values[i];
        }

        // Checked arithmetic, independently integrating each segment up to the query.
        uint256 expected;
        for (uint256 i; i < times.length && times[i] < query; ++i) {
            uint256 end = i + 1 < times.length && times[i + 1] < query ? times[i + 1] : query;
            expected += uint256(values[i]) * (end - times[i]);
        }
        assertEq(VoteIntegralLib.lookup(store, ACCOUNT, query), expected);
    }

    function test_integralAtMaximumValueAndTimestamp() public {
        uint208 maxVotes = type(uint208).max;
        uint48 lastTimestamp = type(uint48).max;
        _setVotes(0, maxVotes, 0);
        _setVotes(maxVotes, maxVotes - 1, lastTimestamp - 1);
        _setVotes(maxVotes - 1, maxVotes, lastTimestamp - 1);
        _setVotes(maxVotes, 0, lastTimestamp);

        assertEq(store.observations[ACCOUNT].length, 3);
        uint256 expected = uint256(maxVotes) * lastTimestamp;
        assertEq(store.observations[ACCOUNT][2].cumulative, expected);
        assertEq(VoteIntegralLib.lookup(store, ACCOUNT, lastTimestamp), expected);
        assertEq(VoteIntegralLib.lookup(store, ACCOUNT, lastTimestamp - 1), uint256(maxVotes) * (lastTimestamp - 1));
    }

    function test_longHistoryAppendCoalesceAndLookup() public {
        for (uint208 i = 1; i <= 64; ++i) {
            _setVotes(i - 1, i, uint48(i * 10));
        }

        vm.cool(address(this));
        vm.startSnapshotGas("append");
        VoteIntegralLib.update(store, address(0), ACCOUNT, 1, 0, 64, 650);
        vm.stopSnapshotGas();
        assertEq(store.observations[ACCOUNT].length, 65);
        assertEq(store.observations[ACCOUNT][64].cumulative, 20_800);

        vm.cool(address(this));
        vm.startSnapshotGas("coalesce");
        VoteIntegralLib.update(store, address(0), ACCOUNT, 1, 0, 65, 650);
        vm.stopSnapshotGas();
        assertEq(store.observations[ACCOUNT].length, 65);
        assertEq(store.observations[ACCOUNT][64].value, 66);
        assertEq(store.observations[ACCOUNT][64].cumulative, 20_800);

        vm.cool(address(this));
        vm.startSnapshotGas("lookup");
        uint256 integral = VoteIntegralLib.lookup(store, ACCOUNT, 455);
        vm.stopSnapshotGas();
        assertEq(integral, 10_125);
        assertEq(VoteIntegralLib.lookup(store, ACCOUNT, 9), 0);
        assertEq(VoteIntegralLib.lookup(store, ACCOUNT, 10), 0);
        assertEq(VoteIntegralLib.lookup(store, ACCOUNT, 650), 20_800);
        assertEq(VoteIntegralLib.lookup(store, ACCOUNT, 655), 21_130);
    }

    function _setVotes(uint208 beforeValue, uint208 afterValue, uint48 timestamp) private {
        if (afterValue >= beforeValue) {
            VoteIntegralLib.update(store, address(0), ACCOUNT, afterValue - beforeValue, 0, beforeValue, timestamp);
        } else {
            VoteIntegralLib.update(store, ACCOUNT, address(0), beforeValue - afterValue, beforeValue, 0, timestamp);
        }
    }
}
