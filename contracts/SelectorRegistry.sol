// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract SelectorRegistry is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // === Events ===

    event SelectorAdded(address indexed target, bytes4 indexed selector);
    event SelectorRemoved(address indexed target, bytes4 indexed selector);

    // === Errors ===

    error SelfAsTarget();

    // === Structs ===

    struct SelectorData {
        address target;
        bytes4 selector;
    }

    // === State ===

    EnumerableSet.AddressSet private _targets;
    mapping(address target => EnumerableSet.Bytes32Set) private _allowedSelectors;

    // === Constructor ===

    constructor(address _owner, SelectorData[] memory selectors) Ownable(_owner) {
        for (uint256 i = 0; i < selectors.length; i++) {
            _add(selectors[i].target, selectors[i].selector);
        }
    }

    // === External ===

    function registerSelectors(SelectorData[] calldata selectors) external onlyOwner {
        for (uint256 i = 0; i < selectors.length; i++) {
            _add(selectors[i].target, selectors[i].selector);
        }
    }

    function unregisterSelectors(SelectorData[] calldata selectors) external onlyOwner {
        for (uint256 i = 0; i < selectors.length; i++) {
            _remove(selectors[i].target, selectors[i].selector);
        }
    }

    // === View ===

    function targets() external view returns (address[] memory) {
        return _targets.values();
    }

    function isAllowed(address target, bytes4 selector) external view returns (bool) {
        return _allowedSelectors[target].contains(bytes32(selector));
    }

    function selectorsAllowed(address target) external view returns (bytes4[] memory allowedSelectors4) {
        bytes32[] memory allowedSelectors = _allowedSelectors[target].values();

        allowedSelectors4 = new bytes4[](allowedSelectors.length);

        for (uint256 i = 0; i < allowedSelectors.length; i++) {
            allowedSelectors4[i] = bytes4(allowedSelectors[i]);
        }
    }

    // === Internal ===

    function _add(address target, bytes4 selector) internal {
        require(target != address(this), SelfAsTarget());

        bool added = _allowedSelectors[target].add(bytes32(selector));

        if (added) {
            _targets.add(target);

            emit SelectorAdded(target, selector);
        }
    }

    function _remove(address target, bytes4 selector) internal {
        bool removed = _allowedSelectors[target].remove(bytes32(selector));

        if (removed) {
            if (_allowedSelectors[target].length() == 0) {
                _targets.remove(target);
            }

            emit SelectorRemoved(target, selector);
        }
    }
}
