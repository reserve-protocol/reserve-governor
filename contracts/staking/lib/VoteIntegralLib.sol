// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { VotesUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/utils/VotesUpgradeable.sol";
import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/**
 * @title Vote Integral Library
 * @notice Tracks cumulative delegated vote-seconds alongside the standard OZ checkpoints.
 * @dev Requires a timestamp clock. Existing checkpoints retain their packed layout and are not backfilled.
 *      Tracking starts at each delegate's first nonzero vote movement after upgrading to this extension.
 */
library VoteIntegralLib {
    /// @custom:storage-location erc7201:reserve.storage.VotesIntegral
    struct VotesIntegralStorage {
        // Integral at the checkpoint timestamp, plus one. Zero means this checkpoint predates tracking.
        mapping(address account => mapping(uint256 index => uint256)) cumulative;
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

    /// @notice Returns cumulative delegated vote-seconds plus one, or zero for untracked history.
    /// @dev Preserves the tracking sentinel, including at zero area. Differences of tracked values are exact.
    function lookup(address account, uint256 timepoint) external view returns (uint256) {
        Checkpoints.Checkpoint208[] storage checkpoints = _delegateHistory(account);
        uint256 low;
        uint256 high = checkpoints.length;
        // At most one checkpoint per uint48 timestamp, so index arithmetic cannot overflow.
        unchecked {
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
        }

        uint256 cumulative = _getVotesIntegralStorage().cumulative[account][low];
        if (cumulative == 0) {
            return 0;
        }
        Checkpoints.Checkpoint208 storage checkpoint = checkpoints[low];
        // Preserve the sentinel so tracked zero area remains distinct from untracked history.
        // The search selected a checkpoint at or before timepoint.
        unchecked {
            timepoint -= checkpoint._key;
        }
        // Keep extrapolation checked: callers can supply timestamps beyond the uint48 clock domain.
        return cumulative + uint256(checkpoint._value) * timepoint;
    }

    /// @dev Must run by delegatecall immediately before the corresponding OZ vote movement, at clock().
    ///      The caller must retain OZ's uint208 supply/vote checks and nondecreasing uint48 timestamp checks.
    function update(address from, address to, uint256 amount, uint48 timestamp) external {
        if (from != to && amount != 0) {
            if (from != address(0)) {
                _recordIntegral(from, timestamp);
            }
            if (to != address(0)) {
                _recordIntegral(to, timestamp);
            }
        }
    }

    function _recordIntegral(address account, uint48 timestamp) private {
        mapping(uint256 => uint256) storage cumulatives = _getVotesIntegralStorage().cumulative[account];
        Checkpoints.Checkpoint208[] storage checkpoints = _delegateHistory(account);
        uint256 index = checkpoints.length;
        uint256 cumulative = 1;
        if (index != 0) {
            // OZ uses nondecreasing uint48 timestamps and uint208 votes. Even the maximum integral
            // plus our sentinel fits uint256: (2^208 - 1) * (2^48 - 1) + 1 < 2^256.
            unchecked {
                Checkpoints.Checkpoint208 storage last = checkpoints[index - 1];
                uint256 previous = cumulatives[index - 1];
                if (last._key == timestamp) {
                    if (previous != 0) {
                        return;
                    }
                    // The first tracked movement can coalesce into a pre-upgrade checkpoint.
                    --index;
                } else if (previous != 0) {
                    cumulative = previous + uint256(last._value) * (timestamp - last._key);
                }
            }
        }
        cumulatives[index] = cumulative;
    }
}
