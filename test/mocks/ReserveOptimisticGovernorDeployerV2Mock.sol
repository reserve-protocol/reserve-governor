// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ReserveOptimisticGovernorDeployer } from "@src/Deployer.sol";

/// @dev Mock V2 deployer used to register a new version in the version registry during tests
contract ReserveOptimisticGovernorDeployerV2Mock is ReserveOptimisticGovernorDeployer {
    constructor(
        address _versionRegistry,
        address _rewardTokenRegistry,
        address _emergencyGuardian,
        address _stakingVaultImpl,
        address _governorImpl,
        address _timelockImpl,
        address _selectorRegistryImpl
    )
        ReserveOptimisticGovernorDeployer(
            _versionRegistry,
            _rewardTokenRegistry,
            _emergencyGuardian,
            _stakingVaultImpl,
            _governorImpl,
            _timelockImpl,
            _selectorRegistryImpl
        )
    { }

    function version() public pure override returns (string memory) {
        return "2.0.0";
    }
}
