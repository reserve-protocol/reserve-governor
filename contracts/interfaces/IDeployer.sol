// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IOptimisticSelectorRegistry } from "./IOptimisticSelectorRegistry.sol";
import { IReserveOptimisticGovernor } from "./IReserveOptimisticGovernor.sol";

interface IReserveOptimisticGovernorDeployer {
    // === Events ===

    event ReserveOptimisticGovernorSystemDeployed(
        address indexed stakingVault,
        address indexed governor,
        address indexed timelock,
        address optimisticSelectorRegistry
    );

    // === Data ===

    struct BaseDeploymentParams {
        IReserveOptimisticGovernor.OptimisticGovernanceParams optimisticParams;
        IReserveOptimisticGovernor.StandardGovernanceParams standardParams;
        IOptimisticSelectorRegistry.SelectorData[] selectorData;
        address[] optimisticProposers;
        address[] guardians;
        uint256 timelockDelay; // {s}
    }

    struct NewStakingVaultParams {
        IERC20Metadata underlying; // MUST have strong value relationship to the system being governed
        address[] rewardTokens;
        uint256 rewardHalfLife; // {s}
        uint256 unstakingDelay; // {s}
    }

    // === Functions ===

    function deployWithNewStakingVault(
        BaseDeploymentParams calldata baseParams,
        NewStakingVaultParams calldata newStakingVaultParams,
        bytes32 deploymentNonce
    ) external returns (address stakingVault, address governor, address timelock, address selectorRegistry);

    function deployWithExistingStakingVault(
        BaseDeploymentParams calldata baseParams,
        address existingStakingVault,
        bytes32 deploymentNonce
    ) external returns (address stakingVault, address governor, address timelock, address selectorRegistry);
}
