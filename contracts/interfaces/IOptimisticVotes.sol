// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

interface IOptimisticVotes {
    function getPastOptimisticVotes(address account, uint256 timepoint) external view returns (uint256);
    function numOptimisticCheckpoints(address account) external view returns (uint32);
    function optimisticCheckpoints(address account, uint32 pos) external view returns (Checkpoints.Checkpoint208 memory);
}
