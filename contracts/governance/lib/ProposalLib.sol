// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { GovernorUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";

import { IOptimisticVotes } from "@interfaces/IOptimisticVotes.sol";
import { IReserveOptimisticGovernor } from "@interfaces/IReserveOptimisticGovernor.sol";

import { OptimisticSelectorRegistry } from "@governance/OptimisticSelectorRegistry.sol";
import { ReserveOptimisticGovernor } from "@governance/ReserveOptimisticGovernor.sol";
import { OPTIMISTIC_PROPOSER_ROLE, PROPOSAL_THROTTLE_PERIOD } from "@utils/Constants.sol";

library ProposalLib {
    string constant CONFIRMATION_PREFIX = "Confirmation For: ";
    bytes18 constant CONFIRMATION_PREFIX_BYTES = bytes18(bytes(CONFIRMATION_PREFIX));
    uint256 constant TRANSITIONED_VETO_THRESHOLD = type(uint256).max;

    struct ProposalData {
        uint256 proposalId;
        address proposer;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
    }

    // === External ===

    function optimisticState(
        GovernorUpgradeable.ProposalCore storage proposalCore,
        uint256 vetoThreshold,
        IOptimisticVotes token,
        uint256 proposalId
    ) external view returns (IGovernor.ProposalState) {
        if (proposalCore.executed) {
            return IGovernor.ProposalState.Executed;
        }

        if (proposalCore.canceled) {
            return IGovernor.ProposalState.Canceled;
        }

        // {s}
        uint256 snapshot = proposalCore.voteStart;
        if (snapshot >= block.timestamp) {
            return IGovernor.ProposalState.Pending;
        }

        if (vetoThreshold == TRANSITIONED_VETO_THRESHOLD) {
            return IGovernor.ProposalState.Defeated;
        }

        // {tok}
        uint256 pastSupply = token.getPastOptimisticTotalSupply(snapshot);
        if (pastSupply == 0) {
            return IGovernor.ProposalState.Canceled;
        }

        // {tok} = D18{1} * {tok} / D18{1}
        uint256 vetoThresholdTok = Math.max((vetoThreshold * pastSupply) / 1e18, 1);
        (uint256 againstVotes,,) = _governor().proposalVotes(proposalId);
        if (againstVotes >= vetoThresholdTok) {
            return IGovernor.ProposalState.Defeated;
        }

        // {s}
        uint256 deadline = proposalCore.voteStart + proposalCore.voteDuration;
        if (deadline >= block.timestamp) {
            return IGovernor.ProposalState.Active;
        }

        return IGovernor.ProposalState.Succeeded;
    }

    function proposeOptimistic(
        ProposalData calldata proposal,
        GovernorUpgradeable.ProposalCore storage proposalCore,
        mapping(
            uint256 proposalId => IReserveOptimisticGovernor.OptimisticProposalDetails
        ) storage optimisticProposals,
        IReserveOptimisticGovernor.OptimisticGovernanceParams calldata optimisticParams
    ) external {
        optimisticProposals[
            proposal.proposalId
        ] = IReserveOptimisticGovernor.OptimisticProposalDetails({
            targets: proposal.targets,
            values: proposal.values,
            calldatas: proposal.calldatas,
            description: proposal.description,
            vetoThreshold: optimisticParams.vetoThreshold
        });

        _validateProposal(proposal, proposalCore);

        ReserveOptimisticGovernor governor = _governor();

        // validate proposer

        require(
            AccessControl(governor.timelock()).hasRole(OPTIMISTIC_PROPOSER_ROLE, proposal.proposer),
            IReserveOptimisticGovernor.OptimisticGovernor__NotOptimisticProposer(proposal.proposer)
        );

        // validate calls

        {
            OptimisticSelectorRegistry selectorRegistry = governor.selectorRegistry();

            for (uint256 i = 0; i < proposal.targets.length; i++) {
                address target = proposal.targets[i];

                require(
                    target.code.length != 0 && proposal.calldatas[i].length >= 4
                        && selectorRegistry.isAllowed(target, bytes4(proposal.calldatas[i])),
                    IReserveOptimisticGovernor.OptimisticGovernor__InvalidCall(target, proposal.calldatas[i])
                );
            }
        }

        // finalize

        emit IReserveOptimisticGovernor.OptimisticProposalCreated(proposal.proposalId, optimisticParams.vetoThreshold);
        _saveProposal(proposal, proposalCore, optimisticParams.vetoDelay, optimisticParams.vetoPeriod);
    }

    function proposePessimistic(ProposalData calldata proposal, GovernorUpgradeable.ProposalCore storage proposalCore)
        external
    {
        _validateProposal(proposal, proposalCore);

        ReserveOptimisticGovernor governor = _governor();

        // validate proposer

        {
            // {tok}
            uint256 votesThreshold = governor.proposalThreshold();
            uint256 proposerVotes = governor.getVotes(proposal.proposer, block.timestamp - 1);

            require(
                proposerVotes >= votesThreshold,
                IGovernor.GovernorInsufficientProposerVotes(proposal.proposer, proposerVotes, votesThreshold)
            );

            uint256 periodStart =
                block.timestamp > PROPOSAL_THROTTLE_PERIOD ? block.timestamp - PROPOSAL_THROTTLE_PERIOD : 0;
            IOptimisticVotes votes = IOptimisticVotes(address(governor.token()));
            uint256 integralStart = votes.getPastVotesIntegral(proposal.proposer, periodStart);
            uint256 integralEnd = votes.getPastVotesIntegral(proposal.proposer, block.timestamp);
            // Deliberately divide by the full period even before timestamp 12 hours or integral activation.
            uint256 averageVotes = (integralEnd - integralStart) / PROPOSAL_THROTTLE_PERIOD;
            require(
                averageVotes >= votesThreshold,
                IGovernor.GovernorInsufficientProposerVotes(proposal.proposer, averageVotes, votesThreshold)
            );
        }

        // validate calls

        for (uint256 i = 0; i < proposal.targets.length; i++) {
            address target = proposal.targets[i];

            require(
                target.code.length != 0 || proposal.calldatas[i].length == 0,
                IReserveOptimisticGovernor.OptimisticGovernor__InvalidCall(target, proposal.calldatas[i])
            );
            // not a security feature, just a partial guard against accidental calls to EOAs
        }

        // finalize

        _saveProposal(proposal, proposalCore, governor.votingDelay(), governor.votingPeriod());
    }

    /// @param proposalId Optimistic proposal id
    function transitionToPessimistic(
        uint256 proposalId,
        IReserveOptimisticGovernor.OptimisticProposalDetails storage optimisticProposal,
        mapping(uint256 proposalId => GovernorUpgradeable.ProposalCore) storage proposalCores
    ) external {
        ReserveOptimisticGovernor governor = _governor();

        require(
            optimisticProposal.vetoThreshold != TRANSITIONED_VETO_THRESHOLD,
            IGovernor.GovernorUnexpectedProposalState(
                proposalId, governor.state(proposalId), bytes32(1 << uint8(IGovernor.ProposalState.Defeated))
            )
        );
        optimisticProposal.vetoThreshold = TRANSITIONED_VETO_THRESHOLD;

        string memory newDescription = string.concat(CONFIRMATION_PREFIX, optimisticProposal.description);

        uint256 newProposalId = governor.getProposalId(
            optimisticProposal.targets,
            optimisticProposal.values,
            optimisticProposal.calldatas,
            keccak256(bytes(newDescription))
        );

        ProposalData memory proposalData = ProposalData(
            newProposalId,
            governor.proposalProposer(proposalId),
            optimisticProposal.targets,
            optimisticProposal.values,
            optimisticProposal.calldatas,
            newDescription
        );

        _saveProposal(proposalData, proposalCores[newProposalId], governor.votingDelay(), governor.votingPeriod());
    }

    // === Private ===

    function _validateProposal(ProposalData calldata proposal, GovernorUpgradeable.ProposalCore storage proposalCore)
        private
        view
    {
        if (proposalCore.voteStart != 0) {
            revert IGovernor.GovernorUnexpectedProposalState(
                proposal.proposalId, _governor().state(proposal.proposalId), bytes32(0)
            );
        }

        require(
            _isValidDescriptionForProposer(proposal.proposer, proposal.description),
            IGovernor.GovernorRestrictedProposer(proposal.proposer)
        );

        require(
            bytes18(bytes(proposal.description)) != CONFIRMATION_PREFIX_BYTES,
            IReserveOptimisticGovernor.OptimisticGovernor__ConfirmationPrefixNotAllowed()
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
        ProposalData memory proposal,
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
