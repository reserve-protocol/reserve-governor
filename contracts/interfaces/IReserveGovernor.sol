// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

// TODO include hash
bytes32 constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
bytes32 constant OPTIMISTIC_PROPOSER_ROLE = keccak256("OPTIMISTIC_PROPOSER_ROLE");
uint256 constant MIN_OPTIMISTIC_VETO_PERIOD = 1 hours;
uint256 constant MAX_VETO_THRESHOLD = 0.2e18; // 20%
uint256 constant MAX_PARALLEL_OPTIMISTIC_PROPOSALS = 5;

interface IReserveGovernor {
    // === Errors ===

    error ExistingOptimisticProposal(uint256 proposalId);
    error OptimisticProposalNotReady(uint256 proposalId);
    error InvalidVetoParameters();
    error NotOptimisticProposer(address account);
    error NoMetaGovernanceThroughOptimistic();
    error TooManyParallelOptimisticProposals();

    // === Events ===

    event OptimisticProposalCreated(
        address indexed proposer,
        uint256 indexed proposalId,
        address[] targets,
        uint256[] values,
        bytes[] calldatas,
        string description,
        uint256 vetoPeriod,
        uint256 vetoThreshold,
        uint256 slashingPercentage
    );

    // === Enums ===

    enum ProposalType {
        Optimistic,
        Standard
    }

    // === Structs ===

    struct OptimisticGovernanceParams {
        uint256 vetoPeriod; // {s}
        uint256 vetoThreshold; // D18{1}
        uint256 slashingPercentage; // D18{1}
        uint256 numParallelProposals; // number of proposals that can be running in parallel
    }

    struct StandardGovernanceParams {
        uint48 votingDelay; // {s}
        uint32 votingPeriod; // {s}
        uint48 voteExtension; // {s}
        uint256 proposalThreshold; // D18{1}
        uint256 quorumNumerator; // 0-100
    }
}
