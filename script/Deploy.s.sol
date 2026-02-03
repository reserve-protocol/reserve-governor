// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console2 } from "forge-std/Script.sol";

import { ReserveOptimisticGovernorDeployer } from "@src/Deployer.sol";
import { OptimisticSelectorRegistry } from "@src/governance/OptimisticSelectorRegistry.sol";
import { ReserveOptimisticGovernor } from "@src/governance/ReserveOptimisticGovernor.sol";
import { TimelockControllerOptimistic } from "@src/governance/TimelockControllerOptimistic.sol";

string constant junkSeedPhrase = "test test test test test test test test test test test junk";

enum DeploymentMode {
    Production,
    Testing
}

contract DeployScript is Script {
    string seedPhrase = block.chainid != 31337 ? vm.readFile(".seed") : junkSeedPhrase;
    uint256 privateKey = vm.deriveKey(seedPhrase, 0);
    address walletAddress = vm.rememberKey(privateKey);

    // Deployment Mode: Production or Testing
    // Change this before deployment!
    DeploymentMode public deploymentMode = DeploymentMode.Production;

    function run()
        external
        returns (address deployer, address governorImpl, address timelockImpl, address selectorRegistryImpl)
    {
        console2.log("----- START -----");
        console2.log("Mode:", deploymentMode == DeploymentMode.Production ? "Production" : "Testing");
        console2.log("Chain ID:", block.chainid);
        console2.log("Wallet Address:", walletAddress);
        console2.log("");

        vm.startBroadcast(privateKey);

        // Deploy implementations
        governorImpl = address(new ReserveOptimisticGovernor());
        timelockImpl = address(new TimelockControllerOptimistic());
        selectorRegistryImpl = address(new OptimisticSelectorRegistry());

        // Deploy Deployer
        deployer = address(new ReserveOptimisticGovernorDeployer(governorImpl, timelockImpl, selectorRegistryImpl));

        vm.stopBroadcast();

        console2.log("ReserveOptimisticGovernor:", governorImpl);
        console2.log("TimelockControllerOptimistic:", timelockImpl);
        console2.log("OptimisticSelectorRegistry:", selectorRegistryImpl);
        console2.log("ReserveOptimisticGovernorDeployer:", deployer);
        console2.log("----- DONE -----");
    }
}
