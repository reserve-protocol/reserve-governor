// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITimelockControllerOptimistic {
    error TimelockControllerOptimistic__OperationConflict();
    error TimelockControllerOptimistic__UnauthorizedUpgrade();

    // === Events ===

    function initialize(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        external;
}
