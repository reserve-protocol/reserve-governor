// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { StakingVault } from "@staking/StakingVault.sol";

/// @dev Mock V2 implementation for upgrade testing
contract StakingVaultV2Mock is StakingVault {
    function version() public pure override returns (string memory) {
        return "2.0.0";
    }
}
