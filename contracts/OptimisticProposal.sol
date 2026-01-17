// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ContextUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

contract OptimisticProposal is Initializable, ContextUpgradeable {
    using SafeERC20 for IERC20;

    // TODO events

    enum ProposalState {
        Pending,
        Succeeded,
        Adjudicating,
        Slashed,
        Canceled
    }

    address public owner;
    IERC20 public token;

    bool public locked;
    bool public slashed;
    bool public canceled;

    uint256 public vetoEnd; // {s} inclusive
    uint256 public vetoThreshold; // {tok}
    uint256 public slashingPercentage; // D18{1}

    mapping(address staker => uint256 amount) public staked;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param _vetoEnd {s} Veto end time
    /// @param _vetoThreshold {tok}
    /// @param _slashingPercentage D18{1}
    function initialize(uint256 _vetoEnd, uint256 _vetoThreshold, uint256 _slashingPercentage, address _token)
        public
        initializer
    {
        require(_slashingPercentage <= 1e18, "OptimisticProposal: invalid slashing percentage");

        owner = _msgSender();
        vetoEnd = _vetoEnd;
        vetoThreshold = _vetoThreshold;
        slashingPercentage = _slashingPercentage;
        token = IERC20(_token);
    }

    modifier onlyOwner() {
        require(_msgSender() == owner, "OptimisticProposal: not owner");
        _;
    }

    function succeeded() public view returns (bool) {
        return block.timestamp > vetoEnd && !locked && !canceled && !slashed;
    }

    // === Owner ===

    function slash() public onlyOwner {
        require(locked && !slashed && !canceled, "OptimisticProposal: already slashed");

        locked = false;
        slashed = true;
        // canceled = false;
    }

    function cancel() public onlyOwner {
        require(!slashed && !canceled, "OptimisticProposal: already canceled");

        locked = false;
        // slashed = false;
        canceled = true;
    }

    // === User ===

    function stake(uint256 amount) external {
        require(block.timestamp <= vetoEnd && !locked && !slashed && !canceled, "OptimisticProposal: cannot stake");

        staked[_msgSender()] += amount;

        token.safeTransferFrom(_msgSender(), address(this), amount);

        if (token.balanceOf(address(this)) >= vetoThreshold) {
            locked = true;
        }
    }

    function withdraw() external {
        require(!locked, "OptimisticProposal: cannot withdraw");

        uint256 amount = staked[_msgSender()];
        delete staked[_msgSender()];

        if (slashed) {
            amount *= (1e18 - slashingPercentage) / 1e18;
        }

        token.safeTransfer(_msgSender(), amount);
    }
}
