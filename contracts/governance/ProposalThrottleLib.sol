// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IReserveOptimisticGovernor } from "../interfaces/IReserveOptimisticGovernor.sol";

library ProposalThrottleLib {
    uint256 private constant MAX_CAPACITY = 10; // 10 per day
    uint256 private constant THROTTLE_PERIOD = 1 days;

    struct ProposalThrottleStorage {
        uint256 capacity; // max number of proposals per 24h
        mapping(address account => ProposalThrottle) throttles;
    }

    struct ProposalThrottle {
        uint256 currentCharge; // D18{1}
        uint256 lastUpdated; // {s}
    }

    /// @dev Changes to `newCapacity` are effective immediately and impact the past
    ///      This is acceptable given the THROTTLE_PERIOD is only 1 day long and this is a governance action
    /// @param newCapacity Proposals per 24h
    function setProposalThrottle(ProposalThrottleStorage storage self, uint256 newCapacity) external {
        require(newCapacity != 0 && newCapacity <= MAX_CAPACITY, IReserveOptimisticGovernor.InvalidProposalThrottle());

        self.capacity = newCapacity;
        emit IReserveOptimisticGovernor.ProposalThrottleUpdated(newCapacity);
    }

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
