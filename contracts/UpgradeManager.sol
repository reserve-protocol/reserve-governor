// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IReserveOptimisticGovernor } from "./interfaces/IReserveOptimisticGovernor.sol";

import { ReserveOptimisticGovernanceVersionRegistry } from "./VersionRegistry.sol";
import { Versioned } from "./utils/Versioned.sol";

interface IUUPSProxy {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract ReserveOptimisticGovernanceUpgradeManager {
    error UpgradeManager__UnauthorizedCaller(address caller);
    error UpgradeManager__InvalidComponent(address component);
    error UpgradeManager__VersionDeprecated(bytes32 versionHash);
    error UpgradeManager__OldStakingVaultVersion(address stakingVault);

    event SystemUpgraded(
        bytes32 indexed versionHash, address stakingVaultImpl, address governorImpl, address timelockImpl
    );

    ReserveOptimisticGovernanceVersionRegistry public immutable versionRegistry;
    address public immutable stakingVault;
    address public immutable governor;
    address public immutable timelock;

    constructor(address _versionRegistry, address _stakingVault, address _governor, address _timelock) {
        require(_versionRegistry != address(0), UpgradeManager__InvalidComponent(_versionRegistry));
        require(_governor != address(0), UpgradeManager__InvalidComponent(_governor));
        require(_timelock != address(0), UpgradeManager__InvalidComponent(_timelock));

        versionRegistry = ReserveOptimisticGovernanceVersionRegistry(_versionRegistry);
        stakingVault = _stakingVault;
        governor = _governor;
        timelock = _timelock;
    }

    function upgradeToLatestVersion() external {
        require(msg.sender == timelock, UpgradeManager__UnauthorizedCaller(msg.sender));

        (bytes32 versionHash,,, bool deprecated) = versionRegistry.getLatestVersion();

        require(!deprecated, UpgradeManager__VersionDeprecated(versionHash));
        // VersionRegistry is assumed to be honest administration that will not grief the latest release

        (address stakingVaultImpl, address governorImpl, address timelockImpl) =
            versionRegistry.getImplementationsForVersion(versionHash);

        if (stakingVault != address(0)) {
            IUUPSProxy(stakingVault).upgradeToAndCall(stakingVaultImpl, "");
        } else {
            stakingVaultImpl = address(0);

            // governors/timelocks can only be upgraded once their associated StakingVault is already on latest
            address associatedStakingVault = address(IReserveOptimisticGovernor(governor).token());
            require(
                keccak256(abi.encodePacked(Versioned(associatedStakingVault).version())) == versionHash,
                UpgradeManager__OldStakingVaultVersion(associatedStakingVault)
            );
        }

        IUUPSProxy(timelock).upgradeToAndCall(timelockImpl, "");
        IUUPSProxy(governor).upgradeToAndCall(governorImpl, "");

        emit SystemUpgraded(versionHash, stakingVaultImpl, governorImpl, timelockImpl);
    }
}
