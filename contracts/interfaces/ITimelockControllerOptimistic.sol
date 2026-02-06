// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IVersioned } from "./IVersioned.sol";

interface ITimelockControllerOptimistic is IVersioned {
    error TimelockControllerOptimistic__OperationConflict();
    error TimelockControllerOptimistic__UnauthorizedUpgrade();

    // === Events ===

    function initialize(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        external;

    function executeBatchBypass(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 predecessor,
        bytes32 salt
    ) external payable;
}
