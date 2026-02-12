// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IReserveOptimisticGovernor } from "../interfaces/IReserveOptimisticGovernor.sol";

import { THROTTLE_PERIOD } from "../utils/Constants.sol";

library ProposalThrottleLib {
    struct ProposalThrottleStorage {
        uint256 capacity; // max number of proposals per 24h
        mapping(address account => ProposalThrottle) throttles;
    }

    struct ProposalThrottle {
        uint256 currentCharge; // D18{1}
        uint256 lastUpdated; // {s}
    }

    /// Consume one proposal charge for an account
    function consumeProposalCharge(ProposalThrottleStorage storage self, address account) external {
        ProposalThrottle storage throttle = self.throttles[account];

        uint256 elapsed = block.timestamp - throttle.lastUpdated;
        uint256 charge = throttle.currentCharge + (elapsed * 1e18) / THROTTLE_PERIOD;

        if (charge > 1e18) {
            charge = 1e18;
        }

        uint256 proposalsAvailable = (self.capacity * charge) / 1e18;
        require(proposalsAvailable >= 1, IReserveOptimisticGovernor.ProposalThrottleExceeded());

        throttle.currentCharge = charge - (1e18 / self.capacity);
        throttle.lastUpdated = block.timestamp;
    }
}
