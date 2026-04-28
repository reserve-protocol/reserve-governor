// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IReserveOptimisticGovernor } from "@interfaces/IReserveOptimisticGovernor.sol";
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
        (uint256 proposalsAvailable, uint256 charge) = _getProposalsAvailable(proposalThrottle, account);
        require(proposalsAvailable >= 1, IReserveOptimisticGovernor.OptimisticGovernor__ProposalThrottleExceeded());

        ProposalThrottle storage throttle = proposalThrottle.throttles[account];

        // Acceptable simplifiction to use latest `capacity`
        throttle.currentCharge = charge - (1e18 / proposalThrottle.capacity);
        throttle.lastUpdated = block.timestamp;
    }

    function getProposalsAvailable(ProposalThrottleStorage storage proposalThrottle, address account)
        external
        view
        returns (uint256 proposalsAvailable)
    {
        (proposalsAvailable,) = _getProposalsAvailable(proposalThrottle, account);
    }

    // === Private ===

    /// @return proposalsAvailable The number of proposals available for the account
    /// @return charge D18{1} The charge for the account
    function _getProposalsAvailable(ProposalThrottleStorage storage proposalThrottle, address account)
        private
        view
        returns (uint256 proposalsAvailable, uint256 charge)
    {
        ProposalThrottle storage throttle = proposalThrottle.throttles[account];

        uint256 elapsed = block.timestamp - throttle.lastUpdated;
        charge = throttle.currentCharge + (elapsed * 1e18) / PROPOSAL_THROTTLE_PERIOD;

        if (charge > 1e18) {
            charge = 1e18;
        }

        proposalsAvailable = (proposalThrottle.capacity * charge) / 1e18;
    }
}
