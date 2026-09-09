// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IReserveOptimisticGovernor } from "@interfaces/IReserveOptimisticGovernor.sol";
import { PROPOSAL_THROTTLE_PERIOD } from "@utils/Constants.sol";

library ThrottleLib {
    struct ProposalThrottleStorage {
        uint256 capacity; // max number of proposals per 12h
        mapping(address account => ProposalThrottle) throttles;
    }

    // keccak256(abi.encode(uint256(keccak256("reserve.storage.PessimisticProposalThrottle")) - 1)) &
    // ~bytes32(uint256(0xff))
    bytes32 private constant PESSIMISTIC_PROPOSAL_THROTTLE_STORAGE =
        0x1b552e2349c8f71b53d37da6a2f5cebd50db593b23c71b0ea8a9c163c2942b00;

    struct PessimisticProposalThrottleStorage {
        mapping(address account => ProposalThrottle) throttles;
    }

    struct ProposalThrottle {
        uint256 currentCharge; // D18{1}
        uint256 lastUpdated; // {s}
    }

    function consumeProposalCharge(ProposalThrottleStorage storage proposalThrottle, address account) external {
        _consumeProposalCharge(proposalThrottle.throttles[account], proposalThrottle.capacity);
    }

    function consumePessimisticProposalCharge(address account, uint256 capacity) internal {
        PessimisticProposalThrottleStorage storage $ = _pessimisticProposalThrottleStorage();
        _consumeProposalCharge($.throttles[account], capacity);
    }

    function _consumeProposalCharge(ProposalThrottle storage throttle, uint256 capacity) private {
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

    function _pessimisticProposalThrottleStorage() private pure returns (PessimisticProposalThrottleStorage storage $) {
        assembly {
            $.slot := PESSIMISTIC_PROPOSAL_THROTTLE_STORAGE
        }
    }

    /// @return proposalsAvailable The number of proposals available for the account
    /// @return charge D18{1} The charge for the account
    function _getProposalsAvailable(ProposalThrottle storage throttle, uint256 capacity)
        private
        view
        returns (uint256 proposalsAvailable, uint256 charge)
    {
        uint256 elapsed = block.timestamp - throttle.lastUpdated;
        charge = throttle.currentCharge + (elapsed * 1e18) / PROPOSAL_THROTTLE_PERIOD;

        if (charge > 1e18) {
            charge = 1e18;
        }

        proposalsAvailable = (capacity * charge) / 1e18;
    }
}
