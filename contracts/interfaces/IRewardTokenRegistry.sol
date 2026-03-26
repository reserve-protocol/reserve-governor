// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IRewardTokenRegistry {
    function isRegistered(address token) external view returns (bool);
}
