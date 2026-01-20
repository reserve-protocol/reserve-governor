// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ContextUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";

import { ReserveGovernor } from "./ReserveGovernor.sol";

contract OptimisticProposal is Initializable, ContextUpgradeable {
    using SafeERC20 for IERC20;

    // === Events ===

    event Staked(address indexed staker, uint256 amount);
    event Withdrawn(address indexed staker, uint256 amount);

    // === Enums ===

    enum OptimisticProposalState {
        Active,
        Succeeded,
        Locked,
        Vetoed,
        Slashed,
        Canceled
    }

    // === State ===

    ReserveGovernor public governor;
    address public token;

    uint256 public proposalId;
    address[] public targets;
    uint256[] public values;
    bytes[] public calldatas;
    string public description;

    uint256 public vetoEnd; // {s} inclusive
    uint256 public vetoThreshold; // {tok}
    uint256 public slashingPercentage; // D18{1}

    mapping(address staker => uint256 amount) public staked; // {tok}

    bool public adjudicationStarted;
    bool public canceled;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param _params.vetoPeriod {s} Veto period
    /// @param _params.vetoThreshold D18{1} Fraction of token supply required to lock proposal for adjudication
    /// @param _params.slashingPercentage D18{1} Fraction of staked tokens to be potentially slashed
    function initialize(
        ReserveGovernor.OptimisticGovernanceParams calldata _params,
        uint256 _proposalId,
        address[] memory _targets,
        uint256[] memory _values,
        bytes[] memory _calldatas,
        string memory _description
    ) public initializer {
        require(_params.vetoThreshold <= 1e18, "OptimisticProposal: invalid veto threshold");
        require(_params.slashingPercentage <= 1e18, "OptimisticProposal: invalid slashing percentage");
        
        require(
            _targets.length != 0 && _targets.length == _values.length && _targets.length == _calldatas.length,
            "OptimisticProposal: invalid proposal"
        );

        governor = ReserveGovernor(payable(_msgSender()));
        token = address(governor.token());

        proposalId = _proposalId;
        targets = _targets;
        values = _values;
        calldatas = _calldatas;
        description = _description;

        // {s}
        vetoEnd = block.timestamp + _params.vetoPeriod;

        // {tok}
        uint256 supply = IVotes(address(token)).getPastTotalSupply(governor.clock() - 1);

        // {tok} = D18{1} * {tok} / D18{1}
        vetoThreshold = (_params.vetoThreshold * supply + (1e18 - 1)) / 1e18;
        // CEIL to make sure thresholds near 0% don't get rounded down to 0 tokens

        // D18{1}
        slashingPercentage = _params.slashingPercentage;
    }

    // === View ===

    function state() public view returns (OptimisticProposalState) {
        if (!adjudicationStarted) {
            if (block.timestamp <= vetoEnd)  {
                return OptimisticProposalState.Active;
            } else {
                return OptimisticProposalState.Succeeded;
            }
        }

        IGovernor.ProposalState adjudicationState = governor.state(proposalId);
        
        if (adjudicationState == IGovernor.ProposalState.Defeated) {
            return OptimisticProposalState.Vetoed;
        }
        
        if (adjudicationState == IGovernor.ProposalState.Executed) {
            return OptimisticProposalState.Slashed;
        }

        // TODO: check that when cancellation happens in the timelock, this state gets triggered
        if (canceled || adjudicationState == IGovernor.ProposalState.Canceled || adjudicationState == IGovernor.ProposalState.Expired) {
            return OptimisticProposalState.Canceled;
        }

        return OptimisticProposalState.Locked;
    }

    // === Governor ===

    function cancel() external {
        require(_msgSender() == address(governor), "OptimisticProposal: governor only");
        require(!canceled, "OptimisticProposal: already canceled");
        
        canceled = true;
    }

    // === User ===

    function stake(uint256 amount) external {
        require(state() == OptimisticProposalState.Active, "OptimisticProposal: not active");
        require(amount != 0, "OptimisticProposal: zero stake");

        // {tok}
        staked[_msgSender()] += amount;

        if (IERC20(token).balanceOf(address(this)) + amount >= vetoThreshold) {
            adjudicationStarted = true;

            // initiate adjudication via slow proposal
            governor.propose(targets, values, calldatas, description);
        }

        IERC20(token).safeTransferFrom(_msgSender(), address(this), amount);
        emit Staked(_msgSender(), amount);
    }

    function withdraw() external {
        OptimisticProposalState _state = state();
        require(_state != OptimisticProposalState.Locked, "OptimisticProposal: locked for adjudication");

        // {tok} = {tok} * D18{1}
        uint256 amount = staked[_msgSender()] * (1e18 - _slashingPercentage(state())) / 1e18;
        delete staked[_msgSender()];

        require(amount != 0, "OptimisticProposal: zero withdrawal");

        IERC20(token).safeTransfer(_msgSender(), amount);
        emit Withdrawn(_msgSender(), amount);
    }

    // === Internal ===

    function _slashingPercentage(OptimisticProposalState _state) internal view returns (uint256) {
        return _state == OptimisticProposalState.Slashed ? slashingPercentage : 0;
    }
}
