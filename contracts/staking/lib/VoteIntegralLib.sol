// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { VotesUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/utils/VotesUpgradeable.sol";
import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import { Time } from "@openzeppelin/contracts/utils/types/Time.sol";

/**
 * @title Vote Integral Library
 * @notice Tracks cumulative delegated vote-seconds alongside the standard OZ checkpoints.
 * @dev Requires a block-timestamp clock. Existing checkpoints retain their packed layout and are not backfilled.
 *      Tracking starts globally at the vault's activation timestamp.
 */
library VoteIntegralLib {
    error VoteIntegral__AlreadyInitialized();
    error VoteIntegral__InvalidActivationTimestamp();
    error VoteIntegral__InvalidTimeRange();

    /// @custom:storage-location erc7201:reserve.storage.VotesIntegral
    struct VotesIntegralStorage {
        // Integral at the checkpoint timestamp. Entries before activation remain zero.
        mapping(address account => mapping(uint256 index => uint256)) cumulative;
        // Zero means accounting has not been activated.
        uint48 activation;
    }

    // keccak256(abi.encode(uint256(keccak256("reserve.storage.VotesIntegral")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VotesIntegralStorageLocation =
        0x6c8ef2534ba8916a427dbfc162fbce2a165f7cccf4d86d45f25d2b245ed73b00;

    function _getVotesIntegralStorage() private pure returns (VotesIntegralStorage storage $) {
        assembly {
            $.slot := VotesIntegralStorageLocation
        }
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Votes")) - 1)) & ~bytes32(uint256(0xff))
    // Matches OZ 5.4 VotesUpgradeable. Changes to that namespace or its checkpoint layout require review.
    bytes32 private constant VotesStorageLocation = 0xe8b26c30fad74198956032a3533d903385d56dd795af560196f9c78d4af40d00;

    // Read-only access: OZ remains responsible for writing standard vote checkpoints.
    function _delegateHistory(address account) private view returns (Checkpoints.Checkpoint208[] storage) {
        VotesUpgradeable.VotesStorage storage $;
        assembly {
            $.slot := VotesStorageLocation
        }
        return $._delegateCheckpoints[account]._checkpoints;
    }

    /// @notice Starts integral accounting at the current timestamp for every delegate.
    /// @dev Called only by the vault's authorized wrapper or during fresh vault initialization.
    function initialize() external {
        VotesIntegralStorage storage $ = _getVotesIntegralStorage();
        require($.activation == 0, VoteIntegral__AlreadyInitialized());
        uint48 timestamp = Time.timestamp();
        require(timestamp != 0, VoteIntegral__InvalidActivationTimestamp());
        $.activation = timestamp;
    }

    /// @notice Returns average delegated votes over [start, end), rounded down.
    /// @dev Time before activation contributes zero but remains part of the averaging period.
    function averageVotes(address account, uint256 start, uint256 end) external view returns (uint256) {
        require(start <= end, VoteIntegral__InvalidTimeRange());
        if (start == end) {
            return 0;
        }
        return (_lookup(account, end) - _lookup(account, start)) / (end - start);
    }

    // Cumulative accounting and activation clipping stay inside the token's library.
    function _lookup(address account, uint256 timepoint) private view returns (uint256) {
        VotesIntegralStorage storage $ = _getVotesIntegralStorage();
        if ($.activation == 0 || timepoint <= $.activation) {
            return 0;
        }

        Checkpoints.Checkpoint208[] storage checkpoints = _delegateHistory(account);
        uint256 low;
        uint256 high = checkpoints.length;
        // At most one checkpoint per uint48 timestamp, so index arithmetic cannot overflow.
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (checkpoints[mid]._key <= timepoint) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        if (low == 0) {
            return 0;
        }
        --low;

        Checkpoints.Checkpoint208 storage checkpoint = checkpoints[low];
        uint48 start = checkpoint._key > $.activation ? checkpoint._key : $.activation;
        // The search selected a checkpoint at or before timepoint, and timepoint is after activation.
        timepoint -= start;
        // Keep extrapolation checked: callers can supply timestamps beyond the uint48 clock domain.
        return $.cumulative[account][low] + uint256(checkpoint._value) * timepoint;
    }

    /// @dev Must run by delegatecall immediately before the corresponding OZ vote movement, using block time.
    ///      The caller must retain OZ's uint208 supply/vote checks and nondecreasing uint48 timestamp checks.
    function update(address from, address to, uint256 amount) external {
        VotesIntegralStorage storage $ = _getVotesIntegralStorage();
        if ($.activation != 0 && from != to && amount != 0) {
            uint48 timestamp = Time.timestamp();
            if (from != address(0)) {
                _recordIntegral($, from, timestamp);
            }
            if (to != address(0)) {
                _recordIntegral($, to, timestamp);
            }
        }
    }

    function _recordIntegral(VotesIntegralStorage storage $, address account, uint48 timestamp) private {
        mapping(uint256 => uint256) storage cumulatives = $.cumulative[account];
        Checkpoints.Checkpoint208[] storage checkpoints = _delegateHistory(account);
        uint256 index = checkpoints.length;
        uint256 cumulative;
        if (index != 0) {
            // One-shot current-clock initialization makes timestamp >= activation. Together with OZ's
            // nondecreasing uint48 timestamps and uint208 vote cap, this ensures the integral fits uint256.
            unchecked {
                Checkpoints.Checkpoint208 storage last = checkpoints[index - 1];
                if (last._key == timestamp) {
                    return;
                }
                uint48 start = last._key > $.activation ? last._key : $.activation;
                cumulative = cumulatives[index - 1] + uint256(last._value) * (timestamp - start);
            }
        }
        cumulatives[index] = cumulative;
    }
}
