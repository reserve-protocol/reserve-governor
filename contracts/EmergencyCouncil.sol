// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";

import { IReserveOptimisticGovernor } from "@interfaces/IReserveOptimisticGovernor.sol";
import { ITimelockControllerOptimistic } from "@interfaces/ITimelockControllerOptimistic.sol";

import { OPTIMISTIC_GUARDIAN_ROLE as OPTIMISTIC_GUARDIAN } from "@utils/Constants.sol";

/**
 * @title EmergencyCouncil
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice Singleton contract to serve as CANCELLER_ROLE for all timelocks.
 *         - DEFAULT_ADMIN_ROLE can cancel any type of proposal
 *         - OPTIMISTIC_GUARDIAN_ROLE can only cancel non-Defeated optimistic proposals
 */
contract EmergencyCouncil is AccessControlEnumerable {
    bytes32 public constant OPTIMISTIC_GUARDIAN_ROLE = OPTIMISTIC_GUARDIAN;

    error EmergencyCouncil__UnauthorizedCaller();
    error EmergencyCouncil__ZeroAddress();
    error EmergencyCouncil__InvalidGovernor(address governor);
    error EmergencyCouncil__InvalidTimelock(address timelock);
    error EmergencyCouncil__NotOptimisticProposal(uint256 proposalId);
    error EmergencyCouncil__DefeatedProposal(uint256 proposalId);

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
            revert EmergencyCouncil__UnauthorizedCaller();
        }

        IReserveOptimisticGovernor managedGovernor = _governor(governor);
        proposalId = IGovernor(governor).getProposalId(targets, values, calldatas, descriptionHash);

        if (!isAdmin) {
            require(managedGovernor.isOptimistic(proposalId), EmergencyCouncil__NotOptimisticProposal(proposalId));
            require(
                IGovernor(governor).state(proposalId) != IGovernor.ProposalState.Defeated,
                EmergencyCouncil__DefeatedProposal(proposalId)
            );
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
