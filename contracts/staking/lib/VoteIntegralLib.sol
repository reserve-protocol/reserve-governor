// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { VotesUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/utils/VotesUpgradeable.sol";
import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/**
 * @title Vote Integral Library
 * @notice Tracks cumulative delegated vote-seconds alongside the standard OZ checkpoints.
 * @dev Requires a block-timestamp clock. Existing checkpoints retain their packed layout and are not backfilled.
 *      Tracking starts globally at the vault's activation timestamp.
 */
library VoteIntegralLib {
    error AverageVotes__AlreadyInitialized();

    /// @custom:storage-location erc7201:reserve.storage.VotesIntegral
    struct VotesIntegralStorage {
        // Integral at the checkpoint timestamp. Entries before activation remain zero.
        mapping(address account => mapping(uint256 index => uint256)) cumulative;
        uint48 activation; // Zero means accounting has not been activated.
        uint208 activationSupply; // {tok} Total supply when accounting was activated.
        // Cumulative total-supply-seconds, indexed by the existing OZ supply checkpoints.
        mapping(uint256 index => uint256) supplyCumulative;
    }

    // keccak256(abi.encode(uint256(keccak256("reserve.storage.VotesIntegral")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VotesIntegralStorageLocation =
        0x6c8ef2534ba8916a427dbfc162fbce2a165f7cccf4d86d45f25d2b245ed73b00;

    function _getVotesIntegralStorage() private pure returns (VotesIntegralStorage storage $) {
        assembly {
            $.slot := VotesIntegralStorageLocation
        }
    }

    function _getVotesStorage() private pure returns (VotesUpgradeable.VotesStorage storage $) {
        assembly {
            $.slot := VotesStorageLocation
        }
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Votes")) - 1)) & ~bytes32(uint256(0xff))
    // Matches OZ 5.4 VotesUpgradeable. Changes to that namespace or its checkpoint layout require review.
    bytes32 private constant VotesStorageLocation = 0xe8b26c30fad74198956032a3533d903385d56dd795af560196f9c78d4af40d00;

    // Read-only access: OZ remains responsible for writing standard vote checkpoints.
    function _delegateHistory(address account) private view returns (Checkpoints.Checkpoint208[] storage) {
        VotesUpgradeable.VotesStorage storage $ = _getVotesStorage();
        return $._delegateCheckpoints[account]._checkpoints;
    }

    /// @notice Starts integral accounting at the current timestamp for every delegate.
    /// @dev Called only by the vault's authorized wrapper or during fresh vault initialization, passing clock().
    function initialize(uint48 timestamp, uint208 supply) external {
        VotesIntegralStorage storage $ = _getVotesIntegralStorage();

        require($.activation == 0, AverageVotes__AlreadyInitialized());

        $.activation = timestamp;
        $.activationSupply = supply;
    }

    /// @notice Returns cumulative delegated vote-seconds at a timestamp.
    /// @dev Time at or before activation contributes zero. Future extrapolation uses checked arithmetic.
    function lookup(address account, uint256 timepoint) external view returns (uint256) {
        return _lookup(account, timepoint);
    }

    function _lookup(address account, uint256 timepoint) private view returns (uint256) {
        VotesIntegralStorage storage $ = _getVotesIntegralStorage();
        return _lookupIntegral(_delegateHistory(account), $.cumulative[account], $.activation, timepoint);
    }

    function _supplyLookup(uint256 timepoint) private view returns (uint256) {
        VotesIntegralStorage storage $ = _getVotesIntegralStorage();
        return _lookupIntegral(_supplyHistory(), $.supplyCumulative, $.activation, timepoint);
    }

    /// @dev Returns the cumulative integral at `timepoint` for either history using one upper-bound search.
    function _lookupIntegral(
        Checkpoints.Checkpoint208[] storage checkpoints,
        mapping(uint256 => uint256) storage cumulatives,
        uint48 activation,
        uint256 timepoint
    ) private view returns (uint256) {
        if (activation == 0 || timepoint <= activation) {
            return 0;
        }

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
        uint48 start = checkpoint._key > activation ? checkpoint._key : activation;

        // Keep extrapolation checked: callers can supply timestamps beyond the uint48 clock domain.
        return cumulatives[low] + uint256(checkpoint._value) * (timepoint - start);
    }

    /// @notice Returns average total supply over `[start, end)`, including activation supply before activation.
    function lookupAverageSupply(uint256 start, uint256 end) external view returns (uint256) {
        if (start == end) {
            return 0;
        }

        uint256 supplySeconds = _supplyLookup(end) - _supplyLookup(start);

        VotesIntegralStorage storage $ = _getVotesIntegralStorage();
        if ($.activation != 0 && start < $.activation) {
            uint256 preActivationEnd = end < $.activation ? end : $.activation;
            supplySeconds += uint256($.activationSupply) * (preActivationEnd - start);
        }

        return supplySeconds / (end - start);
    }

    /// @dev Must run by delegatecall immediately before the corresponding OZ vote movement, passing clock().
    ///      The caller must retain OZ's uint208 supply/vote checks and nondecreasing uint48 timestamp checks.
    function update(address from, address to, uint256 amount, uint48 timestamp) external {
        VotesIntegralStorage storage $ = _getVotesIntegralStorage();

        if ($.activation != 0 && from != to && amount != 0) {
            if (from != address(0)) {
                _recordIntegral(_delegateHistory(from), $.cumulative[from], $.activation, timestamp, 0);
            }

            if (to != address(0)) {
                _recordIntegral(_delegateHistory(to), $.cumulative[to], $.activation, timestamp, 0);
            }
        }
    }

    /// @dev Records the pre-change total supply before OZ writes its checkpoint.
    ///      `newSupply` is the ERC20 total supply after the underlying update.
    function updateSupply(address from, address to, uint256 amount, uint256 newSupply, uint48 timestamp) external {
        VotesIntegralStorage storage $ = _getVotesIntegralStorage();

        if ($.activation == 0 || (from != address(0) && to != address(0)) || amount == 0) {
            return;
        }

        uint256 previousSupply = from == address(0) ? newSupply - amount : newSupply + amount;
        _recordIntegral(_supplyHistory(), $.supplyCumulative, $.activation, timestamp, previousSupply);
    }

    function _recordIntegral(
        Checkpoints.Checkpoint208[] storage checkpoints,
        mapping(uint256 => uint256) storage cumulatives,
        uint48 activation,
        uint48 timestamp,
        uint256 initialValue
    ) private {
        uint256 index = checkpoints.length;

        if (index == 0) {
            if (initialValue != 0) {
                cumulatives[0] = initialValue * (timestamp - activation);
            }
            return;
        }

        // One-shot current-clock initialization makes timestamp >= activation. Together with OZ's
        // nondecreasing uint48 timestamps and uint208 voting-supply cap, this keeps integrals bounded.
        unchecked {
            Checkpoints.Checkpoint208 storage last = checkpoints[index - 1];
            if (last._key == timestamp) {
                return;
            }

            uint48 start = last._key > activation ? last._key : activation;
            uint256 cumulative = cumulatives[index - 1] + uint256(last._value) * (timestamp - start);
            cumulatives[index] = cumulative;
        }
    }

    function _supplyHistory() private view returns (Checkpoints.Checkpoint208[] storage) {
        VotesUpgradeable.VotesStorage storage $ = _getVotesStorage();
        return $._totalCheckpoints._checkpoints;
    }
}
