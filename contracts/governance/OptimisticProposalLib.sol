// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { GovernorUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import {
    GovernorTimelockControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";

import { IOptimisticSelectorRegistry } from "../interfaces/IOptimisticSelectorRegistry.sol";
import { IReserveOptimisticGovernor } from "../interfaces/IReserveOptimisticGovernor.sol";
import { ITimelockControllerOptimistic } from "../interfaces/ITimelockControllerOptimistic.sol";

import { OptimisticProposal } from "./OptimisticProposal.sol";

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
        IReserveOptimisticGovernor.OptimisticGovernanceParams calldata optimisticParams,
        address optimisticProposalImpl,
        IOptimisticSelectorRegistry selectorRegistry
    ) external returns (uint256 proposalId) {
        _clearCompletedOptimisticProposals(activeOptimisticProposals);

        require(proposal.targets.length != 0, IReserveOptimisticGovernor.InvalidProposalLengths());
        require(
            proposal.targets.length == proposal.values.length && proposal.targets.length == proposal.calldatas.length,
            IReserveOptimisticGovernor.InvalidProposalLengths()
        );

        // validate function calls
        {
            address timelock = address(_timelock());

            for (uint256 i = 0; i < proposal.targets.length; i++) {
                address target = proposal.targets[i];
                bytes4 selector = bytes4(proposal.calldatas[i]);

                // never target ReserveOptimisticGovernor or TimelockControllerOptimistic
                require(
                    target != address(this) && target != timelock && selectorRegistry.isAllowed(target, selector),
                    IReserveOptimisticGovernor.InvalidFunctionCall(target, selector)
                );

                // ensure no accidental calls to EOAs
                // limitation: cannot log data to EOAs or interact with a contract within its constructor
                require(
                    selector == bytes4(0) || target.code.length != 0,
                    IReserveOptimisticGovernor.InvalidFunctionCallToEOA(target)
                );
            }
        }

        OptimisticProposal optimisticProposal = OptimisticProposal(Clones.clone(optimisticProposalImpl));

        // ensure ONLY the OptimisticProposal can create the confirmation proposal
        proposal.description =
            string.concat(proposal.description, "#proposer=", Strings.toHexString(address(optimisticProposal)));

        proposalId = IGovernor(payable(address(this)))
            .getProposalId(
                proposal.targets, proposal.values, proposal.calldatas, keccak256(bytes(proposal.description))
            );

        optimisticProposal.initialize(
            optimisticParams,
            proposalId,
            msg.sender,
            proposal.targets,
            proposal.values,
            proposal.calldatas,
            proposal.description
        );

        require(
            address(optimisticProposals[proposalId]) == address(0),
            IReserveOptimisticGovernor.ExistingOptimisticProposal(proposalId)
        );
        optimisticProposals[proposalId] = optimisticProposal;

        require(
            activeOptimisticProposals.length() < optimisticParams.numParallelProposals,
            IReserveOptimisticGovernor.TooManyParallelOptimisticProposals()
        );
        activeOptimisticProposals.add(address(optimisticProposal));

        emit IReserveOptimisticGovernor.OptimisticProposalCreated(
            msg.sender,
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

    function executeOptimisticProposal(
        uint256 proposalId,
        mapping(uint256 proposalId => OptimisticProposal) storage optimisticProposals,
        GovernorUpgradeable.GovernorStorage storage governorStorage
    ) external {
        OptimisticProposal optimisticProposal = optimisticProposals[proposalId];

        require(
            optimisticProposal.state() == OptimisticProposal.OptimisticProposalState.Succeeded,
            IReserveOptimisticGovernor.OptimisticProposalNotSuccessful(proposalId)
        );

        // mark executed in proposal core (for compatibility with legacy offchain monitoring)
        governorStorage._proposals[proposalId].executed = true;

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            optimisticProposal.proposalData();

        emit IGovernor.ProposalCreated(
            proposalId, msg.sender, targets, values, new string[](targets.length), calldatas, 0, 0, description
        );
        emit IGovernor.ProposalExecuted(proposalId);

        _timelock().executeBatchBypass{ value: msg.value }(
            targets, values, calldatas, 0, bytes20(address(this)) ^ keccak256(bytes(description))
        );
    }

    // === View ===

    function activeOptimisticProposalsCount(EnumerableSet.AddressSet storage set)
        external
        view
        returns (uint256 count)
    {
        for (uint256 i = set.length(); i > 0; i--) {
            if (!_proposalFinished(OptimisticProposal(set.at(i - 1)).state())) {
                count++;
            }
        }
    }

    // === Private ===

    function _clearCompletedOptimisticProposals(EnumerableSet.AddressSet storage set) private {
        // this is obviously a bad pattern in general, but with a max
        // of 5 (MAX_PARALLEL_OPTIMISTIC_PROPOSALS) it's fine and saves many callbacks

        // Iterate backwards to safely remove while iterating
        for (uint256 i = set.length(); i > 0; i--) {
            address optimisticProposal = set.at(i - 1);

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

    function _timelock() private view returns (ITimelockControllerOptimistic) {
        return
            ITimelockControllerOptimistic(
                payable(GovernorTimelockControlUpgradeable(payable(address(this))).timelock())
            );
    }
}
