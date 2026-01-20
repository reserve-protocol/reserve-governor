// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

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
import { TimelockControllerBypassable } from "./TimelockControllerBypassable.sol";

import {
    CANCELLER_ROLE,
    IReserveGovernor,
    MAX_PARALLEL_OPTIMISTIC_PROPOSALS,
    MAX_VETO_PERIOD,
    MAX_VETO_THRESHOLD,
    MIN_VETO_PERIOD,
    OPTIMISTIC_PROPOSER_ROLE
} from "./interfaces/IReserveGovernor.sol";

/**
 * @title ReserveGovernor
 * @notice An optimistic-by-default hybrid governor for the Reserve protocol
 *
 * @dev 3 overall components:
 *    1. OptimisticProposal: New contract per optimistic proposal to support veto + locking logic
 *    2. ReserveGovernor: Hybrid governor that contains both optimistic and pessimistic governance flows
 *    3. TimelockControllerBypassable: Single timelock that executes both optimistic and pessimistic proposals
 *
 *   Intended to be used with a 1-token-per-governance system model, e.g
 *     - vlDTF (index protocol)
 *     - stRSR (yield protocol)
 *   If tokens belong to multiple governance systems, there can be contention for staking to veto.
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
    using Clones for address;

    OptimisticProposal public immutable optimisticProposalImpl;

    OptimisticGovernanceParams public optimisticParams;

    mapping(uint256 proposalId => OptimisticProposal) public optimisticProposals;
    uint256 public optimisticProposalCount;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();

        optimisticProposalImpl = new OptimisticProposal();
    }

    /// @param optimisticGovParams.vetoPeriod {s} Veto period
    /// @param optimisticGovParams.vetoThreshold D18{1} Fraction of tok supply required to start adjudication
    /// @param optimisticGovParams.slashingPercentage D18{1} Percentage of staked tokens to be slashed
    /// @param standardGovParams.votingDelay {s} Delay before snapshot
    /// @param standardGovParams.votingPeriod {s} Voting period
    /// @param standardGovParams.proposalThreshold D18{1} Fraction of tok supply required to propose
    /// @param standardGovParams.voteExtension {s} Time extension for late quorum
    /// @param standardGovParams.quorumNumerator 0-100
    function initialize(
        OptimisticGovernanceParams calldata optimisticGovParams,
        StandardGovernanceParams calldata standardGovParams,
        IVotes _token,
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
    }

    function setOptimisticParams(OptimisticGovernanceParams calldata params) external onlyGovernance {
        _setOptimisticParams(params);
    }

    // === Optimistic proposer ===

    modifier onlyOptimisticProposer() {
        require(
            TimelockControllerBypassable(payable(timelock())).hasRole(OPTIMISTIC_PROPOSER_ROLE, _msgSender()),
            NotOptimisticProposer(_msgSender())
        );
        _;
    }

    // === Optimistic flow ===

    /// @param description Exclude `#proposer=0x???` suffix
    /// @return proposalId The ID of the proposed optimistic proposal
    function proposeOptimistic(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string memory description
    ) public onlyOptimisticProposer returns (uint256 proposalId) {
        // prevent targeting this contract or the timelock via optimistic proposals
        for (uint256 i = 0; i < targets.length; i++) {
            require(
                targets[i] != address(this) && targets[i] != address(timelock()), NoMetaGovernanceThroughOptimistic()
            );
        }

        OptimisticProposal optimisticProposal = OptimisticProposal(address(optimisticProposalImpl).clone());

        // prevent front-running of someone creating the same proposal in the standard flow
        description = string.concat(description, "#proposer=", Strings.toHexString(address(optimisticProposal)));

        proposalId = getProposalId(targets, values, calldatas, keccak256(bytes(description)));

        require(address(optimisticProposals[proposalId]) == address(0), ExistingOptimisticProposal(proposalId));
        optimisticProposals[proposalId] = optimisticProposal;

        optimisticProposalCount++;
        require(optimisticProposalCount <= optimisticParams.numParallelProposals, TooManyParallelOptimisticProposals());

        optimisticProposal.initialize(optimisticParams, proposalId, targets, values, calldatas, description);

        emit OptimisticProposalCreated(
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

    /// Execute an optimistic proposal that has passed successfully without going through the adjudication process
    function executeOptimistic(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) public payable onlyOptimisticProposer {
        uint256 proposalId = getProposalId(targets, values, calldatas, descriptionHash);

        // require successful optimistic proposal and no existing standard proposal
        require(
            optimisticProposals[proposalId].state() == OptimisticProposal.OptimisticProposalState.Succeeded
                && proposalSnapshot(proposalId) == 0,
            OptimisticProposalNotReady(proposalId)
        );
        optimisticProposalCount--;

        TimelockControllerBypassable(payable(timelock())).executeBatchBypass{ value: msg.value }(
            targets, values, calldatas, 0, bytes20(address(this)) ^ descriptionHash
        );
        // salt mirrors GovernorTimelockControlUpgradeable._timelockSalt()

        emit OptimisticProposalExecuted(proposalId);
    }

    /// Cancel an optimistic proposal while adjudication is not ongoing
    function cancelOptimistic(uint256 proposalId) public {
        ProposalState _state = state(proposalId);

        // TODO can we find a better way to clear the optimistic proposal queue? the problem is we don't know
        // when a slow proposal fails to pass, so we need the optimistic proposers to take an explicit action
        require(
            (proposalSnapshot(proposalId) == 0 || _state == ProposalState.Defeated || _state == ProposalState.Expired)
                && (TimelockControllerBypassable(payable(timelock())).hasRole(CANCELLER_ROLE, _msgSender())
                    || TimelockControllerBypassable(payable(timelock()))
                        .hasRole(OPTIMISTIC_PROPOSER_ROLE, _msgSender())),
            NotAuthorizedToCancel(_msgSender())
        );
        optimisticProposalCount--;

        optimisticProposals[proposalId].cancel();
        emit OptimisticProposalCanceled(proposalId);
    }

    /// @return The OVERALL state of the proposal, merging both optimistic and standard flows together
    function metaState(uint256 proposalId) public view returns (MetaProposalState) {
        if (address(optimisticProposals[proposalId]) != address(0)) {
            OptimisticProposal.OptimisticProposalState optimisticState = optimisticProposals[proposalId].state();

            if (optimisticState == OptimisticProposal.OptimisticProposalState.Active) {
                return MetaProposalState.Optimistic;
            }

            if (optimisticState == OptimisticProposal.OptimisticProposalState.Succeeded) {
                return MetaProposalState.Succeeded;
            }
        }

        return MetaProposalState(uint8(state(proposalId)) + 1); // +1 to skip Optimistic state
    }

    // === Inheritance overrides ===

    /// @dev As an external consumer of this contract, use metaState() instead
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
            optimisticProposalCount--;
        }
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint256 proposalId) {
        proposalId = super._cancel(targets, values, calldatas, descriptionHash);

        if (address(optimisticProposals[proposalId]) != address(0)) {
            optimisticProposalCount--;
        }
    }

    function _validateCancel(uint256 proposalId, address caller) internal view override returns (bool) {
        return state(proposalId) == ProposalState.Pending
            && (TimelockControllerBypassable(payable(timelock())).hasRole(CANCELLER_ROLE, caller)
                || caller == proposalProposer(proposalId));
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

    function _setOptimisticParams(OptimisticGovernanceParams calldata params) internal {
        require(
            params.vetoPeriod != MIN_VETO_PERIOD && params.vetoPeriod <= MAX_VETO_PERIOD && params.vetoThreshold != 0
                && params.vetoThreshold <= MAX_VETO_THRESHOLD && params.slashingPercentage != 0
                && params.slashingPercentage <= 1e18
                && params.numParallelProposals <= MAX_PARALLEL_OPTIMISTIC_PROPOSALS,
            InvalidVetoParameters()
        );
        optimisticParams = params;
    }

    // TODO: contract size
    // TODO: deployer for the whole system, must remember to setup OPTIMISTIC_PROPOSER_ROLE on the timelock
    // TODO: Add burn() to StakingVault/StRSR
}
