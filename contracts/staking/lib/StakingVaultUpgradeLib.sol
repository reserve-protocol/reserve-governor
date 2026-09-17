// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ReserveOptimisticGovernanceVersionRegistry } from "@src/VersionRegistry.sol";
import { UnstakingManager } from "@staking/UnstakingManager.sol";
import { Versioned } from "@utils/Versioned.sol";

library StakingVaultUpgradeLib {
    error Vault__VersionDeprecated(bytes32 versionHash);
    error Vault__NotLatestStakingVault(address stakingVaultImpl);

    function deployUnstakingManager(IERC20 asset) external returns (UnstakingManager) {
        return new UnstakingManager(asset);
    }

    function authorizeUpgrade(ReserveOptimisticGovernanceVersionRegistry versionRegistry, address stakingVaultImpl)
        external
        view
    {
        bytes32 versionHash = keccak256(abi.encodePacked(Versioned(stakingVaultImpl).version()));

        // RoleRegistry SHOULD maintain fresh latest versions

        (bytes32 latestVersionHash,,, bool deprecated) = versionRegistry.getLatestVersion();
        require(!deprecated, Vault__VersionDeprecated(versionHash));
        require(versionHash == latestVersionHash, Vault__NotLatestStakingVault(stakingVaultImpl));

        (address latestStakingVaultImpl,,) = versionRegistry.getImplementationsForVersion(versionHash);
        require(latestStakingVaultImpl == stakingVaultImpl, Vault__NotLatestStakingVault(stakingVaultImpl));
    }
}
