// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { GovernorUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";

import { IOptimisticSelectorRegistry } from "../../interfaces/IOptimisticSelectorRegistry.sol";
import { IReserveOptimisticGovernor } from "../../interfaces/IReserveOptimisticGovernor.sol";

import { ReserveOptimisticGovernor } from "../ReserveOptimisticGovernor.sol";

import { OPTIMISTIC_PROPOSER_ROLE } from "../../utils/Constants.sol";

library ProposalLib {
    struct ProposalData {
        uint256 proposalId;
        address proposer;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
        uint256 vetoThreshold;
    }

    function propose(
        ProposalData calldata proposal,
        GovernorUpgradeable.ProposalCore storage proposalCore,
        IReserveOptimisticGovernor.OptimisticGovernanceParams calldata optimisticParams
    ) external {
        ReserveOptimisticGovernor governor = ReserveOptimisticGovernor(payable(address(this)));

        if (proposalCore.voteStart != 0) {
            revert IGovernor.GovernorUnexpectedProposalState(
                proposal.proposalId, governor.state(proposal.proposalId), bytes32(0)
            );
        }

        bool isOptimistic = proposal.vetoThreshold != 0;

        if (isOptimistic) {
            require(
                AccessControl(governor.timelock()).hasRole(OPTIMISTIC_PROPOSER_ROLE, proposal.proposer),
                IReserveOptimisticGovernor.NotOptimisticProposer(proposal.proposer)
            );
        }

        {

            // validate proposal lengths

            require(
                proposal.targets.length == proposal.values.length
                    && proposal.targets.length == proposal.calldatas.length,
                IGovernor.GovernorInvalidProposalLength(
                    proposal.targets.length, proposal.calldatas.length, proposal.values.length
                )
            );

            require(proposal.targets.length != 0, IGovernor.GovernorInvalidProposalLength(0, 0, 0));

            // validate proposal calls

            IOptimisticSelectorRegistry selectorRegistry = governor.selectorRegistry();
            for (uint256 i = 0; i < proposal.targets.length; i++) {
                address target = proposal.targets[i];

                if (!isOptimistic) {
                    // pessimistic

                    require(
                        target.code.length != 0 || proposal.calldatas[i].length == 0,
                        IReserveOptimisticGovernor.InvalidCall(target, proposal.calldatas[i])
                    );
                } else {
                    // optimistic

                    require(
                        target.code.length != 0 && proposal.calldatas[i].length >= 4
                            && selectorRegistry.isAllowed(target, bytes4(proposal.calldatas[i])),
                        IReserveOptimisticGovernor.InvalidCall(target, proposal.calldatas[i])
                    );
                }
            }
        }

        {
            uint256 snapshot;
            uint256 duration;

            if (!isOptimistic) {
                // pessimistic

                snapshot = block.timestamp + governor.votingDelay();
                duration = governor.votingPeriod();
            } else {
                // optimistic

                snapshot = block.timestamp + optimisticParams.vetoDelay;
                duration = optimisticParams.vetoPeriod;

                emit IReserveOptimisticGovernor.OptimisticProposalCreated(proposal.proposalId, proposal.vetoThreshold);
            }

            proposalCore.proposer = proposal.proposer;
            proposalCore.voteStart = SafeCast.toUint48(snapshot);
            proposalCore.voteDuration = SafeCast.toUint32(duration);
        }

        _emitProposalCreated(proposal, proposalCore);
    }

    // === Private ===

    function _emitProposalCreated(ProposalData calldata proposal, GovernorUpgradeable.ProposalCore storage proposalCore)
        private
    {
        emit IGovernor.ProposalCreated(
            proposal.proposalId,
            proposal.proposer,
            proposal.targets,
            proposal.values,
            new string[](proposal.targets.length),
            proposal.calldatas,
            proposalCore.voteStart,
            proposalCore.voteStart + proposalCore.voteDuration,
            proposal.description
        );
    }
}
