// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IOptimisticSelectorRegistry {
    // === Events ===

    event SelectorsAdded(address indexed target, bytes4[] indexed selectors);
    event SelectorsRemoved(address indexed target, bytes4[] indexed selectors);

    // === Errors ===

    error OnlyOwner();
    error SelfAsTarget();

    // === Data ===

    struct SelectorData {
        address target;
        bytes4[] selectors;
    }

    // === Functions ===

    function isAllowed(address target, bytes4 selector) external view returns (bool);
}
