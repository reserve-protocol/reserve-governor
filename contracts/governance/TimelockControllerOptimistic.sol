// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    AccessControlEnumerableUpgradeable,
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { GovernanceUpgradeLib } from "@governance/lib/GovernanceUpgradeLib.sol";
import { ITimelockControllerOptimistic } from "@interfaces/ITimelockControllerOptimistic.sol";
import { ReserveOptimisticGovernanceVersionRegistry } from "@src/VersionRegistry.sol";
import { CANCELLER_ROLE, OPTIMISTIC_PROPOSER_ROLE } from "@utils/Constants.sol";
import { Versioned } from "@utils/Versioned.sol";

contract TimelockControllerOptimistic is
    TimelockControllerUpgradeable,
    AccessControlEnumerableUpgradeable,
    Versioned,
    UUPSUpgradeable,
    ITimelockControllerOptimistic
{
    error TimelockControllerOptimistic__InvalidVersionRegistry();
    error TimelockControllerOptimistic__VersionRegistryAlreadySet();

    event VersionRegistrySet(address versionRegistry);

    ReserveOptimisticGovernanceVersionRegistry public versionRegistry;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin,
        address _versionRegistry
    ) public override(ITimelockControllerOptimistic) initializer {
        __TimelockController_init(minDelay, proposers, executors, admin);
        __AccessControlEnumerable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _setVersionRegistry(_versionRegistry);
    }

    /// @dev Call atomically via upgradeToAndCall when upgrading a proxy without a registry.
    function initializeVersionRegistry(address registry) external reinitializer(2) {
        require(msg.sender == address(this), TimelockControllerOptimistic__UnauthorizedUpgrade());
        _setVersionRegistry(registry);
    }

    function _setVersionRegistry(address registry) private {
        require(address(versionRegistry) == address(0), TimelockControllerOptimistic__VersionRegistryAlreadySet());
        require(registry.code.length != 0, TimelockControllerOptimistic__InvalidVersionRegistry());
        versionRegistry = ReserveOptimisticGovernanceVersionRegistry(registry);
        emit VersionRegistrySet(registry);
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

    /// @dev Guardian can revoke OPTIMISTIC_PROPOSER_ROLE
    ///      Any malicious proposals should be cancelled if their execution needs to also be prevented
    function revokeOptimisticProposer(address account) external onlyRole(CANCELLER_ROLE) {
        _revokeRole(OPTIMISTIC_PROPOSER_ROLE, account);
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
    ) public payable onlyRole(PROPOSER_ROLE) {
        bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);

        TimelockControllerStorage storage $ = _getTimelockControllerStorage();

        // mark Ready
        require($._timestamps[id] == 0, TimelockControllerOptimistic__OperationConflict());
        $._timestamps[id] = block.timestamp;

        // check caller has EXECUTOR_ROLE and execute
        executeBatch(targets, values, payloads, predecessor, salt);
    }

    /// @dev Timelock authorizes its own upgrades (self-admin pattern)
    function _authorizeUpgrade(address timelockImpl) internal view override {
        require(msg.sender == address(this), TimelockControllerOptimistic__UnauthorizedUpgrade());
        GovernanceUpgradeLib.authorizeTimelockUpgrade(versionRegistry, timelockImpl);
    }
}
