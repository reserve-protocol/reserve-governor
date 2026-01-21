// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { OptimisticProposal } from "../OptimisticProposal.sol";
import { ReserveGovernor } from "../ReserveGovernor.sol";
import { IReserveGovernor } from "../interfaces/IReserveGovernor.sol";

library OptimisticProposalLib {
    using EnumerableSet for EnumerableSet.AddressSet;

    // stack-too-deep
    struct ProposalData {
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
    }

    // === External ===

    function createOptimisticProposal(
        ProposalData memory proposal,
        mapping(uint256 proposalId => OptimisticProposal) storage optimisticProposals,
        EnumerableSet.AddressSet storage activeOptimisticProposals,
        IReserveGovernor.OptimisticGovernanceParams calldata optimisticParams,
        address optimisticProposalImpl,
        address timelock
    ) external returns (uint256 proposalId) {
        _clearCompletedOptimisticProposals(activeOptimisticProposals);

        // prevent targeting this contract or the timelock
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            require(
                proposal.targets[i] != address(this) && proposal.targets[i] != address(timelock),
                IReserveGovernor.NoMetaGovernanceThroughOptimistic()
            );
        }

        OptimisticProposal optimisticProposal = OptimisticProposal(Clones.clone(optimisticProposalImpl));

        // ensure ONLY the OptimisticProposal can create the dispute proposal
        proposal.description =
            string.concat(proposal.description, "#proposer=", Strings.toHexString(address(optimisticProposal)));

        proposalId = ReserveGovernor(payable(address(this)))
            .getProposalId(
                proposal.targets, proposal.values, proposal.calldatas, keccak256(bytes(proposal.description))
            );

        optimisticProposal.initialize(
            optimisticParams, proposalId, proposal.targets, proposal.values, proposal.calldatas, proposal.description
        );

        require(
            address(optimisticProposals[proposalId]) == address(0),
            IReserveGovernor.ExistingOptimisticProposal(proposalId)
        );
        optimisticProposals[proposalId] = optimisticProposal;

        require(
            activeOptimisticProposals.length() < optimisticParams.numParallelProposals,
            IReserveGovernor.TooManyParallelOptimisticProposals()
        );
        activeOptimisticProposals.add(address(optimisticProposal));

        emit IReserveGovernor.OptimisticProposalCreated(
            msg.sender, // TODO do we care this isn't _msgSender()? seems fine
            proposalId,
            proposal.targets,
            proposal.values,
            proposal.calldatas,
            proposal.description,
            optimisticParams.vetoPeriod,
            optimisticParams.vetoThreshold,
            optimisticParams.slashingPercentage
        );
    }

    // === View ===

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

    function _clearCompletedOptimisticProposals(EnumerableSet.AddressSet storage set) private {
        // this is obviously a bad pattern in general, but with a max
        // of 5 (MAX_PARALLEL_OPTIMISTIC_PROPOSALS) it's fine and saves many callbacks

        while (set.length() > 0) {
            address optimisticProposal = set.at(0);

            if (_proposalFinished(OptimisticProposal(optimisticProposal).state())) {
                set.remove(optimisticProposal);
            }
        }
    }

    function _proposalFinished(OptimisticProposal.OptimisticProposalState state) private pure returns (bool) {
        return state == OptimisticProposal.OptimisticProposalState.Vetoed
            || state == OptimisticProposal.OptimisticProposalState.Slashed
            || state == OptimisticProposal.OptimisticProposalState.Canceled
            || state == OptimisticProposal.OptimisticProposalState.Executed;
    }
}
