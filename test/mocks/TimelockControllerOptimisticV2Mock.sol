// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { TimelockControllerOptimistic } from "@src/TimelockControllerOptimistic.sol";

/// @dev Mock V2 implementation for upgrade testing
contract TimelockControllerOptimisticV2Mock is TimelockControllerOptimistic {
    function implVersion() external pure returns (uint256) {
        return 2;
    }
}
