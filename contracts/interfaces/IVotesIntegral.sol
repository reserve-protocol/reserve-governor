// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IVotesIntegral {
    /// @notice Returns cumulative delegated vote-seconds since integral activation.
    /// @dev Includes the current timestamp. History at or before activation contributes zero.
    function getPastVotesIntegral(address account, uint256 timepoint) external view returns (uint256);
}
