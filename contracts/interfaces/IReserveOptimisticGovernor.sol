// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    GovernorCountingSimpleUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";

interface IReserveOptimisticGovernor {
    // === Errors ===

    error InvalidProposalThreshold();
    error InvalidProposalThrottle();
    error InvalidOptimisticParameters();
    error OptimisticProposalCannotBeQueued(uint256 proposalId);
    error NotOptimisticProposer(address account);
    error ConfirmationPrefixNotAllowed();
    error InvalidCall(address target, bytes call);
    error ProposalThrottleExceeded();
    error InvalidDelay();

    // === Events ===

    /// @param vetoThreshold D18{1} Fraction of token supply required to start confirmation process
    event OptimisticProposalCreated(uint256 indexed proposalId, uint256 vetoThreshold);
    event ProposalThrottleUpdated(uint256 throttleCapacity);

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
        uint256 proposalThrottleCapacity; // proposals-per-account per 24h
    }

    function initialize(
        OptimisticGovernanceParams calldata optimisticGovParams,
        StandardGovernanceParams calldata standardGovParams,
        address _token,
        address _timelock,
        address _selectorRegistry
    ) external;
}
