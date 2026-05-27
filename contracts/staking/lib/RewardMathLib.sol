// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UD60x18 } from "@prb/math/src/UD60x18.sol";

library RewardMathLib {
    function powu(uint256 x, uint256 y) external pure returns (uint256) {
        return UD60x18.wrap(x).powu(y).unwrap();
    }
}
