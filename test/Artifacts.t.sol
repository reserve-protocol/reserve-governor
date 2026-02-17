// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { StakingVaultDeployer } from "../contracts/artifacts/StakingVaultArtifact.sol";
import { ProposalLibDeployer } from "../contracts/artifacts/ProposalLibArtifact.sol";
import { ThrottleLibDeployer } from "../contracts/artifacts/ThrottleLibArtifact.sol";
import { ReserveOptimisticGovernorDeployer } from "../contracts/artifacts/ReserveOptimisticGovernorArtifact.sol";
import { TimelockControllerOptimisticDeployer } from "../contracts/artifacts/TimelockControllerOptimisticArtifact.sol";
import { OptimisticSelectorRegistryDeployer } from "../contracts/artifacts/OptimisticSelectorRegistryArtifact.sol";
import { ReserveOptimisticGovernorDeployerDeployer } from "../contracts/artifacts/DeployerArtifact.sol";

contract ArtifactsTest is Test {
    function test_deployStakingVault() public {
        address deployed = StakingVaultDeployer.deploy();
        assertNotEq(deployed, address(0), "StakingVault deployment failed");
        assertTrue(deployed.code.length > 0, "StakingVault has no code");
    }

    function test_deployProposalLib() public {
        address deployed = ProposalLibDeployer.deploy();
        assertNotEq(deployed, address(0), "ProposalLib deployment failed");
        assertTrue(deployed.code.length > 0, "ProposalLib has no code");
    }

    function test_deployThrottleLib() public {
        address deployed = ThrottleLibDeployer.deploy();
        assertNotEq(deployed, address(0), "ThrottleLib deployment failed");
        assertTrue(deployed.code.length > 0, "ThrottleLib has no code");
    }

    function test_deployReserveOptimisticGovernor() public {
        // First deploy both linked libraries
        address proposalLib = ProposalLibDeployer.deploy();
        address throttleLib = ThrottleLibDeployer.deploy();

        // Then deploy the governor with the linked libraries
        address deployed = ReserveOptimisticGovernorDeployer.deploy(proposalLib, throttleLib);
        assertNotEq(deployed, address(0), "ReserveOptimisticGovernor deployment failed");
        assertTrue(deployed.code.length > 0, "ReserveOptimisticGovernor has no code");
    }

    function test_deployTimelockControllerOptimistic() public {
        address deployed = TimelockControllerOptimisticDeployer.deploy();
        assertNotEq(deployed, address(0), "TimelockControllerOptimistic deployment failed");
        assertTrue(deployed.code.length > 0, "TimelockControllerOptimistic has no code");
    }

    function test_deployOptimisticSelectorRegistry() public {
        address deployed = OptimisticSelectorRegistryDeployer.deploy();
        assertNotEq(deployed, address(0), "OptimisticSelectorRegistry deployment failed");
        assertTrue(deployed.code.length > 0, "OptimisticSelectorRegistry has no code");
    }

    function test_deployReserveOptimisticGovernorDeployer() public {
        // Deploy all implementations first
        address stakingVault = StakingVaultDeployer.deploy();
        address proposalLib = ProposalLibDeployer.deploy();
        address throttleLib = ThrottleLibDeployer.deploy();
        address governor = ReserveOptimisticGovernorDeployer.deploy(proposalLib, throttleLib);
        address timelock = TimelockControllerOptimisticDeployer.deploy();
        address selectorRegistry = OptimisticSelectorRegistryDeployer.deploy();

        // Deploy the factory
        address deployer = ReserveOptimisticGovernorDeployerDeployer.deploy(
            stakingVault, governor, timelock, selectorRegistry
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
