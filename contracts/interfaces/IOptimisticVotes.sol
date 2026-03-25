// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOptimisticVotes {
    function getPastOptimisticVotes(address account, uint256 timepoint) external view returns (uint256);
}
