// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    AccessControlEnumerableUpgradeable,
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { ITimelockControllerOptimistic } from "../interfaces/ITimelockControllerOptimistic.sol";

import { Versioned } from "../utils/Versioned.sol";

contract TimelockControllerOptimistic is
    TimelockControllerUpgradeable,
    AccessControlEnumerableUpgradeable,
    Versioned,
    UUPSUpgradeable,
    ITimelockControllerOptimistic
{
    constructor() {
        _disableInitializers();
    }

    function initialize(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        public
        override(ITimelockControllerOptimistic, TimelockControllerUpgradeable)
        initializer
    {
        __TimelockController_init(minDelay, proposers, executors, admin);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(TimelockControllerUpgradeable, AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _grantRole(bytes32 role, address account)
        internal
        virtual
        override(AccessControlUpgradeable, AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return super._grantRole(role, account);
    }

    function _revokeRole(bytes32 role, address account)
        internal
        virtual
        override(AccessControlUpgradeable, AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return super._revokeRole(role, account);
    }

    /// @dev Danger!
    ///      Execute a batch of operations immediately without waiting out the delay.
    ///      Caller must have BOTH the PROPOSER_ROLE and EXECUTOR_ROLE.
    function executeBatchBypass(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) public payable onlyRoleOrOpenRole(PROPOSER_ROLE) {
        bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);

        TimelockControllerStorage storage $ = _getTimelockControllerStorage();

        // mark Ready
        require($._timestamps[id] == 0, TimelockControllerOptimistic__OperationConflict());
        $._timestamps[id] = block.timestamp;

        // check caller has EXECUTOR_ROLE and execute
        executeBatch(targets, values, payloads, predecessor, salt);
    }

    /// @dev Timelock authorizes its own upgrades (self-admin pattern)
    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == address(this), TimelockControllerOptimistic__UnauthorizedUpgrade());
    }
}
