// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";

contract MockRoleRegistry is IRoleRegistry {
    mapping(address account => bool isConfiguredOwner) private owners;
    mapping(address account => bool isConfiguredEmergencyCouncil) private emergencyCouncil;

    constructor(address initialOwner) {
        owners[initialOwner] = true;
    }

    function setOwner(address account, bool isOwner_) external {
        owners[account] = isOwner_;
    }

    function setEmergencyCouncil(address account, bool isEmergencyCouncil) external {
        emergencyCouncil[account] = isEmergencyCouncil;
    }

    function isOwner(address account) external view returns (bool) {
        return owners[account];
    }

    function isOwnerOrEmergencyCouncil(address account) external view returns (bool) {
        return owners[account] || emergencyCouncil[account];
    }
}
