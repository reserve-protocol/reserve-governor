// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

import { IReserveOptimisticGovernor } from "@interfaces/IReserveOptimisticGovernor.sol";
import { ITimelockControllerOptimistic } from "@interfaces/ITimelockControllerOptimistic.sol";

import { OPTIMISTIC_GUARDIAN_ROLE as OPTIMISTIC_GUARDIAN } from "@utils/Constants.sol";

contract EmergencyCouncil is AccessControlEnumerable {
    bytes32 public constant OPTIMISTIC_GUARDIAN_ROLE = OPTIMISTIC_GUARDIAN;

    error EmergencyCouncil__UnauthorizedCaller();
    error EmergencyCouncil__ZeroAddress();
    error EmergencyCouncil__InvalidGovernor(address governor);
    error EmergencyCouncil__InvalidTimelock(address timelock);
    error EmergencyCouncil__NotOptimisticProposal(uint256 proposalId);

    constructor(address initialAdmin, address[] memory initialOptimisticGuardians) {
        _grantRole(DEFAULT_ADMIN_ROLE, _requireNonZero(initialAdmin));

        for (uint256 i = 0; i < initialOptimisticGuardians.length; ++i) {
            _grantRole(OPTIMISTIC_GUARDIAN_ROLE, _requireNonZero(initialOptimisticGuardians[i]));
        }
    }

    // === External ===

    function revokeOptimisticProposer(address governor, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ITimelockControllerOptimistic(_timelock(governor)).revokeOptimisticProposer(account);
    }

    function cancel(
        address governor,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external returns (uint256 proposalId) {
        bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE, msg.sender);

        if (!isAdmin && !hasRole(OPTIMISTIC_GUARDIAN_ROLE, msg.sender)) {
            revert EmergencyCouncil__UnauthorizedCaller();
        }

        IReserveOptimisticGovernor managedGovernor = _governor(governor);

        if (!isAdmin) {
            require(managedGovernor.isOptimistic(proposalId), EmergencyCouncil__NotOptimisticProposal(proposalId));
        }

        return managedGovernor.cancel(targets, values, calldatas, descriptionHash);
    }

    // === Internal ===

    function _governor(address governor) internal view returns (IReserveOptimisticGovernor) {
        if (governor == address(0) || governor.code.length == 0) {
            revert EmergencyCouncil__InvalidGovernor(governor);
        }

        return IReserveOptimisticGovernor(governor);
    }

    function _timelock(address governor) internal view returns (address timelock) {
        timelock = _governor(governor).timelock();

        if (timelock == address(0) || timelock.code.length == 0) {
            revert EmergencyCouncil__InvalidTimelock(timelock);
        }
    }

    function _requireNonZero(address account) internal pure returns (address) {
        if (account == address(0)) {
            revert EmergencyCouncil__ZeroAddress();
        }

        return account;
    }
}
