// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract ReserveGovernor is ERC20Upgradeable {
    function initialize() public initializer {
        __ERC20_init("Reserve Governor", "RG");
    }
}
