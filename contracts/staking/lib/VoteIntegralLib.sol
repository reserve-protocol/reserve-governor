// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title VoteIntegralLib
 * @notice Bounded cumulative vote-power observations for time-weighted averages.
 *
 * The ring is updated by the token whenever a standard delegate's voting power
 * changes.  Keeping the last balance alongside the observations lets us add
 * the elapsed area without walking the token's unbounded ERC20Votes history.
 */
library VoteIntegralLib {
    // One observation per second is the densest possible history. This ring
    // therefore always retains a full 12-hour lookback.
    uint24 internal constant MAX_OBSERVATIONS = 43_201;

    // The optimistic VotesUpgradeable namespace never uses its `_totalCheckpoints`
    // member. Reuse that member's slot for the integral mapping without shifting
    // storage in contracts that inherit ERC20OptimisticVotesUpgradeable.
    // keccak256(abi.encode(uint256(keccak256("reserve.storage.OptimisticVotes")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OPTIMISTIC_VOTES_STORAGE_LOCATION =
        0x70984a7d0b69c3ed645329f33455608f063bcf2582315816bc9835f4d0581600;
    error VoteIntegral__InsufficientHistory(uint256 timepoint);

    struct Observation {
        uint48 timestamp;
        uint256 cumulativeIntegral;
    }

    struct Account {
        // These fields fit in one slot.  `index` points at the newest observation.
        uint24 index;
        uint24 cardinality;
        uint208 lastBalance;
        Observation[MAX_OBSERVATIONS] observations;
    }

    struct Storage {
        mapping(address account => Account) accounts;
    }

    /// @dev Record a vote-power change. Calls in one timestamp coalesce.
    function record(Storage storage $, address account, uint208 balance) private {
        Account storage a = $.accounts[account];
        uint48 timestamp = uint48(block.timestamp);

        if (a.cardinality == 0) {
            a.cardinality = 1;
            a.observations[0] = Observation(timestamp, 0);
            a.lastBalance = balance;
            return;
        }

        Observation storage latest = a.observations[a.index];
        if (latest.timestamp == timestamp) {
            // No time elapsed, so only the balance used by the next interval changes.
            a.lastBalance = balance;
            return;
        }

        uint256 elapsed = timestamp - latest.timestamp;
        uint256 cumulative = latest.cumulativeIntegral + uint256(a.lastBalance) * elapsed;

        uint24 next = a.index + 1;
        if (next == MAX_OBSERVATIONS) {
            next = 0;
        }
        a.index = next;
        if (a.cardinality < MAX_OBSERVATIONS) {
            ++a.cardinality;
        }
        a.observations[next] = Observation(timestamp, cumulative);
        a.lastBalance = balance;
    }

    function recordPair(address from, uint208 fromBalance, address to, uint208 toBalance) external {
        Storage storage $ = _storage();
        if (from == to) {
            if (from != address(0)) {
                record($, from, fromBalance);
            }
            return;
        }
        if (from != address(0)) {
            record($, from, fromBalance);
        }
        if (to != address(0)) {
            record($, to, toBalance);
        }
    }

    /// @dev Return cumulative vote-power integral at `timepoint`.
    function getIntegral(address account, uint256 timepoint) external view returns (uint256) {
        Account storage a = _storage().accounts[account];
        uint24 cardinality = a.cardinality;
        if (cardinality == 0) {
            revert VoteIntegral__InsufficientHistory(timepoint);
        }

        uint48 timestamp = uint48(timepoint);
        uint24 newestIndex = a.index;
        Observation storage newest = a.observations[newestIndex];

        if (timestamp >= newest.timestamp) {
            return newest.cumulativeIntegral + uint256(a.lastBalance) * (timestamp - newest.timestamp);
        }

        uint24 oldestIndex = cardinality == MAX_OBSERVATIONS ? newestIndex + 1 : 0;
        if (oldestIndex == MAX_OBSERVATIONS) {
            oldestIndex = 0;
        }
        Observation storage oldest = a.observations[oldestIndex];
        if (timestamp < oldest.timestamp) {
            revert VoteIntegral__InsufficientHistory(timepoint);
        }

        // Binary-search the chronological virtual array. This keeps proposal
        // gas logarithmic even when the ring is full.
        uint24 low;
        uint24 high = cardinality - 1;
        while (low < high) {
            uint24 mid = uint24((uint48(low) + uint48(high) + 1) / 2);
            if (_observationAt(a, oldestIndex, mid).timestamp <= timestamp) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        Observation storage current = _observationAt(a, oldestIndex, low);
        if (current.timestamp == timestamp || low + 1 == cardinality) {
            return current.cumulativeIntegral;
        }

        // The area between two observations is constant balance. Deriving it
        // from the cumulative delta keeps each observation in one storage slot.
        Observation storage next = _observationAt(a, oldestIndex, low + 1);
        uint256 elapsed = next.timestamp - current.timestamp;
        uint256 balance = (next.cumulativeIntegral - current.cumulativeIntegral) / elapsed;
        return current.cumulativeIntegral + balance * (timestamp - current.timestamp);
    }

    function _observationAt(Account storage a, uint24 oldestIndex, uint24 offset)
        private
        view
        returns (Observation storage observation)
    {
        uint32 index = uint32(oldestIndex) + uint32(offset);
        if (index >= MAX_OBSERVATIONS) {
            index -= MAX_OBSERVATIONS;
        }
        observation = a.observations[index];
    }

    function _storage() private pure returns (Storage storage $) {
        assembly {
            $.slot := add(OPTIMISTIC_VOTES_STORAGE_LOCATION, 2)
        }
    }
}
