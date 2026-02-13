// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { GovernorUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";

import { IReserveOptimisticGovernor } from "../../interfaces/IReserveOptimisticGovernor.sol";

import { OPTIMISTIC_PROPOSER_ROLE } from "../../utils/Constants.sol";
import { OptimisticSelectorRegistry } from "../OptimisticSelectorRegistry.sol";
import { ReserveOptimisticGovernor } from "../ReserveOptimisticGovernor.sol";

library ProposalLib {
    struct ProposalData {
        uint256 proposalId;
        address proposer;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
    }

    // === External ===

    function proposeOptimistic(
        ProposalData calldata proposal,
        GovernorUpgradeable.ProposalCore storage proposalCore,
        IReserveOptimisticGovernor.OptimisticGovernanceParams calldata optimisticParams
    ) external {
        _validateProposal(proposal, proposalCore);

        ReserveOptimisticGovernor governor = ReserveOptimisticGovernor(payable(address(this)));

        // validate proposer

        require(
            AccessControl(governor.timelock()).hasRole(OPTIMISTIC_PROPOSER_ROLE, proposal.proposer),
            IReserveOptimisticGovernor.NotOptimisticProposer(proposal.proposer)
        );

        // validate calls

        {
            OptimisticSelectorRegistry selectorRegistry = governor.selectorRegistry();

            for (uint256 i = 0; i < proposal.targets.length; i++) {
                address target = proposal.targets[i];

                require(
                    target.code.length != 0 && proposal.calldatas[i].length >= 4
                        && selectorRegistry.isAllowed(target, bytes4(proposal.calldatas[i])),
                    IReserveOptimisticGovernor.InvalidCall(target, proposal.calldatas[i])
                );
            }
        }

        // finalize proposal

        emit IReserveOptimisticGovernor.OptimisticProposalCreated(proposal.proposalId, optimisticParams.vetoThreshold);
        _saveProposal(proposal, proposalCore, optimisticParams.vetoDelay, optimisticParams.vetoPeriod);
    }

    function proposePessimistic(ProposalData calldata proposal, GovernorUpgradeable.ProposalCore storage proposalCore)
        external
    {
        _validateProposal(proposal, proposalCore);

        ReserveOptimisticGovernor governor = ReserveOptimisticGovernor(payable(address(this)));

        // validate proposer

        {
            // {tok}
            uint256 votesThreshold = governor.proposalThreshold();
            uint256 proposerVotes = governor.getVotes(proposal.proposer, block.timestamp - 1);

            require(
                proposerVotes >= votesThreshold,
                IGovernor.GovernorInsufficientProposerVotes(proposal.proposer, proposerVotes, votesThreshold)
            );
        }

        // validate calls

        for (uint256 i = 0; i < proposal.targets.length; i++) {
            address target = proposal.targets[i];

            require(
                target.code.length != 0 || proposal.calldatas[i].length == 0,
                IReserveOptimisticGovernor.InvalidCall(target, proposal.calldatas[i])
            );
        }

        // finalize proposal

        _saveProposal(proposal, proposalCore, governor.votingDelay(), governor.votingPeriod());
    }

    // === Private ===

    function _validateProposal(ProposalData calldata proposal, GovernorUpgradeable.ProposalCore storage proposalCore)
        private
        view
    {
        ReserveOptimisticGovernor governor = _governor();

        if (proposalCore.voteStart != 0) {
            revert IGovernor.GovernorUnexpectedProposalState(
                proposal.proposalId, governor.state(proposal.proposalId), bytes32(0)
            );
        }

        require(
            _isValidDescriptionForProposer(proposal.proposer, proposal.description),
            IGovernor.GovernorRestrictedProposer(proposal.proposer)
        );

        require(
            proposal.targets.length == proposal.values.length && proposal.targets.length == proposal.calldatas.length,
            IGovernor.GovernorInvalidProposalLength(
                proposal.targets.length, proposal.calldatas.length, proposal.values.length
            )
        );

        require(proposal.targets.length != 0, IGovernor.GovernorInvalidProposalLength(0, 0, 0));
    }

    function _saveProposal(
        ProposalData calldata proposal,
        GovernorUpgradeable.ProposalCore storage proposalCore,
        uint256 voteDelay,
        uint256 voteDuration
    ) private {
        proposalCore.proposer = proposal.proposer;
        proposalCore.voteStart = SafeCast.toUint48(block.timestamp + voteDelay);
        proposalCore.voteDuration = SafeCast.toUint32(voteDuration);

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

    function _governor() private view returns (ReserveOptimisticGovernor) {
        return ReserveOptimisticGovernor(payable(address(this)));
    }
}
