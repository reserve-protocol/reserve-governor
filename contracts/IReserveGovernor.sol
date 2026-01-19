// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IReserveGovernor {
    // === Events ===

    event OptimisticProposerGranted(address indexed account);
    event OptimisticProposerRevoked(address indexed account);
    event OptimisticProposalCreated(
        uint256 indexed proposalId,
        address[] targets,
        uint256[] values,
        bytes[] calldatas,
        string description,
        uint256 vetoEnd,
        uint256 vetoThresholdAmt,
        uint256 slashingPercentage
    );
    event OptimisticProposalExecuted(uint256 indexed proposalId);
    event OptimisticProposalCanceled(uint256 indexed proposalId);

    // === Errors ===

    error ExistingOptimisticProposal(uint256 proposalId);
    error InvalidVetoParameters();
    error ProposalDoesNotExist(uint256 proposalId);
    error NotOptimisticProposer(address account);
    error ProposalAlreadyCanceled(uint256 proposalId);
    error ProposalNotReady(uint256 proposalId);
    error NotAuthorizedToCancel(address account);

    // === Structs ===

    struct ProposalDetails {
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        bytes32 descriptionHash;
    }

    // === stack-too-deep

    struct OptimisticGovernanceParams {
        uint256 vetoPeriod; // {s}
        uint256 vetoThreshold; // D18{1}
        uint256 slashingPercentage; // D18{1}
        address[] optimisticProposers;
    }

    struct StandardGovernanceParams {
        uint48 votingDelay; // {s}
        uint32 votingPeriod; // {s}
        uint48 voteExtension; // {s}
        uint256 proposalThreshold; // D18{1}
        uint256 quorumNumerator; // 0-100
    }
}
