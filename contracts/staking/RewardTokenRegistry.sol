// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { IRewardTokenRegistry } from "../interfaces/IRewardTokenRegistry.sol";
import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";

/**
 * @title RewardTokenRegistry
 * @author akshatmittal, julianmrodri, pmckelvy1, tbrent
 * @notice Singleton registry of reward tokens for StakingVaults
 */
contract RewardTokenRegistry is IRewardTokenRegistry {
    using EnumerableSet for EnumerableSet.AddressSet;

    error RewardTokenRegistry__InvalidCaller();
    error RewardTokenRegistry__ZeroAddress();
    error RewardTokenRegistry__RewardAlreadyRegistered();
    error RewardTokenRegistry__RewardNotRegistered();

    event RewardTokenRegistered(address indexed rewardToken);
    event RewardTokenUnregistered(address indexed rewardToken);

    IRoleRegistry public immutable roleRegistry;

    EnumerableSet.AddressSet private _rewardTokens;

    constructor(IRoleRegistry _roleRegistry) {
        require(address(_roleRegistry) != address(0), RewardTokenRegistry__ZeroAddress());

        roleRegistry = _roleRegistry;
    }

    function registerRewardToken(address rewardToken) external {
        require(roleRegistry.isOwner(msg.sender), RewardTokenRegistry__InvalidCaller());
        require(rewardToken != address(0), RewardTokenRegistry__ZeroAddress());
        require(_rewardTokens.add(rewardToken), RewardTokenRegistry__RewardAlreadyRegistered());

        emit RewardTokenRegistered(rewardToken);
    }

    /// @dev Assumption: RoleRegistry will not needlessly unregister + re-register to grief accounting in StakingVaults
    function unregisterRewardToken(address rewardToken) external {
        require(roleRegistry.isOwnerOrEmergencyCouncil(msg.sender), RewardTokenRegistry__InvalidCaller());
        require(_rewardTokens.remove(rewardToken), RewardTokenRegistry__RewardNotRegistered());

        emit RewardTokenUnregistered(rewardToken);
    }

    function rewardTokens() external view returns (address[] memory) {
        return _rewardTokens.values();
    }

    function isRegistered(address rewardToken) external view returns (bool) {
        return _rewardTokens.contains(rewardToken);
    }
}
