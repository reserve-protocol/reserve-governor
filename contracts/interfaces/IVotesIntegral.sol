// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IVotesIntegral {
    /// @notice Returns cumulative delegated vote-seconds plus one, or zero for untracked history.
    /// @dev Includes the current timestamp. A tracked zero integral returns one; differences of tracked values
    ///      yield exact vote-seconds. Callers must check for untracked history before subtracting.
    function getPastVotesIntegral(address account, uint256 timepoint) external view returns (uint256);
}
