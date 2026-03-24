// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { IRoleRegistry } from "@interfaces/IRoleRegistry.sol";
import { ReserveOptimisticGovernanceVersionRegistry } from "@src/VersionRegistry.sol";
import { OptimisticSelectorRegistryDeployer } from "@src/artifacts/OptimisticSelectorRegistryDeployer.sol";
import { ProposalLibDeployer } from "@src/artifacts/ProposalLibDeployer.sol";
import { ReserveOptimisticGovernorDeployer } from "@src/artifacts/ReserveOptimisticGovernorDeployer.sol";
import {
    ReserveOptimisticGovernorDeployerDeployer
} from "@src/artifacts/ReserveOptimisticGovernorDeployerDeployer.sol";
import { StakingVaultDeployer } from "@src/artifacts/StakingVaultDeployer.sol";
import { ThrottleLibDeployer } from "@src/artifacts/ThrottleLibDeployer.sol";
import { TimelockControllerOptimisticDeployer } from "@src/artifacts/TimelockControllerOptimisticDeployer.sol";
import { RewardTokenRegistry } from "@staking/RewardTokenRegistry.sol";

import { MockRoleRegistry } from "@mocks/MockRoleRegistry.sol";

contract ArtifactsTest is Test {
    function _salt(string memory label) internal pure returns (bytes32) {
        return keccak256(bytes(label));
    }

    function test_deployStakingVault() public {
        address deployed = StakingVaultDeployer.deploy(_salt("StakingVault"));
        assertNotEq(deployed, address(0), "StakingVault deployment failed");
        assertTrue(deployed.code.length > 0, "StakingVault has no code");
    }

    function test_deployProposalLib() public {
        address deployed = ProposalLibDeployer.deploy(_salt("ProposalLib"));
        assertNotEq(deployed, address(0), "ProposalLib deployment failed");
        assertTrue(deployed.code.length > 0, "ProposalLib has no code");
    }

    function test_deployThrottleLib() public {
        address deployed = ThrottleLibDeployer.deploy(_salt("ThrottleLib"));
        assertNotEq(deployed, address(0), "ThrottleLib deployment failed");
        assertTrue(deployed.code.length > 0, "ThrottleLib has no code");
    }

    function test_deployReserveOptimisticGovernor() public {
        address deployed = ReserveOptimisticGovernorDeployer.deploy(_salt("ReserveOptimisticGovernor"));
        assertNotEq(deployed, address(0), "ReserveOptimisticGovernor deployment failed");
        assertTrue(deployed.code.length > 0, "ReserveOptimisticGovernor has no code");
    }

    function test_deployTimelockControllerOptimistic() public {
        address deployed = TimelockControllerOptimisticDeployer.deploy(_salt("TimelockControllerOptimistic"));
        assertNotEq(deployed, address(0), "TimelockControllerOptimistic deployment failed");
        assertTrue(deployed.code.length > 0, "TimelockControllerOptimistic has no code");
    }

    function test_deployOptimisticSelectorRegistry() public {
        address deployed = OptimisticSelectorRegistryDeployer.deploy(_salt("OptimisticSelectorRegistry"));
        assertNotEq(deployed, address(0), "OptimisticSelectorRegistry deployment failed");
        assertTrue(deployed.code.length > 0, "OptimisticSelectorRegistry has no code");
    }

    function test_deployReserveOptimisticGovernorDeployer() public {
        // Deploy all implementations first
        address stakingVault = StakingVaultDeployer.deploy(_salt("StakingVaultImpl"));
        address governor = ReserveOptimisticGovernorDeployer.deploy(_salt("GovernorImpl"));
        address timelock = TimelockControllerOptimisticDeployer.deploy(_salt("TimelockImpl"));
        address selectorRegistry = OptimisticSelectorRegistryDeployer.deploy(_salt("SelectorRegistryImpl"));
        ReserveOptimisticGovernanceVersionRegistry versionRegistry =
            new ReserveOptimisticGovernanceVersionRegistry(IRoleRegistry(address(1)));
        RewardTokenRegistry rewardTokenRegistry = new RewardTokenRegistry(IRoleRegistry(address(1)));

        // Deploy the factory
        address deployer = ReserveOptimisticGovernorDeployerDeployer.deploy(
            address(versionRegistry),
            address(rewardTokenRegistry),
            stakingVault,
            governor,
            timelock,
            selectorRegistry,
            _salt("ReserveOptimisticGovernorDeployer")
        );

        assertNotEq(deployer, address(0), "ReserveOptimisticGovernorDeployer deployment failed");
        assertTrue(deployer.code.length > 0, "ReserveOptimisticGovernorDeployer has no code");
    }

    function test_deployWithSalt() public {
        bytes32 salt1 = keccak256("test-salt-1");
        bytes32 salt2 = keccak256("test-salt-2");

        address deployed1 = StakingVaultDeployer.deploy(salt1);
        assertNotEq(deployed1, address(0), "StakingVault deployment with salt1 failed");

        address deployed2 = StakingVaultDeployer.deploy(salt2);
        assertNotEq(deployed2, address(0), "StakingVault deployment with salt2 failed");

        // Different salts should produce different addresses
        assertNotEq(deployed1, deployed2, "Same address for different salts");
    }
}
