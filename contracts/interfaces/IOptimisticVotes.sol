// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC6372 } from "@openzeppelin/contracts/interfaces/IERC6372.sol";
import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

interface IOptimisticVotes is IERC6372 {
    event OptimisticDelegateChanged(
        address indexed delegator, address indexed fromDelegate, address indexed toDelegate
    );
    event OptimisticDelegateVotesChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes);

    function getOptimisticVotes(address account) external view returns (uint256);
    function getPastOptimisticVotes(address account, uint256 timepoint) external view returns (uint256);
    function getPastOptimisticTotalSupply(uint256 timepoint) external view returns (uint256);
    function optimisticDelegates(address account) external view returns (address);
    function delegateOptimistic(address delegatee) external;
    function delegateOptimisticBySig(address delegatee, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s)
        external;
    function numOptimisticCheckpoints(address account) external view returns (uint32);
    function optimisticCheckpoints(address account, uint32 pos) external view returns (Checkpoints.Checkpoint208 memory);
}
