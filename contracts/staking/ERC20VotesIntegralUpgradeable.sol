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
 * @dev Requires a block-timestamp clock. Existing checkpoints retain their packed layout and are not backfilled.
 */
abstract contract ERC20VotesIntegralUpgradeable is ERC20VotesUpgradeable, IVotesIntegral {
    /// @inheritdoc IVotesIntegral
    function getPastAverageVotes(address account, uint256 start, uint256 end) external view returns (uint256) {
        return VoteIntegralLib.averageVotes(account, start, end);
    }

    function _initializeVoteIntegral() internal {
        VoteIntegralLib.initialize();
    }

    function _moveDelegateVotes(address from, address to, uint256 amount) internal virtual override {
        VoteIntegralLib.update(from, to, amount);
        // OZ appends/coalesces the checkpoint whose integral was just recorded. Its supply, vote and
        // timestamp checks apply to both updates: a failure here also reverts the library's writes.
        super._moveDelegateVotes(from, to, amount);
    }
}
