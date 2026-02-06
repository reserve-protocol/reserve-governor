// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IVersioned } from "@interfaces/IVersioned.sol";

import { TimelockControllerOptimistic } from "@governance/TimelockControllerOptimistic.sol";
import { Versioned } from "@utils/Versioned.sol";

/// @dev Mock V2 implementation for upgrade testing
contract TimelockControllerOptimisticV2Mock is TimelockControllerOptimistic {
    function version() public pure override(IVersioned, Versioned) returns (string memory) {
        return "2.0.0";
    }
}
