// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IReserveOptimisticGovernorDeployer } from "@interfaces/IDeployer.sol";
import { IReserveOptimisticGovernanceVersionRegistry } from "@interfaces/IDeployerVersionRegistry.sol";
import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";

import { Versioned } from "@utils/Versioned.sol";

/**
 * @title ReserveOptimisticGovernanceVersionRegistry
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice ReserveOptimisticGovernanceVersionRegistry tracks ReserveOptimisticGovernorDeployers by their
 * version string
 */
contract ReserveOptimisticGovernanceVersionRegistry is IReserveOptimisticGovernanceVersionRegistry {
    IRoleRegistry public immutable roleRegistry;

    mapping(bytes32 => IReserveOptimisticGovernorDeployer) public deployments;
    mapping(bytes32 => bool) public isDeprecated;
    bytes32 private latestVersion;

    constructor(IRoleRegistry _roleRegistry) {
        require(address(_roleRegistry) != address(0), VersionRegistry__ZeroAddress());

        roleRegistry = _roleRegistry;
    }

    function registerVersion(IReserveOptimisticGovernorDeployer deployer) external {
        require(roleRegistry.isOwner(msg.sender), VersionRegistry__InvalidCaller());

        require(address(deployer) != address(0), VersionRegistry__ZeroAddress());

        string memory version = Versioned(address(deployer)).version();
        bytes32 versionHash = keccak256(abi.encodePacked(version));

        require(address(deployments[versionHash]) == address(0), VersionRegistry__InvalidRegistration());

        deployments[versionHash] = deployer;
        latestVersion = versionHash;

        emit VersionRegistered(versionHash, deployer);
    }

    function deprecateVersion(bytes32 versionHash) external {
        require(roleRegistry.isOwnerOrEmergencyCouncil(msg.sender), VersionRegistry__InvalidCaller());

        require(!isDeprecated[versionHash], VersionRegistry__AlreadyDeprecated());

        isDeprecated[versionHash] = true;

        emit VersionDeprecated(versionHash);
    }

    function getLatestVersion()
        external
        view
        returns (
            bytes32 versionHash,
            string memory version,
            IReserveOptimisticGovernorDeployer deployer,
            bool deprecated
        )
    {
        versionHash = latestVersion;
        deployer = deployments[versionHash];

        require(address(deployer) != address(0), VersionRegistry__Unconfigured());

        version = Versioned(address(deployer)).version();
        deprecated = isDeprecated[versionHash];
    }

    function getImplementationsForVersion(bytes32 versionHash)
        external
        view
        returns (address stakingVaultImpl, address governorImpl, address timelockImpl)
    {
        return (
            deployments[versionHash].stakingVaultImpl(),
            deployments[versionHash].governorImpl(),
            deployments[versionHash].timelockImpl()
        );
    }
}
