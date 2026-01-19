// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ContextUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

import { ReserveGovernor } from "./ReserveGovernor.sol";

contract OptimisticProposal is Initializable, ContextUpgradeable {
    using SafeERC20 for IERC20;

    // === Events ===

    event Staked(address indexed staker, uint256 amount);
    event Withdrawn(address indexed staker, uint256 amount);
    event Locked();
    event Slashed(uint256 slashingPercentage);
    event Canceled();

    // === Enums ===

    enum ProposalState {
        Pending,
        Succeeded,
        Locked,
        Slashed,
        Canceled
    }

    // === State ===

    ProposalState private _state;

    ReserveGovernor public owner;
    IERC20 public token;

    struct Proposal {
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
    }

    Proposal public proposal;

    uint256 public vetoEnd; // {s} inclusive
    uint256 public vetoThreshold; // {tok}
    uint256 public slashingPercentage; // D18{1}

    mapping(address staker => uint256 amount) public staked; // {tok}
    uint256 public slashing; // D18{1}

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param _vetoEnd {s} Veto end time
    /// @param _vetoThreshold {tok}
    /// @param _slashingPercentage D18{1}
    function initialize(
        Proposal calldata _proposal,
        uint256 _vetoEnd,
        uint256 _vetoThreshold,
        uint256 _slashingPercentage,
        address _token
    ) public initializer {
        require(
            _proposal.targets.length != 0 && _proposal.targets.length == _proposal.values.length && _proposal.targets.length == _proposal.calldatas.length,
            "OptimisticProposal: invalid proposal"
        );
        require(_slashingPercentage <= 1e18, "OptimisticProposal: invalid slashing percentage");

        owner = ReserveGovernor(payable(_msgSender()));
        proposal = _proposal;
        vetoEnd = _vetoEnd;
        vetoThreshold = _vetoThreshold;
        slashingPercentage = _slashingPercentage;
        token = IERC20(_token);
    }

    modifier onlyOwner() {
        require(_msgSender() == address(owner), "OptimisticProposal: not owner");
        _;
    }

    function state() public view returns (ProposalState) {
        if (_state == ProposalState.Pending && block.timestamp > vetoEnd) {
            return ProposalState.Succeeded;
        }
        return _state;
    }

    // === Owner ===

    function slash() public onlyOwner {
        require(state() == ProposalState.Locked, "OptimisticProposal: not locked");
        _state = ProposalState.Slashed;

        slashing = slashingPercentage;
        emit Slashed(slashingPercentage);
    }

    function cancel() public onlyOwner {
        require(state() != ProposalState.Slashed, "OptimisticProposal: already slashed");
        _state = ProposalState.Canceled;

        emit Canceled();
    }

    // === User ===

    function stake(uint256 amount) external {
        require(state() == ProposalState.Pending, "OptimisticProposal: not pending");
        require(amount != 0, "OptimisticProposal: zero stake");

        // {tok}
        staked[_msgSender()] += amount;

        if (token.balanceOf(address(this)) + amount >= vetoThreshold) {
            _state = ProposalState.Locked;
            emit Locked();

            // initiate adjudication via slow proposal
            owner.propose(proposal.targets, proposal.values, proposal.calldatas, proposal.description);
        }

        token.safeTransferFrom(_msgSender(), address(this), amount);
        emit Staked(_msgSender(), amount);
    }

    function withdraw() external {
        require(state() != ProposalState.Locked, "OptimisticProposal: not locked");

        // {tok} = {tok} * D18{1}
        uint256 amount = staked[_msgSender()] * (1e18 - slashing) / 1e18;
        delete staked[_msgSender()];

        require(amount != 0, "OptimisticProposal: zero withdrawal");

        token.safeTransfer(_msgSender(), amount);
        emit Withdrawn(_msgSender(), amount);
    }
}
