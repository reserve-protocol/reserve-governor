// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { OptimisticProposal } from "../OptimisticProposal.sol";

library OptimisticProposalLib {
    using EnumerableSet for EnumerableSet.AddressSet;

    // === External ===

    function clearCompletedOptimisticProposals(EnumerableSet.AddressSet storage set) external {
        // this is obviously a bad pattern in general, but with a max
        // of 5 (MAX_PARALLEL_OPTIMISTIC_PROPOSALS) it's fine and saves many callbacks
        
        while (set.length() > 0) {
            address optimisticProposal = set.at(0);

            if (_proposalFinished(OptimisticProposal(optimisticProposal).state())) {
                set.remove(optimisticProposal);
            }
        }
    }

    function activeOptimisticProposalsCount(EnumerableSet.AddressSet storage set)
        external
        view
        returns (uint256 count)
    {
        for (uint256 i = 0; i < set.length(); i++) {
            if (!_proposalFinished(OptimisticProposal(set.at(0)).state())) {
                count++;
            }
        }
    }

    // === Private ===

    function _proposalFinished(OptimisticProposal.OptimisticProposalState state) private pure returns (bool) {
        return state == OptimisticProposal.OptimisticProposalState.Vetoed
            || state == OptimisticProposal.OptimisticProposalState.Slashed
            || state == OptimisticProposal.OptimisticProposalState.Canceled
            || state == OptimisticProposal.OptimisticProposalState.Executed;
    }
}
