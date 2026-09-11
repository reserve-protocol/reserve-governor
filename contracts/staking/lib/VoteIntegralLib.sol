// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title Vote Integral Library
 * @notice Stores cumulative time integrals of delegated voting power.
 *
 * @dev An observation records the cumulative integral immediately before the
 *      value at `timestamp` became effective. Observations are append-only;
 *      updates made at the same timestamp coalesce into the latest entry.
 */
library VoteIntegralLib {
    struct Observation {
        uint48 timestamp;
        uint208 value;
        uint256 cumulative;
    }

    struct Storage {
        mapping(address account => Observation[]) observations;
    }

    function update(
        Storage storage store,
        address from,
        address to,
        uint256 amount,
        uint256 fromValue,
        uint256 toValue,
        uint256 timestamp
    ) external {
        unchecked {
            if (from != to && amount != 0) {
                if (from != address(0)) {
                    _update(store.observations[from], fromValue - amount, timestamp);
                }
                if (to != address(0)) {
                    _update(store.observations[to], toValue + amount, timestamp);
                }
            }
        }
    }

    function _update(Observation[] storage observations, uint256 newValue, uint256 timestamp) private {
        if (observations.length == 0) {
            observations.push(Observation(uint48(timestamp), uint208(newValue), 0));
            return;
        }

        Observation storage latest = observations[observations.length - 1];
        uint256 cumulative = latest.cumulative + uint256(latest.value) * (timestamp - latest.timestamp);

        if (latest.timestamp == timestamp) {
            // Multiple vote movements can happen in one timestamp. Keep one
            // observation and expose the final vote power for that timestamp.
            latest.value = uint208(newValue);
            latest.cumulative = cumulative;
        } else {
            observations.push(Observation(uint48(timestamp), uint208(newValue), cumulative));
        }
    }

    function lookup(Storage storage store, address account, uint256 timestamp)
        external
        view
        returns (uint256 integral)
    {
        Observation[] storage observations = store.observations[account];
        uint256 length = observations.length;
        if (length == 0 || timestamp < observations[0].timestamp) {
            return 0;
        }

        uint256 low;
        uint256 high = length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (observations[mid].timestamp <= timestamp) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        Observation storage observation = observations[low - 1];
        unchecked {
            return observation.cumulative + uint256(observation.value) * (timestamp - observation.timestamp);
        }
    }
}
