// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IVotesIntegral } from "@interfaces/IVotesIntegral.sol";
import {
    ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import { VoteIntegralLib } from "@staking/lib/VoteIntegralLib.sol";

/**
 * @title ERC20 Votes Integral
 * @notice Tracks cumulative delegated vote-seconds alongside the standard OZ checkpoints.
 * @dev Requires a timestamp clock. Existing checkpoints retain their packed layout and are not backfilled.
 *      Tracking starts at each delegate's first nonzero vote movement after upgrading to this extension.
 */
abstract contract ERC20VotesIntegralUpgradeable is ERC20VotesUpgradeable, IVotesIntegral {
    /// @notice Returns cumulative delegated vote-seconds at a timestamp, including the current timestamp.
    /// @dev Returns zero before tracking starts. Uses the same timestamps and vote values as getPastVotes.
    function getPastVotesIntegral(address account, uint256 timepoint) external view returns (uint256) {
        return VoteIntegralLib.lookup(account, timepoint);
    }

    function _moveDelegateVotes(address from, address to, uint256 amount) internal virtual override {
        VoteIntegralLib.update(from, to, amount, clock());
        // OZ appends/coalesces the checkpoint whose integral was just recorded. Its supply, vote and
        // timestamp checks apply to both updates: a failure here also reverts the library's writes.
        super._moveDelegateVotes(from, to, amount);
    }
}
