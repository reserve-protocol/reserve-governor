// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC5805 } from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";

import { IOptimisticSelectorRegistry } from "./IOptimisticSelectorRegistry.sol";

interface IReserveOptimisticGovernor is IGovernor {
    // === Errors ===

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

    function lateQuorumVoteExtension() external view returns (uint48);

    function optimisticParams() external view returns (uint48 vetoDelay, uint32 vetoPeriod, uint256 vetoThreshold);

    function proposalThrottleCapacity() external view returns (uint256);

    function proposalThrottleCharges(address account) external view returns (uint256);

    function proposalVotes(uint256 proposalId)
        external
        view
        returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes);

    function proposeOptimistic(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string calldata description
    ) external returns (uint256 proposalId);

    function quorumDenominator() external pure returns (uint256);

    function quorumNumerator() external view returns (uint256);

    function quorumNumerator(uint256 timepoint) external view returns (uint256);

    function relay(address target, uint256 value, bytes calldata data) external payable;

    function selectorRegistry() external view returns (IOptimisticSelectorRegistry);

    function setLateQuorumVoteExtension(uint48 newVoteExtension) external;

    function setOptimisticParams(OptimisticGovernanceParams calldata params) external;

    function setProposalThreshold(uint256 newProposalThreshold) external;

    function setProposalThrottle(uint256 newProposalThrottleCapacity) external;

    function setVotingDelay(uint48 newVotingDelay) external;

    function setVotingPeriod(uint32 newVotingPeriod) external;

    function token() external view returns (IERC5805);

    function updateQuorumNumerator(uint256 newQuorumNumerator) external;

    function updateTimelock(address newTimelock) external;

    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;

    function getOptimisticVotes(address account, uint256 timepoint) external view returns (uint256);

    function isOptimistic(uint256 proposalId) external view returns (bool);

    function timelock() external view returns (address);

    function vetoThreshold(uint256 proposalId) external view returns (uint256);

    function cancel(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external returns (uint256);
}
