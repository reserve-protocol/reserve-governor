// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    GovernorCountingSimpleUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";

interface IReserveOptimisticGovernor {
    // === Errors ===

    error ExistingProposal(uint256 proposalId);
    error OptimisticProposalNotOngoing(uint256 proposalId);
    error OptimisticProposalNotSuccessful(uint256 proposalId);
    error InvalidProposalThreshold();
    error InvalidOptimisticParameters();
    error NotOptimisticProposer(address account);
    error InvalidEmptyCall(address target, bytes data);
    error InvalidFunctionCall(address target, bytes4 selector);
    error InvalidFunctionCallToEOA(address target);
    error InvalidProposalLengths();

    // === Events ===

    /// @param vetoStart {s} Start of the veto period
    /// @param vetoEnd {s} End of the veto period
    /// @param vetoThreshold D18{1} Fraction of token supply required to trigger veto and start confirmation process
    event OptimisticProposalCreated(
        uint256 indexed proposalId, uint256 vetoStart, uint256 vetoEnd, uint256 vetoThreshold
    );
    event ConfirmationVoteScheduled(uint256 indexed proposalId, uint256 voteStart, uint256 voteEnd);

    // === Data ===

    enum ProposalType {
        Optimistic,
        Standard
    }

    struct OptimisticGovernanceParams {
        uint48 vetoDelay; // {s}
        uint32 vetoPeriod; // {s}
        uint256 vetoThreshold; // D18{1}
    }

    struct StandardGovernanceParams {
        uint48 votingDelay; // {s}
        uint32 votingPeriod; // {s}
        uint48 voteExtension; // {s}
        uint256 proposalThreshold; // D18{1}
        uint256 quorumNumerator; // D18{1}
    }

    function initialize(
        OptimisticGovernanceParams calldata optimisticGovParams,
        StandardGovernanceParams calldata standardGovParams,
        address _token,
        address _timelock,
        address _selectorRegistry
    ) external;
}
