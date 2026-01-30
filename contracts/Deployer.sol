// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { OptimisticSelectorRegistry } from "./OptimisticSelectorRegistry.sol";
import { ReserveOptimisticGovernor } from "./ReserveOptimisticGovernor.sol";
import { TimelockControllerOptimistic } from "./TimelockControllerOptimistic.sol";
import { IReserveOptimisticGovernorDeployer } from "./interfaces/IDeployer.sol";
import {
    CANCELLER_ROLE,
    EXECUTOR_ROLE,
    IReserveOptimisticGovernor,
    OPTIMISTIC_PROPOSER_ROLE,
    PROPOSER_ROLE
} from "./interfaces/IReserveOptimisticGovernor.sol";

contract ReserveOptimisticGovernorDeployer is IReserveOptimisticGovernorDeployer {
    address public immutable governorImpl;
    address public immutable timelockImpl;
    address public immutable selectorRegistryImpl;

    constructor(address _governorImpl, address _timelockImpl, address _selectorRegistryImpl) {
        governorImpl = _governorImpl;
        timelockImpl = _timelockImpl;
        selectorRegistryImpl = _selectorRegistryImpl;
    }

    /// @notice Deploy a complete Reserve Governor system with UUPS proxies
    /// @return governor The deployed Governor proxy address
    /// @return timelock The deployed Timelock proxy address
    function deploy(DeploymentParams calldata params, bytes32 deploymentNonce)
        external
        returns (address governor, address timelock, address selectorRegistry)
    {
        bytes32 deploymentSalt = keccak256(abi.encode(msg.sender, params, deploymentNonce));
        
        // Step 0: Confirm token is burnable
        params.token.burn(0);

        // Step 1: Deploy Timelock proxy with Deployer as temporary admin
        bytes memory timelockInitData = abi.encodeCall(
            TimelockControllerOptimistic.initialize,
            (params.timelockDelay, new address[](0), new address[](0), address(this))
        );
        timelock = address(new ERC1967Proxy{salt: deploymentSalt}(timelockImpl, timelockInitData));

        // Step 2: Deploy OptimisticSelectorRegistry proxy
        selectorRegistry = Clones.cloneDeterministic(selectorRegistryImpl, deploymentSalt);

        // Step 3: Deploy Governor proxy
        bytes memory governorInitData = abi.encodeCall(
            ReserveOptimisticGovernor.initialize,
            (params.optimisticParams, params.standardParams, params.token, timelock, selectorRegistry)
        );
        governor = address(new ERC1967Proxy{salt: deploymentSalt}(governorImpl, governorInitData));

        // Step 4: Finalize OptimisticSelectorRegistry proxy
        OptimisticSelectorRegistry(payable(selectorRegistry)).initialize(governor, params.selectorData);

        // Step 5: Configure timelock roles
        TimelockControllerOptimistic _timelock = TimelockControllerOptimistic(payable(timelock));

        // Grant Governor the PROPOSER_ROLE
        _timelock.grantRole(PROPOSER_ROLE, governor);

        // Grant Governor the EXECUTOR_ROLE
        _timelock.grantRole(EXECUTOR_ROLE, governor);

        // Grant Governor the CANCELLER_ROLE
        _timelock.grantRole(CANCELLER_ROLE, governor);

        // Grant CANCELLER_ROLE to all guardians
        for (uint256 i = 0; i < params.guardians.length; ++i) {
            _timelock.grantRole(CANCELLER_ROLE, params.guardians[i]);
        }

        // Grant OPTIMISTIC_PROPOSER_ROLE to all optimistic proposers
        for (uint256 i = 0; i < params.optimisticProposers.length; ++i) {
            _timelock.grantRole(OPTIMISTIC_PROPOSER_ROLE, params.optimisticProposers[i]);
        }

        // Step 6: Renounce admin role
        _timelock.renounceRole(_timelock.DEFAULT_ADMIN_ROLE(), address(this));

        emit ReserveOptimisticGovernorSystemDeployed(governor, timelock, address(params.token), selectorRegistry);
    }
}
