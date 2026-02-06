// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IVersioned } from "../interfaces/IVersioned.sol";

// This value should be updated on each release
string constant VERSION = "1.0.0";

/**
 * @title Versioned
 * @notice A mix-in to track semantic versioning uniformly across contracts.
 */
abstract contract Versioned is IVersioned {
    function version() public pure virtual returns (string memory) {
        return VERSION;
    }
}
