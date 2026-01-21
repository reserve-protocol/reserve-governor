// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

contract TimelockControllerOptimistic is TimelockControllerUpgradeable {
    // Not used; for ReserveGovernor to re-use AccessControl to avoid wasting contract size
    // Also keeps all access control in one place
    bytes32 public constant OPTIMISTIC_PROPOSER_ROLE = keccak256("OPTIMISTIC_PROPOSER_ROLE");

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
