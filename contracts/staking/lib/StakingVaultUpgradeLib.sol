// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ReserveOptimisticGovernanceVersionRegistry } from "@src/VersionRegistry.sol";
import { Versioned } from "@utils/Versioned.sol";

library StakingVaultUpgradeLib {
    error Vault__VersionDeprecated(bytes32 versionHash);
    error Vault__NotLatestStakingVault(address stakingVaultImpl);

    function authorizeUpgrade(ReserveOptimisticGovernanceVersionRegistry versionRegistry, address stakingVaultImpl)
        external
        view
    {
        bytes32 versionHash = keccak256(abi.encodePacked(Versioned(stakingVaultImpl).version()));

        (bytes32 latestVersionHash,,, bool deprecated) = versionRegistry.getLatestVersion();
        require(!deprecated, Vault__VersionDeprecated(versionHash));
        require(versionHash == latestVersionHash, Vault__NotLatestStakingVault(stakingVaultImpl));

        (address latestStakingVaultImpl,,) = versionRegistry.getImplementationsForVersion(versionHash);
        require(latestStakingVaultImpl == stakingVaultImpl, Vault__NotLatestStakingVault(stakingVaultImpl));
    }
}
