// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";

import { IReserveOptimisticGovernor } from "@interfaces/IReserveOptimisticGovernor.sol";
import { ITimelockControllerOptimistic } from "@interfaces/ITimelockControllerOptimistic.sol";

import {
    OPTIMISTIC_GUARDIAN_MANAGER_ROLE as OPTIMISTIC_GUARDIAN_MANAGER,
    OPTIMISTIC_GUARDIAN_ROLE as OPTIMISTIC_GUARDIAN
} from "@utils/Constants.sol";

/**
 * @title Guardian
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice Singleton contract to serve as CANCELLER_ROLE for all timelocks.
 *
 * Permissions:
 *     - DEFAULT_ADMIN_ROLE can admin other roles AND cancel any type of proposal
 *     - OPTIMISTIC_GUARDIAN_ROLE can ONLY cancel non-Defeated optimistic proposals
 *     - OPTIMISTIC_GUARDIAN_MANAGER_ROLE can ONLY grant new OPTIMISTIC_GUARDIAN_ROLEs
 *
 * DEFAULT_ADMIN_ROLE is reserved for break-glass scenarios.
 */
contract Guardian is AccessControlEnumerable {
    bytes32 public constant OPTIMISTIC_GUARDIAN_ROLE = OPTIMISTIC_GUARDIAN;
    bytes32 public constant OPTIMISTIC_GUARDIAN_MANAGER_ROLE = OPTIMISTIC_GUARDIAN_MANAGER;

    error Guardian__UnauthorizedCaller();
    error Guardian__ZeroAddress();
    error Guardian__InvalidGovernor(address governor);
    error Guardian__InvalidTimelock(address timelock);
    error Guardian__NotOptimisticProposal(uint256 proposalId);
    error Guardian__DefeatedProposal(uint256 proposalId);

    constructor(
        address initialAdmin,
        address initialOptimisticGuardianManager,
        address[] memory initialOptimisticGuardians
    ) {
        // DEFAULT_ADMIN_ROLE
        _grantRole(DEFAULT_ADMIN_ROLE, _requireNonZero(initialAdmin));

        // OPTIMISTIC_GUARDIAN_MANAGER_ROLE
        _grantRole(OPTIMISTIC_GUARDIAN_MANAGER_ROLE, _requireNonZero(initialAdmin));
        if (initialOptimisticGuardianManager != address(0)) {
            _grantRole(OPTIMISTIC_GUARDIAN_MANAGER_ROLE, initialOptimisticGuardianManager);
        }

        // OPTIMISTIC_GUARDIAN_ROLE
        for (uint256 i = 0; i < initialOptimisticGuardians.length; ++i) {
            _grantRole(OPTIMISTIC_GUARDIAN_ROLE, _requireNonZero(initialOptimisticGuardians[i]));
        }
    }

    // === External ===

    /// @dev Only callable by OPTIMISTIC_GUARDIAN_MANAGER_ROLE
    function grantOptimisticGuardian(address account) external onlyRole(OPTIMISTIC_GUARDIAN_MANAGER_ROLE) {
        _grantRole(OPTIMISTIC_GUARDIAN_ROLE, _requireNonZero(account));
    }

    /// @dev Only callable by DEFAULT_ADMIN_ROLE
    function revokeOptimisticProposer(address governor, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ITimelockControllerOptimistic(_timelock(governor)).revokeOptimisticProposer(account);
    }

    /// @dev Only callable by OPTIMISTIC_GUARDIAN_ROLE for optimistic proposals, or by DEFAULT_ADMIN_ROLE
    /// @return proposalId The ID of the proposal that was cancelled
    function cancel(
        address governor,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external returns (uint256 proposalId) {
        bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE, msg.sender);

        if (!isAdmin && !hasRole(OPTIMISTIC_GUARDIAN_ROLE, msg.sender)) {
            revert Guardian__UnauthorizedCaller();
        }

        IReserveOptimisticGovernor managedGovernor = _governor(governor);
        proposalId = IGovernor(governor).getProposalId(targets, values, calldatas, descriptionHash);

        if (!isAdmin) {
            require(managedGovernor.isOptimistic(proposalId), Guardian__NotOptimisticProposal(proposalId));
            require(
                IGovernor(governor).state(proposalId) != IGovernor.ProposalState.Defeated,
                Guardian__DefeatedProposal(proposalId)
            );
        }

        return managedGovernor.cancel(targets, values, calldatas, descriptionHash);
    }

    // === Internal ===

    function _governor(address governor) internal view returns (IReserveOptimisticGovernor) {
        if (governor == address(0) || governor.code.length == 0) {
            revert Guardian__InvalidGovernor(governor);
        }

        return IReserveOptimisticGovernor(governor);
    }

    function _timelock(address governor) internal view returns (address timelock) {
        timelock = _governor(governor).timelock();

        if (timelock == address(0) || timelock.code.length == 0) {
            revert Guardian__InvalidTimelock(timelock);
        }
    }

    function _requireNonZero(address account) internal pure returns (address) {
        if (account == address(0)) {
            revert Guardian__ZeroAddress();
        }

        return account;
    }
}
