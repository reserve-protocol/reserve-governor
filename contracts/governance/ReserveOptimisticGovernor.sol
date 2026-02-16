// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC5805 } from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

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
    MAX_OPTIMISTIC_DELAY,
    MAX_PROPOSAL_THROTTLE_CAPACITY,
    MIN_OPTIMISTIC_VETO_DELAY,
    MIN_OPTIMISTIC_VETO_PERIOD,
    OPTIMISTIC_PROPOSER_ROLE
} from "../utils/Constants.sol";
import { Versioned } from "../utils/Versioned.sol";
import { OptimisticSelectorRegistry } from "./OptimisticSelectorRegistry.sol";
import { TimelockControllerOptimistic } from "./TimelockControllerOptimistic.sol";
import { ProposalLib } from "./lib/ProposalLib.sol";
import { ThrottleLib } from "./lib/ThrottleLib.sol";

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

    ThrottleLib.ProposalThrottleStorage private proposalThrottle;

    mapping(uint256 proposalId => OptimisticProposalDetails) private optimisticProposalDetails;

    constructor() {
        _disableInitializers();
    }

    /// @param optimisticGovParams.vetoDelay {s} Delay before snapshot for optimistic proposals
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
        assert(keccak256(bytes(IERC5805(_token).CLOCK_MODE())) == keccak256("mode=timestamp"));

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

    function proposalThrottleCapacity() external view returns (uint256) {
        return proposalThrottle.capacity;
    }

    function quorumDenominator() public pure override returns (uint256) {
        return 1e18;
    }

    function vetoThreshold(uint256 proposalId) public view returns (uint256) {
        return optimisticProposalDetails[proposalId].vetoThreshold;
    }

    function isOptimistic(uint256 proposalId) external view returns (bool) {
        require(_proposalCore(proposalId).voteStart != 0, GovernorNonexistentProposal(proposalId));

        return _isOptimistic(proposalId);
    }

    // === Proposal Creation ===

    /// @dev Only callable by OPTIMISTIC_PROPOSER_ROLE
    function proposeOptimistic(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string calldata description
    ) external returns (uint256 proposalId) {
        address proposer = msg.sender;

        ThrottleLib.consumeProposalCharge(proposalThrottle, proposer);

        proposalId = getProposalId(targets, values, calldatas, keccak256(bytes(description)));

        optimisticProposalDetails[proposalId] = OptimisticProposalDetails({
            targets: targets,
            values: values,
            calldatas: calldatas,
            description: description,
            vetoThreshold: optimisticParams.vetoThreshold
        });

        ProposalLib.proposeOptimistic(
            ProposalLib.ProposalData(proposalId, proposer, targets, values, calldatas, description),
            _proposalCore(proposalId),
            optimisticParams
        );
    }

    /// @dev Permissionless
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override returns (uint256 proposalId) {
        proposalId = getProposalId(targets, values, calldatas, keccak256(bytes(description)));

        ProposalLib.proposePessimistic(
            ProposalLib.ProposalData(proposalId, msg.sender, targets, values, calldatas, description),
            _proposalCore(proposalId)
        );
    }

    // === View Overrides ===

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
        if (_isOptimistic(proposalId)) {
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

            uint256 _vetoThreshold = vetoThreshold(proposalId);

            if (_vetoThreshold == ProposalLib.TRANSITIONED_VETO_THRESHOLD) {
                // special-case for transitioned proposals
                return ProposalState.Defeated;
            }

            // {tok} = D18{1} * {tok} / D18{1}
            uint256 vetoThresholdTok = (_vetoThreshold * token().getPastTotalSupply(snapshot) + (1e18 - 1)) / 1e18;

            if (vetoThresholdTok == 0) {
                return ProposalState.Canceled;
            }

            if (againstVotesCount(proposalId) >= vetoThresholdTok) {
                return ProposalState.Defeated;
            }

            // {s}
            uint256 deadline = proposalCore.voteStart + proposalCore.voteDuration;

            if (deadline >= block.timestamp) {
                return ProposalState.Active;
            }

            return ProposalState.Succeeded;
        }

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
        if (_isOptimistic(proposalId)) {
            return false;
        }

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

    // === Internal Overrides ===

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint48) {
        require(!_isOptimistic(proposalId), OptimisticProposalCannotBeQueued(proposalId));

        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
        if (_isOptimistic(proposalId)) {
            // optimistic case: execute immediately

            _timelock().executeBatchBypass{ value: msg.value }(
                targets, values, calldatas, 0, bytes20(address(this)) ^ descriptionHash
            );
        } else {
            // pessimistic case: execute through timelock

            super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
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
        if (_timelock().hasRole(CANCELLER_ROLE, caller)) {
            return true;
        }

        if (caller != proposalProposer(proposalId)) {
            return false;
        }

        ProposalState s = state(proposalId);

        return (_isOptimistic(proposalId) && s != ProposalState.Defeated) || s == ProposalState.Pending;
    }

    function _tallyUpdated(uint256 proposalId)
        internal
        override(GovernorUpgradeable, GovernorPreventLateQuorumUpgradeable)
    {
        if (!_isOptimistic(proposalId)) {
            // pessimistic case: possibly extend quorum

            return super._tallyUpdated(proposalId);
        }

        OptimisticProposalDetails storage optimisticProposal = optimisticProposalDetails[proposalId];

        if (state(proposalId) == ProposalState.Defeated) {
            // transition optimistic -> pessimistic

            ProposalLib.transitionToPessimistic(proposalId, optimisticProposal, _getGovernorStorage()._proposals);
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

    /// @dev Upgrades authorized only through timelock
    function _authorizeUpgrade(address) internal override onlyGovernance { }

    // === Setters ===

    function _setProposalThreshold(uint256 newProposalThreshold) internal override {
        require(newProposalThreshold != 0 && newProposalThreshold <= 1e18, InvalidProposalThreshold());

        super._setProposalThreshold(newProposalThreshold);
    }

    function _setProposalThrottle(uint256 newCapacity) internal {
        require(newCapacity != 0 && newCapacity <= MAX_PROPOSAL_THROTTLE_CAPACITY, InvalidProposalThrottle());

        proposalThrottle.capacity = newCapacity;
        emit ProposalThrottleUpdated(newCapacity);
    }

    function _setVotingDelay(uint48 newVotingDelay) internal override {
        require(newVotingDelay < MAX_OPTIMISTIC_DELAY, InvalidDelay());
        super._setVotingDelay(newVotingDelay);
    }

    function _setOptimisticParams(OptimisticGovernanceParams calldata params) private {
        require(
            params.vetoDelay >= MIN_OPTIMISTIC_VETO_DELAY && params.vetoDelay < MAX_OPTIMISTIC_DELAY
                && params.vetoPeriod >= MIN_OPTIMISTIC_VETO_PERIOD && params.vetoThreshold != 0
                && params.vetoThreshold <= 1e18,
            InvalidOptimisticParameters()
        );
        optimisticParams = params;
    }

    // === Private ===

    function _isOptimistic(uint256 proposalId) private view returns (bool) {
        return vetoThreshold(proposalId) != 0;
    }

    function _proposalCore(uint256 proposalId) private view returns (ProposalCore storage) {
        return _getGovernorStorage()._proposals[proposalId];
    }

    function _timelock() private view returns (TimelockControllerOptimistic) {
        return TimelockControllerOptimistic(payable(timelock()));
    }

    // === Version ===

    function version() public pure virtual override(GovernorUpgradeable, Versioned) returns (string memory) {
        return Versioned.version();
    }
}
