// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IVotesIntegral {
    /// @notice Returns cumulative delegated vote-seconds at a timestamp, including the current timestamp.
    function getPastVotesIntegral(address account, uint256 timepoint) external view returns (uint256);
}
