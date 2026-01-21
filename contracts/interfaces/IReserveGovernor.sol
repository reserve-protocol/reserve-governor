// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

bytes32 constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE"); // 0xfd643c72710c63c0180259aba6b2d05451e3591a24e58b62239378085726f783
bytes32 constant OPTIMISTIC_PROPOSER_ROLE = keccak256("OPTIMISTIC_PROPOSER_ROLE"); // 0x26f49d08685d9cdd4951a7470bc8fbe9dd0f00419c1a44c1b89f845867ae12e0
uint256 constant MIN_OPTIMISTIC_VETO_PERIOD = 30 minutes;
uint256 constant MAX_VETO_THRESHOLD = 0.2e18; // 20%
uint256 constant MAX_PARALLEL_OPTIMISTIC_PROPOSALS = 5;

interface IReserveGovernor {
    // === Errors ===

    error ExistingOptimisticProposal(uint256 proposalId);
    error OptimisticProposalNotSuccessful(uint256 proposalId);
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
        uint32 vetoPeriod; // {s}
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
