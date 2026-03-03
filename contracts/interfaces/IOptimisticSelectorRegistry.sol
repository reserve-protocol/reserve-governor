// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOptimisticSelectorRegistry {
    // === Events ===

    event SelectorAdded(address indexed proposer, address indexed target, bytes4 indexed selectors);
    event SelectorRemoved(address indexed proposer, address indexed target, bytes4 indexed selectors);

    // === Errors ===

    error OnlyOwner(address caller);
    error InvalidTarget(address target);
    error InvalidSelector(bytes4 selector);

    // === Data ===

    struct SelectorData {
        address proposer;
        address target;
        bytes4[] selectors;
    }

    // === Functions ===

    function isAllowed(address proposer, address target, bytes4 selector) external view returns (bool);
}
