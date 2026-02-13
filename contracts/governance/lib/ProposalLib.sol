// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { GovernorUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";

import { IOptimisticSelectorRegistry } from "../../interfaces/IOptimisticSelectorRegistry.sol";
import { IReserveOptimisticGovernor } from "../../interfaces/IReserveOptimisticGovernor.sol";

import { OPTIMISTIC_PROPOSER_ROLE } from "../../utils/Constants.sol";
import { ReserveOptimisticGovernor } from "../ReserveOptimisticGovernor.sol";

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

        // == Validate description ==

        require(
            _isValidDescriptionForProposer(proposal.proposer, proposal.description),
            IGovernor.GovernorRestrictedProposer(proposal.proposer)
        );

        // == Validate proposer ==

        bool isOptimistic = proposal.vetoThreshold != 0;

        if (isOptimistic) {
            // optimistic

            require(
                AccessControl(governor.timelock()).hasRole(OPTIMISTIC_PROPOSER_ROLE, proposal.proposer),
                IReserveOptimisticGovernor.NotOptimisticProposer(proposal.proposer)
            );
        } else {
            // pessimistic

            uint256 votesThreshold = governor.proposalThreshold();
            if (votesThreshold > 0) {
                uint256 proposerVotes = governor.getVotes(proposal.proposer, block.timestamp - 1);

                require(
                    proposerVotes >= votesThreshold,
                    IGovernor.GovernorInsufficientProposerVotes(proposal.proposer, proposerVotes, votesThreshold)
                );
            }
        }

        // == Validate proposal ==

        {
            require(
                proposal.targets.length == proposal.values.length
                    && proposal.targets.length == proposal.calldatas.length,
                IGovernor.GovernorInvalidProposalLength(
                    proposal.targets.length, proposal.calldatas.length, proposal.values.length
                )
            );

            require(proposal.targets.length != 0, IGovernor.GovernorInvalidProposalLength(0, 0, 0));

            IOptimisticSelectorRegistry selectorRegistry = governor.selectorRegistry();

            for (uint256 i = 0; i < proposal.targets.length; i++) {
                address target = proposal.targets[i];

                if (isOptimistic) {
                    // optimistic

                    require(
                        target.code.length != 0 && proposal.calldatas[i].length >= 4
                            && selectorRegistry.isAllowed(target, bytes4(proposal.calldatas[i])),
                        IReserveOptimisticGovernor.InvalidCall(target, proposal.calldatas[i])
                    );
                } else {
                    // pessimistic

                    require(
                        target.code.length != 0 || proposal.calldatas[i].length == 0,
                        IReserveOptimisticGovernor.InvalidCall(target, proposal.calldatas[i])
                    );
                }
            }
        }

        // == Calculate start/end times ==

        {
            uint256 snapshot;
            uint256 duration;

            if (isOptimistic) {
                // optimistic

                snapshot = block.timestamp + optimisticParams.vetoDelay;
                duration = optimisticParams.vetoPeriod;

                emit IReserveOptimisticGovernor.OptimisticProposalCreated(proposal.proposalId, proposal.vetoThreshold);
            } else {
                // pessimistic

                snapshot = block.timestamp + governor.votingDelay();
                duration = governor.votingPeriod();
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

    function _isValidDescriptionForProposer(address proposer, string memory description) private pure returns (bool) {
        unchecked {
            uint256 length = bytes(description).length;

            // Length is too short to contain a valid proposer suffix
            if (length < 52) {
                return true;
            }

            // Extract what would be the `#proposer=` marker beginning the suffix
            bytes10 marker = bytes10(_unsafeReadBytesOffset(bytes(description), length - 52));

            // If the marker is not found, there is no proposer suffix to check
            if (marker != bytes10("#proposer=")) {
                return true;
            }

            // Check that the last 42 characters (after the marker) are a properly formatted address.
            (bool success, address recovered) = Strings.tryParseAddress(description, length - 42, length);
            return !success || recovered == proposer;
        }
    }

    function _unsafeReadBytesOffset(bytes memory buffer, uint256 offset) private pure returns (bytes32 value) {
        // This is not memory safe in the general case, but all calls to this private function are within bounds.
        assembly ("memory-safe") {
            value := mload(add(add(buffer, 0x20), offset))
        }
    }
}
