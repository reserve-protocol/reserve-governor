// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";

contract MockRoleRegistry is IRoleRegistry {
    mapping(address account => bool isConfiguredOwner) private owners;
    mapping(address account => bool isConfiguredGuardian) private guardians;

    constructor(address initialOwner) {
        owners[initialOwner] = true;
    }

    function setOwner(address account, bool isOwner_) external {
        owners[account] = isOwner_;
    }

    function setGuardian(address account, bool isGuardian) external {
        guardians[account] = isGuardian;
    }

    function isOwner(address account) external view returns (bool) {
        return owners[account];
    }

    function isOwnerOrGuardian(address account) external view returns (bool) {
        return owners[account] || guardians[account];
    }
}
