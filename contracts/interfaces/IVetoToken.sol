// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVetoToken is IERC20, IVotes {
    /// @dev Should NOT revert for 0 amount burn
    function burn(uint256 amount) external;
}
