// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IReserveOptimisticGovernorDeployer } from "./IDeployer.sol";

interface IReserveOptimisticGovernanceVersionRegistry {
    error VersionRegistry__ZeroAddress();
    error VersionRegistry__InvalidRegistration();
    error VersionRegistry__AlreadyDeprecated();
    error VersionRegistry__InvalidCaller();
    error VersionRegistry__Unconfigured();

    event VersionRegistered(bytes32 versionHash, IReserveOptimisticGovernorDeployer folioDeployer);
    event VersionDeprecated(bytes32 versionHash);

    function getImplementationsForVersion(bytes32 versionHash)
        external
        view
        returns (address stakingVault, address governorImpl, address timelockImpl);

    function isDeprecated(bytes32 versionHash) external view returns (bool);

    function deployments(bytes32 versionHash) external view returns (IReserveOptimisticGovernorDeployer);
}
