// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { IERC5805 } from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { GovernorUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {
    GovernorCountingSimpleUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import {
    GovernorTimelockControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";

import { ReserveOptimisticGovernor } from "../governance/ReserveOptimisticGovernor.sol";
import { TimelockControllerOptimistic } from "../governance/TimelockControllerOptimistic.sol";
import { IOptimisticSelectorRegistry } from "../interfaces/IOptimisticSelectorRegistry.sol";
import { IReserveOptimisticGovernor } from "../interfaces/IReserveOptimisticGovernor.sol";
import { OPTIMISTIC_PROPOSER_ROLE } from "../utils/Constants.sol";

library OptimisticProposalLib {
    // stack-too-deep
    struct ProposalData {
        uint256 proposalId;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
    }

    /// === External ===

    function proposeOptimistic(
        ProposalData calldata proposal,
        IReserveOptimisticGovernor.OptimisticGovernanceParams calldata optimisticParams,
        GovernorUpgradeable.ProposalCore storage proposalCore,
        IOptimisticSelectorRegistry selectorRegistry
    ) external {
        // validate proposer has OPTIMISTIC_PROPOSER_ROLE
        {
            require(
                _timelock().hasRole(OPTIMISTIC_PROPOSER_ROLE, msg.sender),
                IReserveOptimisticGovernor.NotOptimisticProposer(msg.sender)
            );
        }

        // validate description is restricted to proposer
        require(
            _isValidDescriptionForProposer(msg.sender, proposal.description),
            IGovernor.GovernorRestrictedProposer(msg.sender)
        );

        // validate proposal details
        {

            require(proposal.targets.length != 0, IReserveOptimisticGovernor.InvalidProposalLengths());
            require(
                proposal.targets.length == proposal.values.length
                    && proposal.targets.length == proposal.calldatas.length,
                IReserveOptimisticGovernor.InvalidProposalLengths()
            );

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
            }
        }

        // create optimistic proposal
        {

            require(proposalCore.voteStart == 0, IReserveOptimisticGovernor.ExistingProposal(proposal.proposalId));

            proposalCore.proposer = msg.sender;
            proposalCore.voteStart = SafeCast.toUint48(block.timestamp) + optimisticParams.vetoDelay;
            proposalCore.voteDuration = SafeCast.toUint32(optimisticParams.vetoPeriod);

            emit IReserveOptimisticGovernor.OptimisticProposalCreated(
                proposal.proposalId,
                proposalCore.voteStart,
                proposalCore.voteStart + proposalCore.voteDuration,
                optimisticParams.vetoThreshold
            );
            emit IGovernor.ProposalCreated(
                proposal.proposalId,
                msg.sender,
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

    function executeOptimisticProposal(
        ProposalData calldata proposal,
        GovernorUpgradeable.ProposalCore storage proposalCore,
        GovernorCountingSimpleUpgradeable.ProposalVote storage proposalVote,
        uint256 vetoThreshold
    ) external {
        require(proposalCore.proposer == msg.sender, IReserveOptimisticGovernor.NotOptimisticProposer(msg.sender));

        require(
            state(proposal.proposalId, proposalCore, proposalVote, vetoThreshold) == IGovernor.ProposalState.Succeeded,
            IReserveOptimisticGovernor.OptimisticProposalNotSuccessful(proposal.proposalId)
        );

        proposalCore.executed = true;
        emit IGovernor.ProposalExecuted(proposal.proposalId);

        _timelock().executeBatchBypass{ value: msg.value }(
            proposal.targets,
            proposal.values,
            proposal.calldatas,
            0,
            bytes20(address(this)) ^ keccak256(bytes(proposal.description))
        );
    }

    /// Possibly transition optimistic proposal to pessimistic proposal for confirmation vote
    /// @dev Called by ReserveOptimisticGovernor._tallyUpdated in optimistic case
    function tallyUpdated(
        uint256 proposalId,
        GovernorUpgradeable.ProposalCore storage proposalCore,
        GovernorCountingSimpleUpgradeable.ProposalVote storage proposalVote,
        mapping(uint256 proposalId => uint256 vetoThreshold) storage vetoThresholds
    ) external {
        // check for optimistic -> pessimistic transition

        if (
            state(proposalId, proposalCore, proposalVote, vetoThresholds[proposalId])
                == IGovernor.ProposalState.Defeated
        ) {
            // optimistic -> pessimistic
            vetoThresholds[proposalId] = 0;

            GovernorUpgradeable governor = GovernorUpgradeable(payable(address(this)));
            uint256 snapshot = block.timestamp + governor.votingDelay();
            uint256 duration = governor.votingPeriod();

            proposalCore.voteStart = SafeCast.toUint48(snapshot);
            proposalCore.voteDuration = SafeCast.toUint32(duration);

            emit IReserveOptimisticGovernor.ConfirmationVoteScheduled(proposalId, snapshot, snapshot + duration);
        }
    }

    function state(
        uint256 proposalId,
        GovernorUpgradeable.ProposalCore storage proposalCore,
        GovernorCountingSimpleUpgradeable.ProposalVote storage proposalVote,
        uint256 vetoThreshold
    ) public view returns (IGovernor.ProposalState) {
        require(vetoThreshold != 0, IReserveOptimisticGovernor.OptimisticProposalNotOngoing(proposalId));

        if (proposalCore.executed) {
            return IGovernor.ProposalState.Executed;
        }

        if (proposalCore.canceled) {
            return IGovernor.ProposalState.Canceled;
        }

        uint256 snapshot = proposalCore.voteStart;

        if (snapshot >= block.timestamp) {
            return IGovernor.ProposalState.Pending;
        }

        IERC5805 token = ReserveOptimisticGovernor(payable(address(this))).token();

        // {tok}
        uint256 pastSupply = token.getPastTotalSupply(snapshot - 1);
        if (pastSupply == 0) {
            return IGovernor.ProposalState.Canceled;
        }

        // {tok} = D18{1} * {tok} / D18{1}
        uint256 vetoThresholdTok = (vetoThreshold * pastSupply + (1e18 - 1)) / 1e18;

        if (proposalVote.againstVotes >= vetoThresholdTok) {
            return IGovernor.ProposalState.Defeated;
        }

        // {s}
        uint256 deadline = proposalCore.voteStart + proposalCore.voteDuration;

        if (deadline >= block.timestamp) {
            return IGovernor.ProposalState.Active;
        }

        return IGovernor.ProposalState.Succeeded;
    }

    // === Private ===

    /// @dev GovernorUpgradeable._isValidDescriptionForProposer
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

    /// @dev GovernorUpgradeable._unsafeReadBytesOffset
    function _unsafeReadBytesOffset(bytes memory buffer, uint256 offset) private pure returns (bytes32 value) {
        // This is not memory safe in the general case, but all calls to this private function are within bounds.
        assembly ("memory-safe") {
            value := mload(add(add(buffer, 0x20), offset))
        }
    }

    function _timelock() private view returns (TimelockControllerOptimistic) {
        return TimelockControllerOptimistic(payable(ReserveOptimisticGovernor(payable(address(this))).timelock()));
    }
}
