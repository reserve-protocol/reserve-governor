// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { TimelockControllerOptimistic } from "@governance/TimelockControllerOptimistic.sol";

/// @dev Mock V2 implementation for upgrade testing
contract TimelockControllerOptimisticV2Mock is TimelockControllerOptimistic {
    function version() public pure override returns (string memory) {
        return "2.0.0";
    }
}
