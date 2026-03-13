// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { ReserveOptimisticGovernanceUpgradeManager } from "../UpgradeManager.sol";

abstract contract UpgradeControlled is Initializable {
    error UpgradeControlled__InvalidUpgradeManager(address upgradeManager);
    error UpgradeControlled__UnauthorizedCaller(address caller);

    ReserveOptimisticGovernanceUpgradeManager public upgradeManager;

    modifier onlyUpgradeManager() {
        require(msg.sender == address(upgradeManager), UpgradeControlled__UnauthorizedCaller(msg.sender));
        _;
    }

    function __UpgradeControlled_init(address _upgradeManager) internal onlyInitializing {
        require(_upgradeManager != address(0), UpgradeControlled__InvalidUpgradeManager(_upgradeManager));

        upgradeManager = ReserveOptimisticGovernanceUpgradeManager(_upgradeManager);
    }
}
