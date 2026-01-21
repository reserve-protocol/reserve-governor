// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

contract TimelockControllerOptimistic is TimelockControllerUpgradeable {
    function initialize(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        public
        virtual
        override
        initializer
    {
        super.initialize(minDelay, proposers, executors, admin);
    }

    // === Addition ===

    /// @dev Danger!
    ///      Execute a batch of operations immediately without waiting out the delay.
    ///      Caller must have BOTH the PROPOSER_ROLE and EXECUTOR_ROLE.
    function executeBatchBypass(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) public payable onlyRoleOrOpenRole(PROPOSER_ROLE) {
        bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);

        TimelockControllerStorage storage $ = _getTimelockControllerStorage();

        // mark Ready
        require($._timestamps[id] == 0, "TimelockControllerOptimistic: Operation Conflict");
        $._timestamps[id] = 1;

        // check caller has EXECUTOR_ROLE and execute
        executeBatch(targets, values, payloads, predecessor, salt);
    }
}
