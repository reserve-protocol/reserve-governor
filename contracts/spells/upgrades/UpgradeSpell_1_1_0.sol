// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { TimelockControllerOptimistic } from "@governance/TimelockControllerOptimistic.sol";
import { ReserveOptimisticGovernanceVersionRegistry } from "@src/VersionRegistry.sol";
import { StakingVault } from "@staking/StakingVault.sol";

bytes32 constant VERSION_1_0_0 = keccak256("1.0.0");
bytes32 constant VERSION_1_1_0 = keccak256("1.1.0");

/**
 * @title UpgradeSpell_1_1_0
 * @notice Production 1.0.0 -> 1.1.0 upgrade spell for all governance components.
 * @dev `castVault` follows the reserve-index-dtf temporary-admin pattern. The
 *      vault admin timelock grants this contract DEFAULT_ADMIN_ROLE, calls it,
 *      and the spell upgrades then renounces that role.
 *
 *      `castTimelock` is used as an intermediate UUPS implementation. The DTF
 *      proposal directly upgrades the governor (required by onlyGovernance) and
 *      upgrades the timelock to this spell. The delegatecalled `castTimelock`
 *      initializes the registry and self-upgrades to the registered final
 *      timelock implementation. Thus all three proxies are upgraded by the
 *      production spell flow without bypassing either authorization boundary.
 */
contract UpgradeSpell_1_1_0 is TimelockControllerOptimistic {
    error UpgradeSpell__Error(uint256 code);

    function castVault(StakingVault vault) external {
        require(keccak256(bytes(vault.version())) == VERSION_1_0_0, UpgradeSpell__Error(1));
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(this)), UpgradeSpell__Error(2));
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), msg.sender), UpgradeSpell__Error(3));

        ReserveOptimisticGovernanceVersionRegistry registry = vault.versionRegistry();
        (bytes32 versionHash, string memory version,, bool deprecated) = registry.getLatestVersion();
        require(!deprecated && keccak256(bytes(version)) == VERSION_1_1_0, UpgradeSpell__Error(4));
        (address implementation,,) = registry.getImplementationsForVersion(versionHash);

        vault.upgradeToAndCall(implementation, "");
        require(keccak256(bytes(vault.version())) == VERSION_1_1_0, UpgradeSpell__Error(5));

        vault.renounceRole(vault.DEFAULT_ADMIN_ROLE(), address(this));
        require(!vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(this)), UpgradeSpell__Error(6));
        require(vault.getRoleMemberCount(vault.DEFAULT_ADMIN_ROLE()) == 1, UpgradeSpell__Error(7));
        require(vault.getRoleMember(vault.DEFAULT_ADMIN_ROLE(), 0) == msg.sender, UpgradeSpell__Error(8));
    }

    function castTimelock(address timelockImplementation, ReserveOptimisticGovernanceVersionRegistry versionRegistry)
        external
    {
        require(msg.sender == address(this), UpgradeSpell__Error(9));
        (,, address registeredTimelock) = versionRegistry.getImplementationsForVersion(VERSION_1_1_0);
        require(registeredTimelock == timelockImplementation, UpgradeSpell__Error(10));

        TimelockControllerOptimistic self = TimelockControllerOptimistic(payable(address(this)));
        self.initializeVersionRegistry(address(versionRegistry));
        self.upgradeToAndCall(timelockImplementation, "");
    }
}
