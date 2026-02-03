// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { IOptimisticSelectorRegistry } from "../interfaces/IOptimisticSelectorRegistry.sol";

import { ReserveOptimisticGovernor } from "./ReserveOptimisticGovernor.sol";

contract OptimisticSelectorRegistry is Initializable, IOptimisticSelectorRegistry {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // === State ===

    ReserveOptimisticGovernor public governor;

    EnumerableSet.AddressSet private _targets;
    mapping(address target => EnumerableSet.Bytes32Set) private _allowedSelectors;

    // === Initialization ===

    constructor() {
        _disableInitializers();
    }

    function initialize(address _governor, SelectorData[] memory selectorData) public initializer {
        governor = ReserveOptimisticGovernor(payable(_governor));

        for (uint256 i = 0; i < selectorData.length; i++) {
            _add(selectorData[i].target, selectorData[i].selectors);
        }
    }

    // === External ===

    modifier onlyTimelock() {
        require(msg.sender == governor.timelock(), OnlyOwner());
        _;
    }

    function registerSelectors(SelectorData[] calldata selectorData) external onlyTimelock {
        for (uint256 i = 0; i < selectorData.length; i++) {
            _add(selectorData[i].target, selectorData[i].selectors);
        }
    }

    function unregisterSelectors(SelectorData[] calldata selectorData) external onlyTimelock {
        for (uint256 i = 0; i < selectorData.length; i++) {
            _remove(selectorData[i].target, selectorData[i].selectors);
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
