// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC5805 } from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

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
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IReserveOptimisticGovernor } from "../interfaces/IReserveOptimisticGovernor.sol";
import {
    CANCELLER_ROLE,
    MAX_PROPOSAL_THROTTLE_CAPACITY,
    MIN_OPTIMISTIC_VETO_DELAY,
    MIN_OPTIMISTIC_VETO_PERIOD,
    OPTIMISTIC_PROPOSER_ROLE,
    PROPOSAL_THROTTLE_PERIOD
} from "../utils/Constants.sol";
import { ProposalValidationLib } from "./ProposalValidationLib.sol";

import { Versioned } from "../utils/Versioned.sol";
import { OptimisticSelectorRegistry } from "./OptimisticSelectorRegistry.sol";
import { TimelockControllerOptimistic } from "./TimelockControllerOptimistic.sol";

/**
 * @title Reserve Optimistic Governor
 * @notice A hybrid optimistic/pessimistic governor for the Reserve protocol
 *
 * @dev 3 overall components:
 *    1. ReserveGovernor: Hybrid governor that unifies proposalIds for optimistic/pessimistic flows
 *    2. OptimisticSelectorRegistry: Registry of allowed selectors for optimistic proposals
 *    3. TimelockControllerOptimistic: Single timelock that executes everything, with bypass for optimistic case
 */
