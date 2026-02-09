// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC5805 } from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
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

import { IReserveOptimisticGovernor } from "../interfaces/IReserveOptimisticGovernor.sol";
import {
    CANCELLER_ROLE,
    MIN_OPTIMISTIC_VETO_DELAY,
    MIN_OPTIMISTIC_VETO_PERIOD,
    OPTIMISTIC_PROPOSER_ROLE
} from "../utils/Constants.sol";
import { OptimisticProposalLib } from "./OptimisticProposalLib.sol";

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

    mapping(uint256 proposalId => OptimisticProposal) private optimisticProposals;

    constructor() {
        _disableInitializers();
    }

    modifier onlyOptimisticProposer() {
        _requireOptimisticProposer(_msgSender());
        _;
    }

    /// @param optimisticGovParams.votingDelay {s} Delay before snapshot for optimistic proposals
    /// @param optimisticGovParams.vetoPeriod {s} Veto period for optimistic proposals
    /// @param optimisticGovParams.vetoThreshold D18{1} Fraction of tok supply required to start confirmation process
    /// @param standardGovParams.votingDelay {s} Delay before snapshot
    /// @param standardGovParams.votingPeriod {s} Voting period
    /// @param standardGovParams.proposalThreshold D18{1} Fraction of tok supply required to propose
    /// @param standardGovParams.voteExtension {s} Time extension for late quorum
    /// @param standardGovParams.quorumNumerator D18{1} Fraction of token supply required to reach quorum
    function initialize(
        OptimisticGovernanceParams calldata optimisticGovParams,
        StandardGovernanceParams calldata standardGovParams,
        address _token,
        address _timelock,
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
        __GovernorTimelockControl_init(TimelockControllerUpgradeable(payable(_timelock)));

        _setOptimisticParams(optimisticGovParams);

        selectorRegistry = OptimisticSelectorRegistry(payable(_selectorRegistry));
    }

    function setOptimisticParams(OptimisticGovernanceParams calldata params) external onlyGovernance {
        _setOptimisticParams(params);
    }

    // === Optimistic flow ===

    function proposeOptimistic(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string calldata description
    ) external onlyOptimisticProposer returns (uint256 proposalId) {
        require(_isValidDescriptionForProposer(msg.sender, description), GovernorRestrictedProposer(msg.sender));

        proposalId = getProposalId(targets, values, calldatas, keccak256(bytes(description)));

        OptimisticProposalLib.createOptimisticProposal(
            proposalId,
            OptimisticProposalLib.ProposalData(targets, values, calldatas, description),
            optimisticProposals[proposalId],
            optimisticParams,
            selectorRegistry
        );
    }

    function castVetoOptimistic(uint256 proposalId, string memory reason) external {
        OptimisticProposal storage optimisticProposal = optimisticProposals[proposalId];

        bool vetoed = OptimisticProposalLib.castVeto(optimisticProposal, reason);

        // trigger confirmation vote if vetoed
        if (vetoed) {
            _propose(
                optimisticProposal.targets,
                optimisticProposal.values,
                optimisticProposal.calldatas,
                optimisticProposal.description,
                optimisticProposal.core.proposer
            );
        }
    }

    /// Execute an optimistic proposal that passed successfully without going through the confirmation process
    function executeOptimistic(uint256 proposalId) external payable onlyOptimisticProposer {
        // mark executed in proposal core (for compatibility with legacy offchain monitoring)
        _getGovernorStorage()._proposals[proposalId].executed = true;

        OptimisticProposalLib.executeOptimisticProposal(optimisticProposals[proposalId]);
    }

    /// @dev If ProposalType.Optimistic, call `stateOptimistic()`
    /// @dev If ProposalType.Standard, call `state()`
    /// @return ProposalType.Optimistic | ProposalType.Standard
    function proposalType(uint256 proposalId) public view returns (ProposalType) {
        if (proposalSnapshot(proposalId) != 0) {
            return ProposalType.Standard;
        }

        require(optimisticProposals[proposalId].core.voteStart != 0, GovernorNonexistentProposal(proposalId));

        return ProposalType.Optimistic;
    }

    function stateOptimistic(uint256 proposalId) public view returns (ProposalState) {
        return OptimisticProposalLib.state(optimisticProposals[proposalId]);
    }

    // === Inheritance overrides ===

    function quorumDenominator() public pure override returns (uint256) {
        return 1e18;
    }

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
        uint256 supply = Math.max(1, token().getPastTotalSupply(clock() - 1));

        // CEIL to make sure thresholds near 0% don't get rounded down to 0 tokens
        return (proposalThresholdRatio * supply + (1e18 - 1)) / 1e18;
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override returns (uint256 proposalId) {
        // ensure no accidental calls to EOAs
        // limitation: cannot log data to EOAs or interact with a contract within its constructor
        for (uint256 i = 0; i < targets.length; i++) {
            require(calldatas[i].length == 0 || targets[i].code.length != 0, InvalidFunctionCallToEOA(targets[i]));
        }

        proposalId = super.propose(targets, values, calldatas, description);

        // ensure no collisions with optimistic proposal
        require(optimisticProposals[proposalId].core.voteStart == 0, ExistingOptimisticProposal(proposalId));
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

    function _setProposalThreshold(uint256 newProposalThreshold) internal override {
        require(newProposalThreshold <= 1e18, InvalidProposalThreshold());
        super._setProposalThreshold(newProposalThreshold);
    }

    // === Private ===

    function _setOptimisticParams(OptimisticGovernanceParams calldata params) private {
        require(
            params.vetoDelay >= MIN_OPTIMISTIC_VETO_DELAY && params.vetoPeriod >= MIN_OPTIMISTIC_VETO_PERIOD
                && params.vetoThreshold != 0 && params.vetoThreshold <= 1e18,
            InvalidOptimisticParameters()
        );
        optimisticParams = params;
    }

    function _requireOptimisticProposer(address account) private view {
        require(
            TimelockControllerOptimistic(payable(timelock())).hasRole(OPTIMISTIC_PROPOSER_ROLE, account),
            NotOptimisticProposer(account)
        );
    }

    /// @dev Upgrades authorized only through timelock
    function _authorizeUpgrade(address) internal override onlyGovernance { }

    function version() public pure virtual override(GovernorUpgradeable, Versioned) returns (string memory) {
        return Versioned.version();
    }
}
