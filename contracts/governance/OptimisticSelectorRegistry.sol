// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { IOptimisticSelectorRegistry } from "../interfaces/IOptimisticSelectorRegistry.sol";

import { UpgradeControlled } from "../utils/UpgradeControlled.sol";

contract OptimisticSelectorRegistry is UpgradeControlled, IOptimisticSelectorRegistry {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // === State ===

    EnumerableSet.AddressSet private _targets;
    mapping(address target => EnumerableSet.Bytes32Set) private _allowedSelectors;

    // === Initialization ===

    constructor() {
        _disableInitializers();
    }

    function initialize(SelectorData[] memory selectorData, address upgradeManager_) public initializer {
        __UpgradeControlled_init(upgradeManager_);

        for (uint256 i = 0; i < selectorData.length; i++) {
            _add(selectorData[i].target, selectorData[i].selectors);
        }
    }

    // === External ===

    modifier onlyTimelock() {
        require(msg.sender == upgradeManager.timelock(), OnlyOwner(msg.sender));
        _;
    }

    function registerSelectors(SelectorData[] calldata selectorData) external onlyTimelock {
        for (uint256 i = 0; i < selectorData.length; i++) {
            _add(selectorData[i].target, selectorData[i].selectors);
        }
    }

    /// @dev Warning: Does NOT cancel existing optimistic proposals using these selectors
    ///      CANCELLER_ROLE must rememeber to cancel existing optimistic proposals if execution should be prevented
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
        // target != self, governor, timelock, token
        require(
            target != address(this) && target != address(upgradeManager) && target != upgradeManager.governor()
                && target != upgradeManager.timelock() && target != upgradeManager.stakingVault(),
            InvalidTarget(target)
        );

        for (uint256 i = 0; i < selectors.length; i++) {
            // no empty selectors
            require(selectors[i] != bytes4(0), InvalidSelector(selectors[i]));

            bool added = _allowedSelectors[target].add(bytes32(selectors[i]));

            if (added) {
                _targets.add(target);

                emit SelectorAdded(target, selectors[i]);
            }
        }
    }

    function _remove(address target, bytes4[] memory selectors) internal {
        for (uint256 i = 0; i < selectors.length; i++) {
            bool removed = _allowedSelectors[target].remove(bytes32(selectors[i]));

            if (removed) {
                if (_allowedSelectors[target].length() == 0) {
                    _targets.remove(target);
                }

                emit SelectorRemoved(target, selectors[i]);
            }
        }
    }
}
