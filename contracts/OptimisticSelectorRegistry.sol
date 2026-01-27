// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract OptimisticSelectorRegistry is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // === Events ===

    event SelectorsAdded(address indexed target, bytes4[] indexed selectors);
    event SelectorsRemoved(address indexed target, bytes4[] indexed selectors);

    // === Errors ===

    error SelfAsTarget();

    // === Structs ===

    struct SelectorDataQuery {
        address target;
        bytes4[] selectors;
    }

    // === State ===

    EnumerableSet.AddressSet private _targets;
    mapping(address target => EnumerableSet.Bytes32Set) private _allowedSelectors;

    // === Constructor ===

    constructor(address _owner, SelectorDataQuery[] memory queries) Ownable(_owner) {
        for (uint256 i = 0; i < queries.length; i++) {
            _add(queries[i].target, queries[i].selectors);
        }
    }

    // === External ===

    function registerSelectors(SelectorDataQuery[] calldata queries) external onlyOwner {
        for (uint256 i = 0; i < queries.length; i++) {
            _add(queries[i].target, queries[i].selectors);
        }
    }

    function unregisterSelectors(SelectorDataQuery[] calldata queries) external onlyOwner {
        for (uint256 i = 0; i < queries.length; i++) {
            _remove(queries[i].target, queries[i].selectors);
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

    function _add(address target, bytes4[] memory selectors) internal {
        require(target != address(this), SelfAsTarget());

        for (uint256 i = 0; i < selectors.length; i++) {
            bool added = _allowedSelectors[target].add(bytes32(selectors[i]));

            if (added) {
                _targets.add(target);
            }
        }

        emit SelectorsAdded(target, selectors);
    }

    function _remove(address target, bytes4[] memory selectors) internal {
        require(target != address(this), SelfAsTarget());

        for (uint256 i = 0; i < selectors.length; i++) {
            bool removed = _allowedSelectors[target].remove(bytes32(selectors[i]));

            if (removed && _allowedSelectors[target].length() == 0) {
                _targets.remove(target);
            }
        }

        emit SelectorsRemoved(target, selectors);
    }
}
