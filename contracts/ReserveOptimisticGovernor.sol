// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { GovernorUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {
    GovernorCountingSimpleUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import {
    GovernorPreventLateQuorumUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorPreventLateQuorumUpgradeable.sol";
import {
    GovernorSettingsUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import {
    GovernorTimelockControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import {
    GovernorVotesQuorumFractionUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesQuorumFractionUpgradeable.sol";
import {
    GovernorVotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";

import { OptimisticProposal } from "./OptimisticProposal.sol";
import { SelectorRegistry } from "./SelectorRegistry.sol";
import { TimelockControllerOptimistic } from "./TimelockControllerOptimistic.sol";
import {
    CANCELLER_ROLE,
    IReserveGovernor,
    MAX_PARALLEL_OPTIMISTIC_PROPOSALS,
    MAX_VETO_THRESHOLD,
    MIN_OPTIMISTIC_VETO_PERIOD,
    OPTIMISTIC_PROPOSER_ROLE
} from "./interfaces/IReserveGovernor.sol";
import { IVetoToken } from "./interfaces/IVetoToken.sol";
import { OptimisticProposalLib } from "./libraries/OptimisticProposalLib.sol";

/**
 * @title Reserve Optimistic Governor
 * @notice A hybrid optimistic/pessimistic governor for the Reserve protocol
 *
 * @dev 4 overall components:
 *    1. ReserveGovernor: Hybrid governor that unifies proposalIds for optimistic/pessimistic flows
 *    2. SelectorRegistry: Registry of allowed selectors for optimistic proposals
 *    3. TimelockControllerOptimistic: Single timelock that executes everything, with bypass for optimistic case
 *    4. OptimisticProposal: One-off contract per optimistic proposal to support staking + slashing
 *
 *   Intended to be used with a 1-governance-system-per-token model, NOT shared.
 *   If tokens belong to multiple governance systems there can be contention for veto staking.
 */
contract ReserveOptimisticGovernor is
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorPreventLateQuorumUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    GovernorVotesQuorumFractionUpgradeable,
    GovernorTimelockControlUpgradeable,
    UUPSUpgradeable,
    IReserveGovernor
{
    address public immutable optimisticProposalImpl;

    OptimisticGovernanceParams public optimisticParams;

    mapping(uint256 proposalId => OptimisticProposal) public optimisticProposals;
    EnumerableSet.AddressSet private activeOptimisticProposals;

    SelectorRegistry public selectorRegistry;

    constructor() {
        _disableInitializers();

        optimisticProposalImpl = address(new OptimisticProposal());
    }

    /// @param optimisticGovParams.vetoPeriod {s} Veto period
    /// @param optimisticGovParams.vetoThreshold D18{1} Fraction of tok supply required to start dispute process
    /// @param optimisticGovParams.slashingPercentage D18{1} Percentage of staked tokens to be slashed
    /// @param optimisticGovParams.numParallelProposals Number of optimistic proposals that can be in parallel
    /// @param standardGovParams.votingDelay {s} Delay before snapshot
    /// @param standardGovParams.votingPeriod {s} Voting period
    /// @param standardGovParams.proposalThreshold D18{1} Fraction of tok supply required to propose
    /// @param standardGovParams.voteExtension {s} Time extension for late quorum
    /// @param standardGovParams.quorumNumerator 0-100
    function initialize(
        OptimisticGovernanceParams calldata optimisticGovParams,
        StandardGovernanceParams calldata standardGovParams,
        IVetoToken _token,
        address _timelock,
        address _selectorRegistry
    ) public initializer {
        __Governor_init("Reserve Optimistic Governor");
        __GovernorSettings_init(
            standardGovParams.votingDelay, standardGovParams.votingPeriod, standardGovParams.proposalThreshold
        );
        __GovernorPreventLateQuorum_init(standardGovParams.voteExtension);
        __GovernorCountingSimple_init();
        __GovernorVotes_init(_token);
        __GovernorVotesQuorumFraction_init(standardGovParams.quorumNumerator);
        __GovernorTimelockControl_init(TimelockControllerUpgradeable(payable(_timelock)));

        _setOptimisticParams(optimisticGovParams);

        // confirm selector registry is callable
        SelectorRegistry(payable(_selectorRegistry)).isAllowed(address(1), IVetoToken.burn.selector);
        selectorRegistry = SelectorRegistry(payable(_selectorRegistry));

        // confirm token is burnable
        _token.burn(0);
    }

    function setOptimisticParams(OptimisticGovernanceParams calldata params) external onlyGovernance {
        _setOptimisticParams(params);
    }

    // === Optimistic flow ===

    /// @param description Exclude `#proposer=0x???` suffix, it will be ignored
    /// @return proposalId The ID of the proposed optimistic proposal
    function proposeOptimistic(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string calldata description
    ) external returns (uint256 proposalId) {
        _requireOptimisticProposer(_msgSender());

        proposalId = OptimisticProposalLib.createOptimisticProposal(
            OptimisticProposalLib.ProposalData(targets, values, calldatas, description),
            optimisticProposals,
            activeOptimisticProposals,
            optimisticParams,
            optimisticProposalImpl,
            selectorRegistry
        );
    }

    /// Execute an optimistic proposal that passed successfully without dispute
    function executeOptimistic(uint256 proposalId) external payable {
        _requireOptimisticProposer(_msgSender());

        OptimisticProposalLib.executeOptimisticProposal(proposalId, optimisticProposals, _getGovernorStorage());
    }

    /// @return The number of active optimistic proposals
    function activeOptimisticProposalsCount() external view returns (uint256) {
        return OptimisticProposalLib.activeOptimisticProposalsCount(activeOptimisticProposals);
    }

    /// @dev If ProposalType.Standard, call `state()`
    /// @dev If ProposalType.Optimistic, call `optimisticProposal.state()`
    /// @return ProposalType.Optimistic | ProposalType.Standard
    function proposalType(uint256 proposalId) public view returns (ProposalType) {
        if (proposalSnapshot(proposalId) != 0) {
            return ProposalType.Standard;
        }

        if (address(optimisticProposals[proposalId]) != address(0)) {
            return ProposalType.Optimistic;
        }

        revert GovernorNonexistentProposal(proposalId);
    }

    // === Inheritance overrides ===

    /// @dev Call proposalType() to determine whether to call `state()` or `optimisticProposal.state()`
    function state(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalDeadline(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorPreventLateQuorumUpgradeable)
        returns (uint256)
    {
        return super.proposalDeadline(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    /// @return {tok} The number of votes required in order for a voter to become a proposer
    function proposalThreshold()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        uint256 proposalThresholdRatio = super.proposalThreshold(); // D18{1}

        // {tok}
        uint256 supply = token().getPastTotalSupply(clock() - 1);

        // CEIL to make sure thresholds near 0% don't get rounded down to 0 tokens
        return (proposalThresholdRatio * supply + (1e18 - 1)) / 1e18;
    }

    /// Propose a dispute proposal, only callable by an OptimisticProposal
    function proposeDispute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        address initialProposer,
        uint256 initialVotesAgainst
    ) public returns (uint256 proposalId) {
        address caller = _msgSender();

        proposalId = _propose(targets, values, calldatas, description, initialProposer);

        require(caller == address(optimisticProposals[proposalId]), NotOptimisticProposal(caller));

        // cast initial AGAINST votes
        uint256 votedWeight = _countVote(proposalId, caller, uint8(VoteType.Against), initialVotesAgainst, "");
        emit VoteCast(caller, proposalId, uint8(VoteType.Against), votedWeight, "");
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
        if (address(optimisticProposals[proposalId]) != address(0)) {
            optimisticProposals[proposalId].slash();
        }

        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint256 proposalId) {
        proposalId = super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _validateCancel(uint256 proposalId, address caller) internal view override returns (bool) {
        return TimelockControllerOptimistic(payable(timelock())).hasRole(CANCELLER_ROLE, caller)
            || super._validateCancel(proposalId, caller);
    }

    function _executor()
        internal
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        return super._executor();
    }

    function _tallyUpdated(uint256 proposalId)
        internal
        override(GovernorUpgradeable, GovernorPreventLateQuorumUpgradeable)
    {
        super._tallyUpdated(proposalId);
    }

    // === Private ===

    function _setOptimisticParams(OptimisticGovernanceParams calldata params) private {
        require(
            params.vetoPeriod >= MIN_OPTIMISTIC_VETO_PERIOD && params.vetoThreshold != 0
                && params.vetoThreshold <= MAX_VETO_THRESHOLD && params.slashingPercentage <= 1e18
                && params.numParallelProposals <= MAX_PARALLEL_OPTIMISTIC_PROPOSALS,
            InvalidVetoParameters()
        );
        optimisticParams = params;
    }

    function _requireOptimisticProposer(address account) private view {
        require(
            TimelockControllerOptimistic(payable(timelock())).hasRole(OPTIMISTIC_PROPOSER_ROLE, account),
            NotOptimisticProposer(account)
        );
    }

    /// @dev Upgrades authorized only through timelock (governance)
    function _authorizeUpgrade(address) internal override onlyGovernance { }
}
