// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAverageVotes {
    error AverageVotes__InvalidTimeRange();

    /// @notice Returns average delegated votes over [start, end), rounded down.
    /// @dev Divides by the full requested interval, including time before activation, which contributes zero.
    ///      Equal bounds return zero; start > end reverts.
    ///      Supports the current timestamp and checked extrapolation into the future.
    function getPastAverageVotes(address account, uint256 start, uint256 end) external view returns (uint256);

    /// @notice Returns the supply-seconds voting share over [start, end), as a D18 fraction.
    function getPastVoteShare(address account, uint256 start, uint256 end) external view returns (uint256);
}