contract ReserveOptimisticGovernor is
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorPreventLateQuorumUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    GovernorVotesQuorumFractionUpgradeable,
    GovernorTimelockControlUpgradeable,
    Versioned,
    UUPSUpgradeable,
    IReserveOptimisticGovernor
{
    OptimisticGovernanceParams public optimisticParams;

    OptimisticSelectorRegistry public selectorRegistry;

    ProposalThrottleStorage private proposalThrottle;

    mapping(uint256 proposalId => uint256 vetoThreshold) public vetoThresholds; // D18{1}

    constructor() {
        _disableInitializers();
    }

    /// @param optimisticGovParams.votingDelay {s} Delay before snapshot for optimistic proposals
    /// @param optimisticGovParams.vetoPeriod {s} Veto period for optimistic proposals
    /// @param optimisticGovParams.vetoThreshold D18{1} Fraction of tok supply required to start confirmation process
    /// @param standardGovParams.votingDelay {s} Delay before snapshot
    /// @param standardGovParams.votingPeriod {s} Voting period
    /// @param standardGovParams.proposalThreshold D18{1} Fraction of tok supply required to propose
    /// @param standardGovParams.voteExtension {s} Time extension for late quorum
    /// @param standardGovParams.quorumNumerator D18{1} Fraction of token supply required to reach quorum
    /// @param standardGovParams.proposalThrottleCapacity Proposals-per-account per 24h
    function initialize(
        OptimisticGovernanceParams calldata optimisticGovParams,
        StandardGovernanceParams calldata standardGovParams,
        address _token,
        address _timelockController,
        address _selectorRegistry
    ) public initializer {
        __Governor_init("Reserve Optimistic Governor");
        __GovernorSettings_init(
            standardGovParams.votingDelay, standardGovParams.votingPeriod, standardGovParams.proposalThreshold
        );
        __GovernorPreventLateQuorum_init(standardGovParams.voteExtension);
        __GovernorCountingSimple_init();
        __GovernorVotes_init(IERC5805(_token));
        __GovernorVotesQuorumFraction_init(standardGovParams.quorumNumerator);
        __GovernorTimelockControl_init(TimelockControllerUpgradeable(payable(_timelockController)));
        __UUPSUpgradeable_init();

        _setOptimisticParams(optimisticGovParams);
        _setProposalThrottle(standardGovParams.proposalThrottleCapacity);

        selectorRegistry = OptimisticSelectorRegistry(payable(_selectorRegistry));
    }

    function setOptimisticParams(OptimisticGovernanceParams calldata params) external onlyGovernance {
        _setOptimisticParams(params);
    }

    function setProposalThrottle(uint256 newProposalThrottleCapacity) external onlyGovernance {
        _setProposalThrottle(newProposalThrottleCapacity);
    }

    function getProposalThrottleCapacity() external view returns (uint256) {
        return proposalThrottle.capacity;
    }

    // === Optimistic flow ===

    /// @dev Only callable by OPTIMISTIC_PROPOSER_ROLE
    function proposeOptimistic(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string calldata description
    ) external returns (uint256 proposalId) {
        require(_timelock().hasRole(OPTIMISTIC_PROPOSER_ROLE, msg.sender), NotOptimisticProposer(msg.sender));

        require(_isValidDescriptionForProposer(msg.sender, description), GovernorRestrictedProposer(msg.sender));

        _consumeProposalCharge(msg.sender);

        proposalId = getProposalId(targets, values, calldatas, keccak256(bytes(description)));

        vetoThresholds[proposalId] = optimisticParams.vetoThreshold;

        _propose(targets, values, calldatas, description, msg.sender);
    }

    function proposalType(uint256 proposalId) public view returns (ProposalType) {
        require(_proposalCore(proposalId).voteStart != 0, GovernorNonexistentProposal(proposalId));

        return vetoThresholds[proposalId] != 0 ? ProposalType.Optimistic : ProposalType.Standard;
    }

    // === Inheritance overrides ===

    function quorumDenominator() public pure override returns (uint256) {
        return 1e18;
    }

    function quorum(uint256 timepoint)
        public
        view
        override(GovernorUpgradeable, GovernorVotesQuorumFractionUpgradeable)
        returns (uint256)
    {
        return Math.max(1, super.quorum(timepoint));
    }

    /// @dev Call proposalType() to determine whether to call `state()` or `optimisticProposal.state()`
    function state(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        uint256 vetoThreshold = vetoThresholds[proposalId];

        if (vetoThreshold == 0) {
            // pessimistic case

            return super.state(proposalId);
        } else {
            // optimistic case

            ProposalCore storage proposalCore = _proposalCore(proposalId);

            if (proposalCore.executed) {
                return ProposalState.Executed;
            }

            if (proposalCore.canceled) {
                return ProposalState.Canceled;
            }

            uint256 snapshot = proposalCore.voteStart;

            if (snapshot >= block.timestamp) {
                return ProposalState.Pending;
            }

            // {tok} = D18{1} * {tok} / D18{1}
            uint256 vetoThresholdTok = (vetoThreshold * token().getPastTotalSupply(snapshot) + (1e18 - 1)) / 1e18;

            if (vetoThresholdTok == 0) {
                return ProposalState.Canceled;
            }

            if (_proposalVote(proposalId).againstVotes >= vetoThresholdTok) {
                return ProposalState.Defeated;
            }

            // {s}
            uint256 deadline = proposalCore.voteStart + proposalCore.voteDuration;

            if (deadline >= block.timestamp) {
                return ProposalState.Active;
            }

            return ProposalState.Succeeded;
        }
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
        uint256 supply = Math.max(1, token().getPastTotalSupply(block.timestamp - 1));

        // CEIL to make sure thresholds near 0% don't get rounded down to 0 tokens
        return (proposalThresholdRatio * supply + (1e18 - 1)) / 1e18;
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override returns (uint256) {
        _consumeProposalCharge(msg.sender);

        return super.propose(targets, values, calldatas, description);
    }

    function _propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        address proposer
    ) internal override returns (uint256 proposalId) {
        proposalId = getProposalId(targets, values, calldatas, keccak256(bytes(description)));

        bool isOptimistic = vetoThresholds[proposalId] != 0;

        ProposalValidationLib.validateProposal(isOptimistic, targets, values, calldatas, selectorRegistry);

        ProposalCore storage proposalCore = _proposalCore(proposalId);

        if (proposalCore.voteStart != 0) {
            revert GovernorUnexpectedProposalState(proposalId, state(proposalId), bytes32(0));
        }

        uint256 snapshot;
        uint256 duration;
        {
            if (isOptimistic) {
                snapshot = block.timestamp + optimisticParams.vetoDelay;
                duration = optimisticParams.vetoPeriod;

                emit OptimisticProposalCreated(proposalId, vetoThresholds[proposalId]);
            } else {
                snapshot = block.timestamp + votingDelay();
                duration = votingPeriod();
            }
        }

        emit ProposalCreated(
            proposalId,
            proposer,
            targets,
            values,
            new string[](targets.length),
            calldatas,
            snapshot,
            snapshot + duration,
            description
        );

        proposalCore.proposer = proposer;
        proposalCore.voteStart = SafeCast.toUint48(snapshot);
        proposalCore.voteDuration = SafeCast.toUint32(duration);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint48) {
        require(vetoThresholds[proposalId] == 0, OptimisticProposalCannotBeQueued(proposalId));

        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
        if (vetoThresholds[proposalId] == 0) {
            // pessimistic case: execute through timelock

            super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
        } else {
            // optimistic case: execute immediately

            _timelock().executeBatchBypass{ value: msg.value }(
                targets, values, calldatas, 0, bytes20(address(this)) ^ descriptionHash
            );
        }
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _validateCancel(uint256 proposalId, address caller) internal view override returns (bool) {
        return caller == proposalProposer(proposalId) || _timelock().hasRole(CANCELLER_ROLE, caller);
    }

    function _tallyUpdated(uint256 proposalId)
        internal
        override(GovernorUpgradeable, GovernorPreventLateQuorumUpgradeable)
    {
        if (vetoThresholds[proposalId] == 0) {
            // pessimistic case: possibly extend quorum

            super._tallyUpdated(proposalId);
        } else if (state(proposalId) == ProposalState.Defeated) {
            // optimistic -> pessimistic transition

            vetoThresholds[proposalId] = 0;

            uint256 voteEnd = block.timestamp + votingPeriod();
            emit ConfirmationVoteScheduled(proposalId, block.timestamp, voteEnd);

            ProposalCore storage proposalCore = _proposalCore(proposalId);
            proposalCore.voteDuration = SafeCast.toUint32(voteEnd - proposalCore.voteStart);
        }
    }

    function _executor()
        internal
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        return super._executor();
    }

    function _setProposalThreshold(uint256 newProposalThreshold) internal override {
        require(newProposalThreshold <= 1e18, InvalidProposalThreshold());

        super._setProposalThreshold(newProposalThreshold);
    }

    /// @dev Upgrades authorized only through timelock
    function _authorizeUpgrade(address) internal override onlyGovernance { }

    // === Private ===

    function _consumeProposalCharge(address account) private {
        ProposalThrottle storage throttle = proposalThrottle.throttles[account];

        uint256 elapsed = block.timestamp - throttle.lastUpdated;
        uint256 charge = throttle.currentCharge + (elapsed * 1e18) / PROPOSAL_THROTTLE_PERIOD;

        if (charge > 1e18) {
            charge = 1e18;
        }

        uint256 proposalsAvailable = (proposalThrottle.capacity * charge) / 1e18;
        require(proposalsAvailable >= 1, ProposalThrottleExceeded());

        throttle.currentCharge = charge - (1e18 / proposalThrottle.capacity);
        throttle.lastUpdated = block.timestamp;
    }

    function _setProposalThrottle(uint256 newCapacity) private {
        require(newCapacity != 0 && newCapacity <= MAX_PROPOSAL_THROTTLE_CAPACITY, InvalidProposalThrottle());

        proposalThrottle.capacity = newCapacity;
        emit ProposalThrottleUpdated(newCapacity);
    }

    function _setOptimisticParams(OptimisticGovernanceParams calldata params) private {
        require(
            params.vetoDelay >= MIN_OPTIMISTIC_VETO_DELAY && params.vetoPeriod >= MIN_OPTIMISTIC_VETO_PERIOD
                && params.vetoThreshold != 0 && params.vetoThreshold <= 1e18,
            InvalidOptimisticParameters()
        );
        optimisticParams = params;
    }

    function _setVotingPeriod(uint32 newVotingPeriod) internal override {
        // voting periods near uint32.max can overflow in _tallyUpdated()
        require(newVotingPeriod < type(uint32).max / 2, InvalidVotingPeriod());

        super._setVotingPeriod(newVotingPeriod);
    }

    function _proposalCore(uint256 proposalId) private view returns (ProposalCore storage) {
        return _getGovernorStorage()._proposals[proposalId];
    }

    function _proposalVote(uint256 proposalId) private view returns (ProposalVote storage) {
        return _getGovernorCountingSimpleStorage()._proposalVotes[proposalId];
    }

    function _timelock() private view returns (TimelockControllerOptimistic) {
        return TimelockControllerOptimistic(payable(timelock()));
    }

    // === Version ===

    function version() public pure virtual override(GovernorUpgradeable, Versioned) returns (string memory) {
        return Versioned.version();
    }
}
