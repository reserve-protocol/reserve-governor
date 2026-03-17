// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ITimelockControllerOptimistic {
    error TimelockControllerOptimistic__OperationConflict();
    error TimelockControllerOptimistic__InvalidInitialization();

    // === Events ===

    function initialize(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin,
        address upgradeManager
    ) external;

    function executeBatchBypass(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 predecessor,
        bytes32 salt
    ) external payable;
}
