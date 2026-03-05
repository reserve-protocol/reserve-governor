// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IReserveOptimisticGovernanceVersionRegistry } from "@interfaces/IDeployerVersionRegistry.sol";

import { Versioned } from "./Versioned.sol";

library UpgradeLib {
    error UpgradeLib__InvalidStakingVaultImplementation();
    error UpgradeLib__InvalidGovernorImplementation();
    error UpgradeLib__InvalidTimelockImplementation();
    error UpgradeLib__VersionDeprecated();

    enum UpgradeType {
        STAKING_VAULT,
        GOVERNOR,
        TIMELOCK
    }

    /// @param newImplementation StakingVault, ReserveOptimisticGovernor, or TimelockControllerOptimistic
    function authorizeUpgrade(address _versionRegistry, UpgradeType upgradeType, address newImplementation)
        external
        view
    {
        bytes32 newVersion = keccak256(abi.encodePacked(Versioned(newImplementation).version()));

        IReserveOptimisticGovernanceVersionRegistry versionRegistry =
            IReserveOptimisticGovernanceVersionRegistry(_versionRegistry);

        require(!versionRegistry.isDeprecated(newVersion), UpgradeLib__VersionDeprecated());

        (address stakingVaultImpl, address governorImpl, address timelockImpl) =
            versionRegistry.getImplementationsForVersion(newVersion);

        if (upgradeType == UpgradeType.STAKING_VAULT) {
            require(stakingVaultImpl == newImplementation, UpgradeLib__InvalidStakingVaultImplementation());
        } else if (upgradeType == UpgradeType.GOVERNOR) {
            require(governorImpl == newImplementation, UpgradeLib__InvalidGovernorImplementation());
        } else if (upgradeType == UpgradeType.TIMELOCK) {
            require(timelockImpl == newImplementation, UpgradeLib__InvalidTimelockImplementation());
        }
    }
}
