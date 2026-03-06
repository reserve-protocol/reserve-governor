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

    mapping(address proposer => EnumerableSet.AddressSet) private _targets;
    mapping(address proposer => mapping(address target => EnumerableSet.Bytes32Set)) private _allowedSelectors;

    // === Initialization ===

    constructor() {
        _disableInitializers();
    }

    function initialize(address _governor, SelectorData[] memory selectorData) public initializer {
        governor = ReserveOptimisticGovernor(payable(_governor));

        // validate governor
        governor.timelock();
        governor.token();

        for (uint256 i = 0; i < selectorData.length; i++) {
            _add(selectorData[i].proposer, selectorData[i].target, selectorData[i].selectors);
        }
    }

    // === External ===

    modifier onlyTimelock() {
        require(msg.sender == governor.timelock(), OnlyOwner(msg.sender));
        _;
    }

    function registerSelectors(SelectorData[] calldata selectorData) external onlyTimelock {
        for (uint256 i = 0; i < selectorData.length; i++) {
            _add(selectorData[i].proposer, selectorData[i].target, selectorData[i].selectors);
        }
    }

    /// @dev Warning: Does NOT cancel existing optimistic proposals using these selectors
    ///      CANCELLER_ROLE must rememeber to cancel existing optimistic proposals if execution should be prevented
    function unregisterSelectors(SelectorData[] calldata selectorData) external onlyTimelock {
        for (uint256 i = 0; i < selectorData.length; i++) {
            _remove(selectorData[i].proposer, selectorData[i].target, selectorData[i].selectors);
        }
    }

    // === View ===

    function targets(address proposer) external view returns (address[] memory) {
        return _targets[proposer].values();
    }

    function isAllowed(address proposer, address target, bytes4 selector) external view returns (bool) {
        return _allowedSelectors[proposer][target].contains(bytes32(selector));
    }

    function selectorsAllowed(address proposer, address target)
        external
        view
        returns (bytes4[] memory allowedSelectors4)
    {
        bytes32[] memory allowedSelectors = _allowedSelectors[proposer][target].values();

        allowedSelectors4 = new bytes4[](allowedSelectors.length);

        for (uint256 i = 0; i < allowedSelectors.length; i++) {
            allowedSelectors4[i] = bytes4(allowedSelectors[i]);
        }
    }

    // === Internal ===

    function _add(address proposer, address target, bytes4[] memory selectors) internal {
        // target != self, governor, timelock, token
        require(
            target != address(this) && target != address(governor) && target != address(governor.timelock())
                && target != address(governor.token()),
            InvalidTarget(target)
        );

        for (uint256 i = 0; i < selectors.length; i++) {
            // no empty selectors
            require(selectors[i] != bytes4(0), InvalidSelector(selectors[i]));

            bool added = _allowedSelectors[proposer][target].add(bytes32(selectors[i]));

            if (added) {
                _targets[proposer].add(target);

                emit SelectorAdded(proposer, target, selectors[i]);
            }
        }
    }

    function _remove(address proposer, address target, bytes4[] memory selectors) internal {
        for (uint256 i = 0; i < selectors.length; i++) {
            bool removed = _allowedSelectors[proposer][target].remove(bytes32(selectors[i]));

            if (removed) {
                if (_allowedSelectors[proposer][target].length() == 0) {
                    _targets[proposer].remove(target);
                }

                emit SelectorRemoved(proposer, target, selectors[i]);
            }
        }
    }
}
