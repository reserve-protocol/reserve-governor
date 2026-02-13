// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IReserveOptimisticGovernor } from "../../interfaces/IReserveOptimisticGovernor.sol";

library ThrottleLib {
    uint256 constant PROPOSAL_THROTTLE_PERIOD = 1 days;

    struct ProposalThrottleStorage {
        uint256 capacity; // max number of proposals per 24h
        mapping(address account => ProposalThrottle) throttles;
    }

    struct ProposalThrottle {
        uint256 currentCharge; // D18{1}
        uint256 lastUpdated; // {s}
    }

    function consumeProposalCharge(ProposalThrottleStorage storage proposalThrottle, address account) external {
        ProposalThrottle storage throttle = proposalThrottle.throttles[account];

        uint256 elapsed = block.timestamp - throttle.lastUpdated;
        uint256 charge = throttle.currentCharge + (elapsed * 1e18) / PROPOSAL_THROTTLE_PERIOD;

        if (charge > 1e18) {
            charge = 1e18;
        }

        uint256 proposalsAvailable = (proposalThrottle.capacity * charge) / 1e18;
        require(proposalsAvailable >= 1, IReserveOptimisticGovernor.ProposalThrottleExceeded());

        throttle.currentCharge = charge - (1e18 / proposalThrottle.capacity);
        throttle.lastUpdated = block.timestamp;
    }
}
