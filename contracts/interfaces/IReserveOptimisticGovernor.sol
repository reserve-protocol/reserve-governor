// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IReserveOptimisticGovernor {
    // === Errors ===

    error OptimisticGovernor__InvalidToken();
    error OptimisticGovernor__InvalidProposalThreshold();
    error OptimisticGovernor__InvalidProposalThrottle();
    error OptimisticGovernor__InvalidOptimisticParameters();
    error OptimisticGovernor__OptimisticProposalCannotBeQueued(uint256 proposalId);
    error OptimisticGovernor__NotOptimisticProposer(address account);
    error OptimisticGovernor__ConfirmationPrefixNotAllowed();
    error OptimisticGovernor__InvalidCall(address target, bytes call);
    error OptimisticGovernor__ProposalThrottleExceeded();
    error OptimisticGovernor__InvalidDelay();
    error OptimisticGovernor__OptimisticProposalCanOnlyBeVetoed(uint256 proposalId);

    // === Events ===

    /// @param vetoThreshold D18{1} Fraction of token supply required to start confirmation process
    event OptimisticProposalCreated(uint256 indexed proposalId, uint256 vetoThreshold);
    event ProposalThrottleUpdated(uint256 throttleCapacity);
    event OptimisticParamsUpdated(OptimisticGovernanceParams optimisticParams);

    // === Data ===

    struct OptimisticProposalDetails {
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
        uint256 vetoThreshold; // D18{1} Fraction of token supply required to start confirmation process
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
        uint256 _proposalThrottleCapacity,
        address _token,
        address _timelock,
        address _selectorRegistry
    ) external;

    function isOptimistic(uint256 proposalId) external view returns (bool);

    function timelock() external view returns (address);

    function cancel(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external returns (uint256);
}
