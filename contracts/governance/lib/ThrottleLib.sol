// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IReserveOptimisticGovernor } from "@interfaces/IReserveOptimisticGovernor.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PROPOSAL_THROTTLE_PERIOD } from "@utils/Constants.sol";

library ThrottleLib {
    struct ProposalThrottleStorage {
        uint256 capacity; // max number of proposals per 12h
        mapping(address account => ProposalThrottle) throttles;
    }

    struct ProposalThrottle {
        uint256 currentCharge; // D18{1}
        uint256 lastUpdated; // {s}
    }

    function consumeProposalCharge(ProposalThrottleStorage storage proposalThrottle, address account) external {
        _consumeProposalCharge(proposalThrottle.throttles[account], proposalThrottle.capacity);
    }

    function _consumeProposalCharge(ProposalThrottle storage throttle, uint256 capacity) private {
        capacity = Math.max(capacity, 1);
        (uint256 proposalsAvailable, uint256 charge) = _getProposalsAvailable(throttle, capacity);
        require(proposalsAvailable >= 1, IReserveOptimisticGovernor.OptimisticGovernor__ProposalThrottleExceeded());

        // Acceptable simplifiction to use latest `capacity`
        throttle.currentCharge = charge - (1e18 / capacity);
        throttle.lastUpdated = block.timestamp;
    }

    function getProposalsAvailable(ProposalThrottleStorage storage proposalThrottle, address account)
        external
        view
        returns (uint256 proposalsAvailable)
    {
        (proposalsAvailable,) = _getProposalsAvailable(proposalThrottle.throttles[account], proposalThrottle.capacity);
    }

    // === Private ===

    /// @return proposalsAvailable The number of proposals available for the account
    /// @return charge D18{1} The charge for the account
    function _getProposalsAvailable(ProposalThrottle storage throttle, uint256 capacity)
        private
        view
        returns (uint256 proposalsAvailable, uint256 charge)
    {
        capacity = Math.max(capacity, 1);
        uint256 elapsed = block.timestamp - throttle.lastUpdated;
        charge = throttle.currentCharge + (elapsed * 1e18) / PROPOSAL_THROTTLE_PERIOD;

        if (charge > 1e18) {
            charge = 1e18;
        }

        proposalsAvailable = (capacity * charge) / 1e18;
    }
}
