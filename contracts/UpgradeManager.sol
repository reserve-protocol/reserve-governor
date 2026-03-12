// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ReserveOptimisticGovernanceVersionRegistry } from "./VersionRegistry.sol";

interface IUUPSProxy {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract ReserveOptimisticGovernanceUpgradeManager {
    error UpgradeManager__UnauthorizedCaller(address caller);
    error UpgradeManager__InvalidComponent(address component);
    error UpgradeManager__VersionDeprecated(bytes32 versionHash);

    event SystemUpgraded(
        bytes32 indexed versionHash, address stakingVaultImpl, address governorImpl, address timelockImpl
    );

    ReserveOptimisticGovernanceVersionRegistry public immutable versionRegistry;
    address public immutable stakingVault;
    address public immutable governor;
    address public immutable timelock;

    constructor(address _versionRegistry, address _stakingVault, address _governor, address _timelock) {
        require(_versionRegistry != address(0), UpgradeManager__InvalidComponent(_versionRegistry));

        // _stakingVault can be address(0)
        require(_governor != address(0), UpgradeManager__InvalidComponent(_governor));
        require(_timelock != address(0), UpgradeManager__InvalidComponent(_timelock));

        versionRegistry = ReserveOptimisticGovernanceVersionRegistry(_versionRegistry);
        stakingVault = _stakingVault;
        governor = _governor;
        timelock = _timelock;
    }

    function upgradeToVersion(bytes32 versionHash) external {
        require(msg.sender == timelock, UpgradeManager__UnauthorizedCaller(msg.sender));

        require(!versionRegistry.isDeprecated(versionHash), UpgradeManager__VersionDeprecated(versionHash));

        (address stakingVaultImpl, address governorImpl, address timelockImpl) =
            versionRegistry.getImplementationsForVersion(versionHash);

        if (stakingVault != address(0)) {
            IUUPSProxy(stakingVault).upgradeToAndCall(stakingVaultImpl, "");
        } else {
            stakingVaultImpl = address(0);
        }

        IUUPSProxy(timelock).upgradeToAndCall(timelockImpl, "");
        IUUPSProxy(governor).upgradeToAndCall(governorImpl, "");

        emit SystemUpgraded(versionHash, stakingVaultImpl, governorImpl, timelockImpl);
    }
}
