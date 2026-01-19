// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

import { GovernorUpgradeable } from "./vendor/GovernorUpgradeable.sol";
import { GovernorCountingSimpleUpgradeable } from "./vendor/GovernorCountingSimpleUpgradeable.sol";
import { GovernorPreventLateQuorumUpgradeable } from "./vendor/GovernorPreventLateQuorumUpgradeable.sol";
import { GovernorSettingsUpgradeable } from "./vendor/GovernorSettingsUpgradeable.sol";
import { GovernorTimelockControlUpgradeable } from "./vendor/GovernorTimelockControlUpgradeable.sol";
import { GovernorVotesQuorumFractionUpgradeable } from "./vendor/GovernorVotesQuorumFractionUpgradeable.sol";
import { GovernorVotesUpgradeable } from "./vendor/GovernorVotesUpgradeable.sol";

import { IReserveGovernor } from "./IReserveGovernor.sol";
import { OptimisticProposal } from "./OptimisticProposal.sol";
import { TimelockControllerBypassable } from "./TimelockControllerBypassable.sol";

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

    uint256 public vetoPeriod; // {s}
    uint256 public vetoThreshold; // D18{1}
    uint256 public slashingPercentage; // D18{1}

    mapping(address role => bool) public isOptimisticProposer; // TODO move to Timelock?

    mapping(uint256 proposalId => OptimisticProposal) public optimisticProposals;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();

        optimisticProposalImpl = new OptimisticProposal();
    }

    /// @param optimisticParams.vetoPeriod {s} Veto period
    /// @param optimisticParams.vetoThreshold D18{1} Fraction of vlToken supply required to start veto adjudication
    /// @param standardParams.votingDelay {s} Delay before snapshot
    /// @param standardParams.votingPeriod {s} Voting period
    /// @param standardParams.proposalThreshold D18{1} Fraction of vlToken supply required to propose
    /// @param standardParams.voteExtension {s} Time extension for late quorum
    /// @param standardParams.quorumNumerator 0-100
    function initialize(
        OptimisticGovernanceParams calldata optimisticParams,
        StandardGovernanceParams calldata standardParams,
        IVotes _token,
        address _timelock
    ) public initializer {
        require(optimisticParams.vetoPeriod != 0 && optimisticParams.vetoThreshold != 0, InvalidVetoParameters());

        __Governor_init("Reserve Governor");
        __GovernorSettings_init(
            standardParams.votingDelay, standardParams.votingPeriod, standardParams.proposalThreshold
        );
        __GovernorPreventLateQuorum_init(standardParams.voteExtension);
        __GovernorCountingSimple_init();
        __GovernorVotes_init(_token);
        __GovernorVotesQuorumFraction_init(standardParams.quorumNumerator);
        __GovernorTimelockControl_init(TimelockControllerUpgradeable(payable(_timelock)));

        for (uint256 i = 0; i < optimisticParams.optimisticProposers.length; i++) {
            isOptimisticProposer[optimisticParams.optimisticProposers[i]] = true;
        }
        vetoPeriod = optimisticParams.vetoPeriod;
        vetoThreshold = optimisticParams.vetoThreshold;
        slashingPercentage = optimisticParams.slashingPercentage;
    }

    // === Optimistic proposer ===

    modifier onlyOptimisticProposer() {
        require(isOptimisticProposer[_msgSender()], NotOptimisticProposer(_msgSender()));
        _;
    }

    function grantOptimisticProposer(address account) public onlyGovernance {
        isOptimisticProposer[account] = true;
        emit OptimisticProposerGranted(account);
    }

    function revokeOptimisticProposer(address account) public onlyGovernance {
        isOptimisticProposer[account] = false;
        emit OptimisticProposerRevoked(account);
    }

    // === Optimistic flow ===

    /// @return proposalId The ID of the proposed optimistic proposal
    function proposeOptimistic(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string calldata description
    ) public onlyOptimisticProposer returns (uint256 proposalId) {
        proposalId = getProposalId(targets, values, calldatas, keccak256(bytes(description)));

        require(
            targets.length == values.length && targets.length == calldatas.length && targets.length == 0,
            GovernorInvalidProposalLength(targets.length, calldatas.length, values.length)
        );
        require(address(optimisticProposals[proposalId]) == address(0), ExistingOptimisticProposal(proposalId));

        uint256 vetoEnd = block.timestamp + vetoPeriod;

        // {vlToken}
        uint256 supply = token().getPastTotalSupply(clock() - 1);

        // {vlToken}
        uint256 vetoThresholdAmt = (vetoThreshold * supply + (1e18 - 1)) / 1e18;
        // CEIL to make sure thresholds near 0% don't get rounded down to 0 tokens

        OptimisticProposal optimisticProposal = OptimisticProposal(address(optimisticProposalImpl).clone());
        optimisticProposals[proposalId] = optimisticProposal;
        optimisticProposal.initialize(vetoEnd, vetoThresholdAmt, slashingPercentage, address(token()));

        emit OptimisticProposalCreated(proposalId, targets, values, calldatas, vetoEnd, description);
    }

    /// Execute an optimistic proposal that has passed through
    function executeOptimistic(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) public payable onlyOptimisticProposer {
        uint256 proposalId = getProposalId(targets, values, calldatas, descriptionHash);

        OptimisticProposal optimisticProposal = optimisticProposals[proposalId];
        require(optimisticProposal.state() == OptimisticProposal.ProposalState.Succeeded, ProposalNotReady(proposalId));

        TimelockControllerBypassable(payable(timelock())).executeBatchBypass{ value: msg.value }(
            targets, values, calldatas, 0, bytes20(address(this)) ^ descriptionHash
        );
        // salt mirrors GovernorTimelockControlUpgradeable._timelockSalt()
    }

    /// Allow any optimistic proposer or timelock canceller to cancel an optimistic proposal
    function cancelOptimistic(uint256 proposalId) public {
        TimelockControllerBypassable timelockController = TimelockControllerBypassable(payable(timelock()));

        require(
            isOptimisticProposer[_msgSender()]
                || timelockController.hasRole(timelockController.CANCELLER_ROLE(), _msgSender()),
            NotAuthorizedToCancel(_msgSender())
        );

        OptimisticProposal optimisticProposal = optimisticProposals[proposalId];
        optimisticProposal.cancel(); // reverts if already slashed

        emit OptimisticProposalCanceled(proposalId);
    }

    // === Inheritance overrides ===

    function state(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        // TODO map OptimisticProposal state to ProposalState

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

    /// @return {vlToken} The number of votes required in order for a voter to become a proposer
    function proposalThreshold()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        uint256 proposalThresholdRatio = super.proposalThreshold(); // D18{1}

        // {vlToken}
        uint256 supply = token().getPastTotalSupply(clock() - 1);

        // CEIL to make sure thresholds near 0% don't get rounded down to 0 tokens
        return (proposalThresholdRatio * supply + (1e18 - 1)) / 1e18;
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

        // cancel if has an accompanying optimistic proposal
        if (address(optimisticProposals[proposalId]) != address(0)) {
            optimisticProposals[proposalId].cancel();
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

    function _tallyUpdated(uint256 proposalId)
        internal
        override(GovernorUpgradeable, GovernorPreventLateQuorumUpgradeable)
    {
        super._tallyUpdated(proposalId);
    }

    // TODO: Have OptimisticProposal call back into ReserveGovernor to start a slow proposal
    //      - Think through how to handle duplicate proposals
    // TODO: Call OptimisticProposal.slash() when proposal passes
    // TODO: setters for vetoPeriod, vetoThreshold, slashingPercentage
}
