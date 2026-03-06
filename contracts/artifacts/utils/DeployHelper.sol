// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

library DeployHelper {
    function deploy(bytes memory initcode, bytes32 salt) internal returns (address contractAddress) {
        assembly ("memory-safe") {
            contractAddress := create2(callvalue(), add(initcode, 32), mload(initcode), salt)
            if iszero(contractAddress) {
                let ptr := mload(0x40)
                let errorSize := returndatasize()
                returndatacopy(ptr, 0, errorSize)
                revert(ptr, errorSize)
            }
        }
    }

    function deploy(bytes memory initcode) internal returns (address contractAddress) {
        contractAddress = deploy(initcode, bytes32(0));
    }

    /// @dev Deploys a library using CREATE2 with zero salt.
    ///      If the library is already deployed (duplicate across contracts), returns the existing address.
    function deployLibrary(bytes memory initcode) internal returns (address contractAddress) {
        bytes32 salt = bytes32(0);
        contractAddress = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(initcode))))));
        if (contractAddress.code.length > 0) return contractAddress;
        contractAddress = deploy(initcode, salt);
    }
}
