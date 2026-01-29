// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

bytes32 constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE"); // 0xb09aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1
bytes32 constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE"); // 0xd8aa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63
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
    error NotOptimisticProposal(address account);
    error InvalidFunctionCall(address target, bytes4 selector);
    error InvalidFunctionCallToEOA(address target);
    error TooManyParallelOptimisticProposals();
    error InvalidProposalLengths();

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

    // === Data ===

    enum ProposalType {
        Optimistic,
        Standard
    }

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
        uint256 quorumNumerator; // D18{1}
    }
}
