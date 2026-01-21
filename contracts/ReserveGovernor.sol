// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

import { GovernorUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
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
 * @title ReserveGovernor
 * @notice A hybrid optimistic/pessimistic governor for the Reserve protocol
 *
 * @dev 3 overall components:
 *    1. OptimisticProposal: New contract per optimistic proposal to support staking + slashing
 *    2. ReserveGovernor: Hybrid governor that unifies proposalIds for optimistic/pessimistic flows
 *    3. TimelockControllerOptimistic: Single timelock that executes everything, with bypass for optimistic case
 *
 *   Intended to be used with a 1-governance-system-per-token model, NOT shared.
 *   If tokens belong to multiple governance systems there can be contention for veto staking.
 */
contract ReserveGovernor is
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorPreventLateQuorumUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    GovernorVotesQuorumFractionUpgradeable,
    GovernorTimelockControlUpgradeable,
    IReserveGovernor
{
    using EnumerableSet for EnumerableSet.AddressSet;

    address public immutable optimisticProposalImpl;

    OptimisticGovernanceParams public optimisticParams;

    mapping(uint256 proposalId => OptimisticProposal) public optimisticProposals;
    EnumerableSet.AddressSet private activeOptimisticProposals;

    constructor() {
        _disableInitializers();

        optimisticProposalImpl = address(new OptimisticProposal());
    }

    /// @param optimisticGovParams.vetoPeriod {s} Veto period
    /// @param optimisticGovParams.vetoThreshold D18{1} Fraction of tok supply required to start dispute process
    /// @param optimisticGovParams.slashingPercentage D18{1} Percentage of staked tokens to be slashed
    /// @param standardGovParams.votingDelay {s} Delay before snapshot
    /// @param standardGovParams.votingPeriod {s} Voting period
    /// @param standardGovParams.proposalThreshold D18{1} Fraction of tok supply required to propose
    /// @param standardGovParams.voteExtension {s} Time extension for late quorum
    /// @param standardGovParams.quorumNumerator 0-100
    function initialize(
        OptimisticGovernanceParams calldata optimisticGovParams,
        StandardGovernanceParams calldata standardGovParams,
        IVetoToken _token,
        address _timelock
    ) public initializer {
        __Governor_init("Reserve Governor");
        __GovernorSettings_init(
            standardGovParams.votingDelay, standardGovParams.votingPeriod, standardGovParams.proposalThreshold
        );
        __GovernorPreventLateQuorum_init(standardGovParams.voteExtension);
        __GovernorCountingSimple_init();
        __GovernorVotes_init(_token);
        __GovernorVotesQuorumFraction_init(standardGovParams.quorumNumerator);
        __GovernorTimelockControl_init(TimelockControllerUpgradeable(payable(_timelock)));

        _setOptimisticParams(optimisticGovParams);

        // confirm `_token` is burnable
        _token.burn(0);
    }

    function setOptimisticParams(OptimisticGovernanceParams calldata params) external onlyGovernance {
        _setOptimisticParams(params);
    }

    // === Optimistic flow ===

    /// @param description Exclude `#proposer=0x???` suffix
    /// @return proposalId The ID of the proposed optimistic proposal
    function proposeOptimistic(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string memory description
    ) external returns (uint256 proposalId) {
        require(_isOptimisticProposer(_msgSender()), NotOptimisticProposer(_msgSender()));

        OptimisticProposalLib.clearCompletedOptimisticProposals(activeOptimisticProposals);

        // prevent targeting this contract or the timelock
        for (uint256 i = 0; i < targets.length; i++) {
            require(
                targets[i] != address(this) && targets[i] != address(timelock()), NoMetaGovernanceThroughOptimistic()
            );
        }

        OptimisticProposal optimisticProposal = OptimisticProposal(Clones.clone(optimisticProposalImpl));

        // ensure ONLY the OptimisticProposal can create the dispute proposal
        description = string.concat(description, "#proposer=", Strings.toHexString(address(optimisticProposal)));

        proposalId = getProposalId(targets, values, calldatas, keccak256(bytes(description)));

        optimisticProposal.initialize(optimisticParams, proposalId, targets, values, calldatas, description);

        require(address(optimisticProposals[proposalId]) == address(0), ExistingOptimisticProposal(proposalId));
        optimisticProposals[proposalId] = optimisticProposal;

        require(
            activeOptimisticProposals.length() < optimisticParams.numParallelProposals,
            TooManyParallelOptimisticProposals()
        );
        activeOptimisticProposals.add(address(optimisticProposal));

        emit OptimisticProposalCreated(
            _msgSender(),
            proposalId,
            targets,
            values,
            calldatas,
            description,
            optimisticParams.vetoPeriod,
            optimisticParams.vetoThreshold,
            optimisticParams.slashingPercentage
        );
    }

    /// Execute an optimistic proposal that passed successfully without dispute
    function executeOptimistic(uint256 proposalId) external payable {
        require(_isOptimisticProposer(_msgSender()), NotOptimisticProposer(_msgSender()));

        OptimisticProposal optimisticProposal = optimisticProposals[proposalId];

        require(
            optimisticProposal.state() == OptimisticProposal.OptimisticProposalState.Succeeded,
            OptimisticProposalNotSuccessful(proposalId)
        );

        // mark executed (for compatibility with legacy offchain monitoring)
        _getGovernorStorage()._proposals[proposalId].executed = true;

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            optimisticProposal.proposalData();

        emit ProposalCreated(
            proposalId, _msgSender(), targets, values, new string[](targets.length), calldatas, 0, 0, description
        );
        emit ProposalExecuted(proposalId);

        TimelockControllerOptimistic(payable(timelock())).executeBatchBypass{ value: msg.value }(
            targets, values, calldatas, 0, bytes20(address(this)) ^ keccak256(bytes(description))
        );
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

    function _propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        address proposer
    ) internal override returns (uint256) {
        return super._propose(targets, values, calldatas, description, proposer);
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
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);

        if (address(optimisticProposals[proposalId]) != address(0)) {
            optimisticProposals[proposalId].slash();
        }
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
        return _isGuardian(caller)
            || (_isOptimisticProposer(caller) && address(optimisticProposals[proposalId]) != address(0))
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
                && params.vetoThreshold <= MAX_VETO_THRESHOLD && params.slashingPercentage != 0
                && params.slashingPercentage <= 1e18
                && params.numParallelProposals <= MAX_PARALLEL_OPTIMISTIC_PROPOSALS,
            InvalidVetoParameters()
        );
        optimisticParams = params;
    }

    function _isGuardian(address account) private view returns (bool) {
        return TimelockControllerOptimistic(payable(timelock())).hasRole(CANCELLER_ROLE, account);
    }

    function _isOptimisticProposer(address account) private view returns (bool) {
        return TimelockControllerOptimistic(payable(timelock())).hasRole(OPTIMISTIC_PROPOSER_ROLE, account);
    }

    // TODO: contract size
    // TODO: deployer for the whole system, must remember to setup OPTIMISTIC_PROPOSER_ROLE on the timelock
    // TODO: Add burn() to StakingVault/StRSR
}
