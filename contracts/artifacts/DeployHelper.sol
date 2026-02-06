// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library DeployHelper {
    error DeploymentFailed();

    function deploy(bytes memory initcode, bytes32 salt) internal returns (address deployed) {
        assembly {
            deployed := create2(0, add(initcode, 0x20), mload(initcode), salt)
        }
        if (deployed == address(0)) revert DeploymentFailed();
    }

    function deploy(bytes memory initcode) internal returns (address) {
        return deploy(initcode, bytes32(0));
    }
}
