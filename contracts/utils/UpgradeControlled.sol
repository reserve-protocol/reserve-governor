// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ReserveOptimisticGovernanceUpgradeManager } from "../UpgradeManager.sol";

abstract contract UpgradeControlled {
    error UpgradeControlled__InvalidUpgradeManager(address upgradeManager);
    error UpgradeControlled__UnauthorizedCaller(address caller);
    error UpgradeControlled__UpgradeManagerAlreadySet();

    ReserveOptimisticGovernanceUpgradeManager public upgradeManager;

    modifier onlyUpgradeManager() {
        require(msg.sender == address(upgradeManager), UpgradeControlled__UnauthorizedCaller(msg.sender));
        _;
    }

    function setUpgradeManager(address _upgradeManager) external {
        require(_upgradeManager != address(0), UpgradeControlled__InvalidUpgradeManager(_upgradeManager));

        require(address(upgradeManager) == address(0), UpgradeControlled__UpgradeManagerAlreadySet());
        upgradeManager = ReserveOptimisticGovernanceUpgradeManager(_upgradeManager);
    }
}
