// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ReserveOptimisticGovernanceVersionRegistry } from "@src/VersionRegistry.sol";
import { Versioned } from "@utils/Versioned.sol";

library GovernanceUpgradeLib {
    error Governance__VersionDeprecated(bytes32 versionHash);
    error Governance__NotLatestGovernor(address governorImpl);
    error Governance__NotLatestTimelock(address timelockImpl);

    function authorizeGovernorUpgrade(ReserveOptimisticGovernanceVersionRegistry versionRegistry, address governorImpl)
        external
        view
    {
        _authorizeComponentUpgrade(versionRegistry, governorImpl, false);
    }

    function authorizeTimelockUpgrade(ReserveOptimisticGovernanceVersionRegistry versionRegistry, address timelockImpl)
        external
        view
    {
        _authorizeComponentUpgrade(versionRegistry, timelockImpl, true);
    }

    function _authorizeComponentUpgrade(
        ReserveOptimisticGovernanceVersionRegistry versionRegistry,
        address implementation,
        bool timelock
    ) private view {
        bytes32 versionHash = keccak256(abi.encodePacked(Versioned(implementation).version()));
        (bytes32 latestVersionHash,,, bool deprecated) = versionRegistry.getLatestVersion();
        require(!deprecated, Governance__VersionDeprecated(versionHash));
        if (versionHash != latestVersionHash) {
            if (timelock) {
                revert Governance__NotLatestTimelock(implementation);
            }
            revert Governance__NotLatestGovernor(implementation);
        }
        (, address latestGovernorImpl, address latestTimelockImpl) =
            versionRegistry.getImplementationsForVersion(versionHash);
        address latestImpl = timelock ? latestTimelockImpl : latestGovernorImpl;
        if (latestImpl != implementation) {
            if (timelock) {
                revert Governance__NotLatestTimelock(implementation);
            }
            revert Governance__NotLatestGovernor(implementation);
        }
    }
}
