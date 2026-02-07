// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ContextUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

import { IReserveOptimisticGovernor } from "../interfaces/IReserveOptimisticGovernor.sol";
import { IStakingVault } from "../interfaces/IStakingVault.sol";
import { CANCELLER_ROLE } from "../utils/Constants.sol";

import { ReserveOptimisticGovernor } from "./ReserveOptimisticGovernor.sol";
import { TimelockControllerOptimistic } from "./TimelockControllerOptimistic.sol";

/**
 * @title OptimisticProposal
 *
 * @dev Not compatible with rebasing tokens
 *      Do NOT send tokens to this contract directly, call `stake()` instead
 *      Token supply should be less than 1e59
 */
contract OptimisticProposal is Initializable, ContextUpgradeable {
    using SafeERC20 for IStakingVault;

    // === Events ===

    event Initialized(
        address indexed governor,
        address indexed proposer,
        uint256 indexed proposalId,
        address token,
        uint48 voteEnd,
        uint256 vetoThreshold,
        uint256 slashingPercentage
    );
    event Staked(address indexed staker, uint256 amount);
    event Withdrawn(address indexed staker, uint256 amount);
    event Slashed(uint256 amount);
    event Canceled();

    // === Errors ===

    error OptimisticProposal__CannotCancel();
    error OptimisticProposal__NotActive();
    error OptimisticProposal__ZeroStake();
    error OptimisticProposal__ZeroWithdrawal();
    error OptimisticProposal__NotGovernor();
    error OptimisticProposal__NotSlashed();
    error OptimisticProposal__UnderConfirmation();

    // === Enums ===

    enum OptimisticProposalState {
        Active,
        Succeeded,
        Locked,
        Vetoed,
        Slashed,
        Canceled,
        Executed
    }

    // === State ===

    ReserveOptimisticGovernor public governor;
    IStakingVault public token;

    address public proposer;
    uint256 public proposalId;
    address[] public targets;
    uint256[] public values;
    bytes[] public calldatas;
    string public description;

    uint48 public voteEnd; // {s} inclusive
    uint256 public vetoThreshold; // {tok}
    uint256 public slashingPercentage; // D18{1}

    mapping(address staker => uint256 amount) public staked; // {tok}
    uint256 public totalStaked; // {tok}

    bool public canceled;

    constructor() {
        _disableInitializers();
    }

    /// @param _params.vetoPeriod {s} Veto period
    /// @param _params.vetoThreshold D18{1} Fraction of token supply required to lock proposal for confirmation
    /// @param _params.slashingPercentage D18{1} Fraction of staked tokens to be potentially slashed
    function initialize(
        IReserveOptimisticGovernor.OptimisticGovernanceParams calldata _params,
        uint256 _proposalId,
        address _proposer,
        address[] memory _targets,
        uint256[] memory _values,
        bytes[] memory _calldatas,
        string memory _description
    ) public initializer {
        __Context_init();

        governor = ReserveOptimisticGovernor(payable(_msgSender()));
        token = IStakingVault(address(governor.token()));

        proposer = _proposer;
        proposalId = _proposalId;
        targets = _targets;
        values = _values;
        calldatas = _calldatas;
        description = _description;

        // {s}
        voteEnd = uint48(block.timestamp + _params.vetoPeriod);

        // {tok}
        uint256 supply = IStakingVault(address(token)).getPastTotalSupply(governor.clock() - 1);

        // {tok} = D18{1} * {tok} / D18{1}
        vetoThreshold = (_params.vetoThreshold * supply + (1e18 - 1)) / 1e18;
        // CEIL to make sure thresholds near 0% don't get rounded down to 0 tokens

        // D18{1}
        slashingPercentage = _params.slashingPercentage;

        emit Initialized(
            address(governor), _proposer, _proposalId, address(token), voteEnd, vetoThreshold, slashingPercentage
        );
    }

    // === View ===

    function state() public view returns (OptimisticProposalState) {
        if (canceled) {
            return OptimisticProposalState.Canceled;
        }

        try governor.state(proposalId) returns (IGovernor.ProposalState governorState) {
            IReserveOptimisticGovernor.ProposalType proposalType = governor.proposalType(proposalId);

            if (proposalType == IReserveOptimisticGovernor.ProposalType.Optimistic) {
                // Proposal executed without confirmation

                return OptimisticProposalState.Executed;
            } else {
                // Proposal under confirmation

                if (
                    governorState == IGovernor.ProposalState.Defeated
                        || governorState == IGovernor.ProposalState.Expired
                ) {
                    return OptimisticProposalState.Vetoed;
                }

                if (governorState == IGovernor.ProposalState.Executed) {
                    return OptimisticProposalState.Slashed;
                }

                if (governorState == IGovernor.ProposalState.Canceled) {
                    return OptimisticProposalState.Canceled;
                }

                return OptimisticProposalState.Locked;
            }
        } catch {
            // Proposal not under confirmation nor executed

            if (block.timestamp > voteEnd) {
                return OptimisticProposalState.Succeeded;
            }

            return OptimisticProposalState.Active;
        }
    }

    function proposalData()
        external
        view
        returns (
            address[] memory _targets,
            uint256[] memory _values,
            bytes[] memory _calldatas,
            string memory _description
        )
    {
        return (targets, values, calldatas, description);
    }

    // === Admin ===

    /// Cancel an optimistic proposal WITHOUT a corresponding confirmation proposal
    /// Caller must have CANCELLER_ROLE
    function cancel() external {
        TimelockControllerOptimistic timelock = TimelockControllerOptimistic(payable(governor.timelock()));

        require(
            timelock.hasRole(CANCELLER_ROLE, _msgSender()) || _msgSender() == proposer,
            OptimisticProposal__CannotCancel()
        );

        OptimisticProposalState _state = state();

        require(
            _state == OptimisticProposalState.Active || _state == OptimisticProposalState.Succeeded,
            OptimisticProposal__CannotCancel()
        );

        canceled = true;
        emit Canceled();
    }

    // === User ===

    /// @dev Can stake less than `maxAmount` if there is excess
    function stakeToVeto(uint256 maxAmount) external {
        require(state() == OptimisticProposalState.Active, OptimisticProposal__NotActive());

        // cap amount at remaining needed
        uint256 remaining = vetoThreshold - totalStaked;
        uint256 amount = remaining < maxAmount ? remaining : maxAmount;

        require(amount != 0, OptimisticProposal__ZeroStake());

        // {tok}
        staked[_msgSender()] += amount;
        totalStaked += amount;

        if (totalStaked == vetoThreshold) {
            // initiate confirmation process via slow proposal
            governor.proposeConfirmation(targets, values, calldatas, description, proposer, totalStaked);
        }

        token.safeTransferFrom(_msgSender(), address(this), amount);
        emit Staked(_msgSender(), amount);
    }

    function withdraw() external {
        OptimisticProposalState _state = state();
        require(_state != OptimisticProposalState.Locked, OptimisticProposal__UnderConfirmation());

        // can leave dust behind equal to total number of deposits
        // {tok} = {tok} * D18{1}
        uint256 amount = staked[_msgSender()] * (1e18 - _slashingPercentage(_state)) / 1e18;
        delete staked[_msgSender()];
        // totalStaked unchanged

        require(amount != 0, OptimisticProposal__ZeroWithdrawal());

        token.safeTransfer(_msgSender(), amount);
        emit Withdrawn(_msgSender(), amount);
    }

    // === Governor ===

    function slash() external {
        require(_msgSender() == address(governor), OptimisticProposal__NotGovernor());
        require(state() == OptimisticProposalState.Slashed, OptimisticProposal__NotSlashed());

        // {tok} = {tok} * D18{1}
        uint256 amount = (totalStaked * _slashingPercentage(state())) / 1e18;
        totalStaked = 0;

        token.burn(amount);
        emit Slashed(amount);
    }

    // === Internal ===

    function _slashingPercentage(OptimisticProposalState _state) internal view returns (uint256) {
        return _state == OptimisticProposalState.Slashed ? slashingPercentage : 0;
    }
}
