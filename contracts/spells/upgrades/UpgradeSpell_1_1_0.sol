// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ReserveOptimisticGovernanceVersionRegistry } from "@src/VersionRegistry.sol";
import { StakingVault } from "@staking/StakingVault.sol";

bytes32 constant VERSION_1_0_0 = keccak256("1.0.0");
bytes32 constant VERSION_1_1_0 = keccak256("1.1.0");

/**
 * @title UpgradeSpell_1_1_0
 * @notice Upgrades a deployed 1.0.0 staking vault to 1.1.0.
 * @dev The vault admin timelock must atomically grant this contract
 *      DEFAULT_ADMIN_ROLE and call cast(). The spell validates that the
 *      caller remains an admin, performs the UUPS upgrade, then renounces its
 *      temporary admin role and verifies that the original timelock is the
 *      sole remaining admin.
 *
 *      Governor and timelock proxies are upgraded separately through their
 *      direct governance proposal targets. Their authorization is bound to
 *      the governor execution context and cannot be forwarded by this spell.
 */
contract UpgradeSpell_1_1_0 {
    error UpgradeSpell__Error(uint256 code);

    function cast(StakingVault vault) external {
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
}
