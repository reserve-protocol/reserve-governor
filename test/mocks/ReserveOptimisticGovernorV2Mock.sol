// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ReserveOptimisticGovernor } from "@src/governance/ReserveOptimisticGovernor.sol";

/// @dev Mock V2 implementation for upgrade testing
contract ReserveOptimisticGovernorV2Mock is ReserveOptimisticGovernor {
    function implVersion() external pure returns (uint256) {
        return 2;
    }
}
