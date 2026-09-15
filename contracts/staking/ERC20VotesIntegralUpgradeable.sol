// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IVotesIntegral } from "@interfaces/IVotesIntegral.sol";
import {
    ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/**
 * @title ERC20 Votes Integral
 * @notice Tracks cumulative delegated vote-seconds alongside the standard OZ checkpoints.
 * @dev Requires a timestamp clock. Existing checkpoints retain their packed layout and are not backfilled.
 *      Tracking starts at each delegate's first nonzero vote movement after upgrading to this extension.
 */
abstract contract ERC20VotesIntegralUpgradeable is ERC20VotesUpgradeable, IVotesIntegral {
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

    /// @notice Returns cumulative delegated vote-seconds at a timestamp, including the current timestamp.
    /// @dev Returns zero before tracking starts. Uses the same timestamps and vote values as getPastVotes.
    function getPastVotesIntegral(address account, uint256 timepoint) external view returns (uint256) {
        uint256 low;
        uint256 high = _numCheckpoints(account);
        // The search bounds are uint32 checkpoint counts, so index arithmetic cannot overflow.
        unchecked {
            while (low < high) {
                uint256 mid = (low + high) / 2;
                if (_checkpoints(account, uint32(mid))._key <= timepoint) {
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
        Checkpoints.Checkpoint208 memory checkpoint = _checkpoints(account, uint32(low));
        // The sentinel is nonzero and the search selected a checkpoint at or before timepoint.
        unchecked {
            --cumulative;
            timepoint -= checkpoint._key;
        }
        // Keep extrapolation checked: callers can supply timestamps beyond the uint48 clock domain.
        return cumulative + uint256(checkpoint._value) * timepoint;
    }

    function _moveDelegateVotes(address from, address to, uint256 amount) internal virtual override {
        if (from != to && amount != 0) {
            uint48 timestamp = clock();
            if (from != address(0)) {
                _recordIntegral(from, timestamp);
            }
            if (to != address(0)) {
                _recordIntegral(to, timestamp);
            }
        }
        // OZ appends or coalesces exactly the checkpoint whose integral was recorded above.
        // Its supply, vote and clock checks also apply to the integral; failures revert both updates.
        super._moveDelegateVotes(from, to, amount);
    }

    function _recordIntegral(address account, uint48 timestamp) private {
        mapping(uint256 => uint256) storage cumulatives = _getVotesIntegralStorage().cumulative[account];
        uint256 index = _numCheckpoints(account);
        uint256 cumulative = 1;
        if (index != 0) {
            // OZ uses nondecreasing uint48 timestamps and uint208 votes. Even the maximum integral
            // plus our sentinel fits uint256: (2^208 - 1) * (2^48 - 1) + 1 < 2^256.
            unchecked {
                Checkpoints.Checkpoint208 memory last = _checkpoints(account, uint32(index - 1));
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
