// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { OptimisticSelectorRegistry } from "../OptimisticSelectorRegistry.sol";
import { IReserveOptimisticGovernor } from "./IReserveOptimisticGovernor.sol";
import { IVetoToken } from "./IVetoToken.sol";

interface IReserveOptimisticGovernorDeployer {
    // === Events ===

    event ReserveOptimisticGovernorSystemDeployed(
        address indexed governor, address indexed timelock, address indexed token, address OptimisticSelectorRegistry
    );

    // === Data ===

    struct DeploymentParams {
        IReserveOptimisticGovernor.OptimisticGovernanceParams optimisticParams;
        IReserveOptimisticGovernor.StandardGovernanceParams standardParams;
        IVetoToken token;
        OptimisticSelectorRegistry.SelectorData[] selectorData;
        address[] optimisticProposers;
        address[] guardians;
        uint256 timelockDelay;
    }

    // === Functions ===

    function deploy(DeploymentParams calldata params, bytes32 deploymentNonce)
        external
        returns (address governor, address timelock, address selectorRegistry);
}
