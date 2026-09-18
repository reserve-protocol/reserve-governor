// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { TimelockControllerOptimistic } from "@governance/TimelockControllerOptimistic.sol";
import { ReserveOptimisticGovernanceVersionRegistry } from "@src/VersionRegistry.sol";

bytes32 constant VERSION_1_1_0 = keccak256("1.1.0");

/**
 * @title UpgradeSpell_1_1_0
 * @notice Finishes a 1.0.0 DTF timelock upgrade to 1.1.0.
 * @dev The governance proposal must directly upgrade the governor first, then
 *      call the old timelock's `upgradeToAndCall` with this contract as the
 *      intermediate implementation. During `cast`, the proxy is executing
 *      this code, so the self-calls satisfy the timelock's authorization. The
 *      final self-upgrade leaves the proxy using the registered standard 1.1.0
 *      timelock implementation; the spell is never left installed.
 *
 *      The staking vault is intentionally not part of this spell. In deployed
 *      DTFs its admin governor/timelock is distinct from the DTF governance
 *      system and must be upgraded through that separate admin path first.
 */
contract UpgradeSpell_1_1_0 is TimelockControllerOptimistic {
    error UpgradeSpell__UnauthorizedCaller();
    error UpgradeSpell__InvalidTimelockImplementation();

    function cast(address timelockImplementation, ReserveOptimisticGovernanceVersionRegistry versionRegistry) external {
        if (msg.sender != address(this)) {
            revert UpgradeSpell__UnauthorizedCaller();
        }

        (,, address registeredTimelock) = versionRegistry.getImplementationsForVersion(VERSION_1_1_0);
        if (registeredTimelock != timelockImplementation) {
            revert UpgradeSpell__InvalidTimelockImplementation();
        }

        TimelockControllerOptimistic self = TimelockControllerOptimistic(payable(address(this)));
        self.initializeVersionRegistry(address(versionRegistry));
        self.upgradeToAndCall(timelockImplementation, "");
    }
}
