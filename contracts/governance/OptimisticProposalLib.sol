// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { IERC5805 } from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { GovernorUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import {
    GovernorTimelockControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";

import { IOptimisticSelectorRegistry } from "../interfaces/IOptimisticSelectorRegistry.sol";
import { IReserveOptimisticGovernor } from "../interfaces/IReserveOptimisticGovernor.sol";
import { ITimelockControllerOptimistic } from "../interfaces/ITimelockControllerOptimistic.sol";

library OptimisticProposalLib {
    // stack-too-deep
    struct ProposalData {
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
    }

    /// === External ===

    function createOptimisticProposal(
        uint256 proposalId,
        ProposalData calldata proposal,
        IReserveOptimisticGovernor.OptimisticProposal storage optimisticProposal,
        IReserveOptimisticGovernor.OptimisticGovernanceParams calldata optimisticParams,
        IOptimisticSelectorRegistry selectorRegistry
    ) external {
        require(proposal.targets.length != 0, IReserveOptimisticGovernor.InvalidProposalLengths());
        require(
            proposal.targets.length == proposal.values.length && proposal.targets.length == proposal.calldatas.length,
            IReserveOptimisticGovernor.InvalidProposalLengths()
        );

        // validate function calls
        {
            for (uint256 i = 0; i < proposal.targets.length; i++) {
                address target = proposal.targets[i];

                require(target.code.length != 0, IReserveOptimisticGovernor.InvalidFunctionCallToEOA(target));

                require(
                    proposal.calldatas[i].length >= 4,
                    IReserveOptimisticGovernor.InvalidEmptyCall(target, proposal.calldatas[i])
                );

                require(
                    selectorRegistry.isAllowed(target, bytes4(proposal.calldatas[i])),
                    IReserveOptimisticGovernor.InvalidFunctionCall(target, bytes4(proposal.calldatas[i]))
                );

                // copy data to storage
                optimisticProposal.targets.push(proposal.targets[i]);
                optimisticProposal.values.push(proposal.values[i]);
                optimisticProposal.calldatas.push(proposal.calldatas[i]);
            }
        }

        require(
            optimisticProposal.core.voteStart == 0, IReserveOptimisticGovernor.ExistingOptimisticProposal(proposalId)
        );

        optimisticProposal.proposalId = proposalId;
        optimisticProposal.description = proposal.description;

        optimisticProposal.core.proposer = msg.sender;
        optimisticProposal.core.voteStart = uint48(block.timestamp) + optimisticParams.vetoDelay;
        optimisticProposal.core.voteDuration = SafeCast.toUint32(optimisticParams.vetoPeriod);

        optimisticProposal.vetoThreshold = optimisticParams.vetoThreshold;

        emit IReserveOptimisticGovernor.OptimisticProposalCreated(
            proposalId,
            msg.sender,
            proposal.targets,
            proposal.values,
            proposal.calldatas,
            optimisticProposal.core.voteStart,
            optimisticProposal.core.voteStart + optimisticParams.vetoPeriod,
            optimisticProposal.vetoThreshold,
            proposal.description
        );
    }

    /// @return If the proposal was vetoed past the veto threshold
    function castVeto(
        IReserveOptimisticGovernor.OptimisticProposal storage optimisticProposal,
        IERC5805 token,
        string memory reason
    ) external returns (bool) {
        require(
            _state(optimisticProposal, token) == IGovernor.ProposalState.Active,
            IReserveOptimisticGovernor.OptimisticProposalNotActive(optimisticProposal.proposalId)
        );

        uint256 weight = token.getPastVotes(msg.sender, optimisticProposal.core.voteStart);

        require(
            !optimisticProposal.vote.hasVoted[msg.sender],
            IReserveOptimisticGovernor.OptimisticProposalAlreadyVetoed(optimisticProposal.proposalId)
        );
        optimisticProposal.vote.hasVoted[msg.sender] = true;

        optimisticProposal.vote.againstVotes += weight;
        emit IReserveOptimisticGovernor.VetoCast(optimisticProposal.proposalId, msg.sender, weight, reason);

        return _state(optimisticProposal, token) == IGovernor.ProposalState.Defeated;
    }

    function executeOptimisticProposal(
        IReserveOptimisticGovernor.OptimisticProposal storage optimisticProposal,
        IERC5805 token
    ) external {
        require(
            _state(optimisticProposal, token) == IGovernor.ProposalState.Succeeded,
            IReserveOptimisticGovernor.OptimisticProposalNotSuccessful(optimisticProposal.proposalId)
        );

        emit IGovernor.ProposalCreated(
            optimisticProposal.proposalId,
            msg.sender,
            optimisticProposal.targets,
            optimisticProposal.values,
            new string[](optimisticProposal.targets.length),
            optimisticProposal.calldatas,
            block.timestamp,
            block.timestamp,
            optimisticProposal.description
        );
        emit IGovernor.ProposalExecuted(optimisticProposal.proposalId);

        ITimelockControllerOptimistic timelock = ITimelockControllerOptimistic(
            payable(GovernorTimelockControlUpgradeable(payable(address(this))).timelock())
        );

        timelock.executeBatchBypass{ value: msg.value }(
            optimisticProposal.targets,
            optimisticProposal.values,
            optimisticProposal.calldatas,
            0,
            bytes20(address(this)) ^ keccak256(bytes(optimisticProposal.description))
        );
    }

    function state(IReserveOptimisticGovernor.OptimisticProposal storage optimisticProposal, IERC5805 token)
        external
        view
        returns (IGovernor.ProposalState)
    {
        return _state(optimisticProposal, token);
    }

    // === Internal ===

    function _state(IReserveOptimisticGovernor.OptimisticProposal storage optimisticProposal, IERC5805 token)
        internal
        view
        returns (IGovernor.ProposalState)
    {
        if (optimisticProposal.core.executed) {
            return IGovernor.ProposalState.Executed;
        }

        if (optimisticProposal.core.canceled) {
            return IGovernor.ProposalState.Canceled;
        }

        uint256 snapshot = optimisticProposal.core.voteStart;
        require(snapshot != 0, IGovernor.GovernorNonexistentProposal(optimisticProposal.proposalId));

        if (snapshot >= block.timestamp) {
            return IGovernor.ProposalState.Pending;
        }

        // {tok}
        uint256 pastSupply = token.getPastTotalSupply(snapshot - 1);
        if (pastSupply == 0) {
            return IGovernor.ProposalState.Canceled;
        }

        // {s}
        uint256 deadline = optimisticProposal.core.voteStart + optimisticProposal.core.voteDuration;

        if (deadline >= block.timestamp) {
            return IGovernor.ProposalState.Active;
        }

        // {tok} = D18{1} * {tok} / D18{1}
        uint256 vetoThreshold = (optimisticProposal.vetoThreshold * pastSupply + (1e18 - 1)) / 1e18;

        if (optimisticProposal.vote.againstVotes >= vetoThreshold) {
            return IGovernor.ProposalState.Defeated;
        } else {
            return IGovernor.ProposalState.Succeeded;
        }
    }
}
