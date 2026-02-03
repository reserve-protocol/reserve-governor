// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IReserveOptimisticGovernor {
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

    function initialize(
        OptimisticGovernanceParams calldata optimisticGovParams,
        StandardGovernanceParams calldata standardGovParams,
        address _token,
        address _timelock,
        address _selectorRegistry
    ) external;
}
