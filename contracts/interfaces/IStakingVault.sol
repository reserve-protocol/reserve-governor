// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IVersioned } from "./IVersioned.sol";

interface IStakingVault is IERC20, IVotes, IVersioned {
    /// @dev Should NOT revert for 0 amount burn
    function burn(uint256 amount) external;

    function addRewardToken(address rewardToken) external;

    function removeRewardToken(address rewardToken) external;

    function asset() external view returns (address);

    function owner() external view returns (address);

    function rewardRatio() external view returns (uint256);

    function unstakingDelay() external view returns (uint256);
}
