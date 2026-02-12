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
    error InvalidCall(address target, bytes call);
    error ProposalThrottleExceeded();

    // === Events ===

    /// @param vetoThreshold D18{1} Fraction of token supply required to start confirmation process
    event OptimisticProposalCreated(uint256 indexed proposalId, uint256 vetoThreshold);
    event ConfirmationVoteScheduled(uint256 indexed proposalId, uint256 voteStart, uint256 voteEnd);
    event ProposalThrottleUpdated(uint256 throttleCapacity);

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
        uint256 proposalThrottleCapacity; // proposals-per-account per 24h
    }

    struct ProposalThrottleStorage {
        uint256 capacity; // max number of proposals per 24h
        mapping(address account => ProposalThrottle) throttles;
    }

    struct ProposalThrottle {
        uint256 currentCharge; // D18{1}
        uint256 lastUpdated; // {s}
    }

    function initialize(
        OptimisticGovernanceParams calldata optimisticGovParams,
        StandardGovernanceParams calldata standardGovParams,
        address _token,
        address _timelock,
        address _selectorRegistry
    ) external;
}
