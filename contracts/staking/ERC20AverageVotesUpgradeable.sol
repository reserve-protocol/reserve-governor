// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAverageVotes } from "@interfaces/IAverageVotes.sol";
import {
    ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { VoteIntegralLib } from "@staking/lib/VoteIntegralLib.sol";

/**
 * @title ERC20 Average Votes
 * @notice Provides historical average delegated votes and supply-seconds shares using standard OZ checkpoints.
 * @dev Requires a block-timestamp clock. Existing checkpoints retain their packed layout and are not backfilled.
 */
abstract contract ERC20AverageVotesUpgradeable is ERC20VotesUpgradeable, IAverageVotes {
    /// @inheritdoc IAverageVotes
    function getPastAverageVotes(address account, uint256 start, uint256 end) external view returns (uint256) {
        require(start <= end, AverageVotes__InvalidTimeRange());

        if (start == end) {
            return 0;
        }

        return (VoteIntegralLib.lookup(account, end) - VoteIntegralLib.lookup(account, start)) / (end - start);
    }

    /// @notice Returns the account's supply-seconds share over `[start, end)` as D18.
    function getPastVoteShare(address account, uint256 start, uint256 end) external view returns (uint256) {
        require(start <= end, AverageVotes__InvalidTimeRange());
        return VoteIntegralLib.lookupShare(account, start, end);
    }

    function _initializeAverageVotes() internal {
        VoteIntegralLib.initialize(clock(), SafeCast.toUint208(totalSupply()));
    }

    function _moveDelegateVotes(address from, address to, uint256 amount) internal virtual override {
        VoteIntegralLib.update(from, to, amount, clock());

        // OZ appends/coalesces the checkpoint whose integral was just recorded. Its supply, vote and
        // timestamp checks apply to both updates: a failure here also reverts the library's writes.
        super._moveDelegateVotes(from, to, amount);
    }

    function _transferVotingUnits(address from, address to, uint256 amount) internal virtual override {
        VoteIntegralLib.updateSupply(from, to, amount, totalSupply(), clock());
        super._transferVotingUnits(from, to, amount);
    }
}
