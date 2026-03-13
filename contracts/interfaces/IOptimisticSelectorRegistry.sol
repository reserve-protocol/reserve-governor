// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOptimisticSelectorRegistry {
    // === Events ===

    event SelectorAdded(address indexed target, bytes4 indexed selector);
    event SelectorRemoved(address indexed target, bytes4 indexed selector);

    // === Errors ===

    error InvalidGovernor();
    error OnlyOwner(address caller);
    error InvalidTarget(address target);
    error InvalidSelector(bytes4 selector);

    // === Data ===

    struct SelectorData {
        address target;
        bytes4[] selectors;
    }

    // === Functions ===

    function isAllowed(address target, bytes4 selector) external view returns (bool);
}
