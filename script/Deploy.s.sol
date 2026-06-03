// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console2 } from "forge-std/Script.sol";

import { OptimisticSelectorRegistry } from "@governance/OptimisticSelectorRegistry.sol";
import { ReserveOptimisticGovernor } from "@governance/ReserveOptimisticGovernor.sol";
import { TimelockControllerOptimistic } from "@governance/TimelockControllerOptimistic.sol";
import { ReserveOptimisticGovernorDeployer } from "@src/Deployer.sol";
import { Guardian } from "@src/Guardian.sol";
import { StakingVault } from "@src/staking/StakingVault.sol";

string constant junkSeedPhrase = "test test test test test test test test test test test junk";

enum DeploymentMode {
    Production,
    Testing
}

contract DeployScript is Script {
    error DeployScript__InvalidChainId();

    string seedPhrase = block.chainid != 31337 ? vm.readFile(".seed") : junkSeedPhrase;
    uint256 privateKey = vm.deriveKey(seedPhrase, 0);
    address walletAddress = vm.rememberKey(privateKey);

    // Deployment Mode: Production or Testing
    // Change this before deployment!
    DeploymentMode public deploymentMode = DeploymentMode.Production;

    function run()
        external
        returns (
            address stakingVaultImpl,
            address governorImpl,
            address timelockImpl,
            address selectorRegistryImpl,
            address deployer
        )
    {
        console2.log("----- START -----");
        console2.log("Mode:", deploymentMode == DeploymentMode.Production ? "Production" : "Testing");
        console2.log("Chain ID:", block.chainid);
        console2.log("Wallet Address:", walletAddress);

        address guardian = _getGuardian();
        address versionRegistry = _getVersionRegistry();
        address rewardTokenRegistry = _getRewardTokenRegistry();
        address trustedFillerRegistry = _getTrustedFillerRegistry();

        console2.log("Guardian:", guardian);
        console2.log("ReserveOptimisticGovernorStakingVaultVersionRegistry:", versionRegistry);
        console2.log("RewardTokenRegistry:", rewardTokenRegistry);
        console2.log("TrustedFillerRegistry:", trustedFillerRegistry);
        console2.log("");

        vm.startBroadcast(privateKey);

        // Deploy implementations
        stakingVaultImpl = address(new StakingVault());
        governorImpl = address(new ReserveOptimisticGovernor());
        timelockImpl = address(new TimelockControllerOptimistic());
        selectorRegistryImpl = address(new OptimisticSelectorRegistry());

        // Deploy Deployer
        deployer = address(
            new ReserveOptimisticGovernorDeployer(
                versionRegistry,
                rewardTokenRegistry,
                trustedFillerRegistry,
                guardian,
                stakingVaultImpl,
                governorImpl,
                timelockImpl,
                selectorRegistryImpl
            )
        );

        vm.stopBroadcast();

        console2.log("StakingVault:", stakingVaultImpl);
        console2.log("ReserveOptimisticGovernor:", governorImpl);
        console2.log("TimelockControllerOptimistic:", timelockImpl);
        console2.log("OptimisticSelectorRegistry:", selectorRegistryImpl);
        console2.log("ReserveOptimisticGovernorDeployer:", deployer);
        console2.log("----- DONE -----");
    }

    function _getGuardian() internal view returns (address) {
        // TODO Guardian deployments

        if (block.chainid == 1 || block.chainid == 31337) {
            return 0x0000000000000000000000000000000000000000;
        }

        if (block.chainid == 8453) {
            return 0x0000000000000000000000000000000000000000;
        }

        if (block.chainid == 56) {
            return 0x0000000000000000000000000000000000000000;
        }

        revert DeployScript__InvalidChainId();
    }

    function _getVersionRegistry() internal view returns (address) {
        // TODO ReserveOptimisticGovernanceVersionRegistry deployments

        if (block.chainid == 1 || block.chainid == 31337) {
            return 0x0000000000000000000000000000000000000000;
        }

        if (block.chainid == 8453) {
            return 0x0000000000000000000000000000000000000000;
        }

        if (block.chainid == 56) {
            return 0x0000000000000000000000000000000000000000;
        }

        revert DeployScript__InvalidChainId();
    }

    function _getRewardTokenRegistry() internal view returns (address) {
        // TODO RewardTokenRegistry deployments

        if (block.chainid == 1 || block.chainid == 31337) {
            return 0x0000000000000000000000000000000000000000;
        }

        if (block.chainid == 8453) {
            return 0x0000000000000000000000000000000000000000;
        }

        if (block.chainid == 56) {
            return 0x0000000000000000000000000000000000000000;
        }

        revert DeployScript__InvalidChainId();
    }

    function _getTrustedFillerRegistry() internal view returns (address) {
        if (block.chainid == 1 || block.chainid == 31337) {
            return 0x279ccF56441fC74f1aAC39E7faC165Dec5A88B3A;
        }

        if (block.chainid == 8453) {
            return 0x72DB5f49D0599C314E2f2FEDf6Fe33E1bA6C7A18;
        }

        if (block.chainid == 56) {
            return 0x08424d7C52bf9edd4070701591Ea3FE6dca6449B;
        }

        revert DeployScript__InvalidChainId();
    }
}
