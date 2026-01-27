// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { OptimisticSelectorRegistry } from "./OptimisticSelectorRegistry.sol";
import { ReserveOptimisticGovernor } from "./ReserveOptimisticGovernor.sol";
import { TimelockControllerOptimistic } from "./TimelockControllerOptimistic.sol";
import { CANCELLER_ROLE, IReserveGovernor, OPTIMISTIC_PROPOSER_ROLE } from "./interfaces/IReserveGovernor.sol";
import { IVetoToken } from "./interfaces/IVetoToken.sol";

struct DeploymentParams {
    IReserveGovernor.OptimisticGovernanceParams optimisticParams;
    IReserveGovernor.StandardGovernanceParams standardParams;
    IVetoToken token;
    OptimisticSelectorRegistry.SelectorData[] selectorData;
    address[] optimisticProposers;
    address[] guardians;
    uint256 timelockDelay;
}

contract Deployer {
    event ReserveGovernorSystemDeployed(
        address indexed governor, address indexed timelock, address indexed token, address OptimisticSelectorRegistry
    );

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
    function deploy(DeploymentParams calldata params)
        external
        returns (address governor, address timelock, address selectorRegistry)
    {
        // Step 1: Deploy Timelock proxy with Deployer as temporary admin
        bytes memory timelockInitData = abi.encodeCall(
            TimelockControllerOptimistic.initialize,
            (params.timelockDelay, new address[](0), new address[](0), address(this))
        );
        timelock = address(new ERC1967Proxy(timelockImpl, timelockInitData));

        // Step 2: Deploy OptimisticSelectorRegistry proxy
        selectorRegistry = Clones.clone(selectorRegistryImpl);

        // Step 3: Deploy Governor proxy
        bytes memory governorInitData = abi.encodeCall(
            ReserveOptimisticGovernor.initialize,
            (params.optimisticParams, params.standardParams, params.token, timelock, selectorRegistry)
        );
        governor = address(new ERC1967Proxy(governorImpl, governorInitData));

        // Step 4: Finalize OptimisticSelectorRegistry proxy
        OptimisticSelectorRegistry(payable(selectorRegistry)).initialize(governor, params.selectorData);

        // Step 5: Configure timelock roles
        TimelockControllerOptimistic _timelock = TimelockControllerOptimistic(payable(timelock));

        // Grant Governor the PROPOSER_ROLE
        _timelock.grantRole(_timelock.PROPOSER_ROLE(), governor);

        // Grant Governor the EXECUTOR_ROLE
        _timelock.grantRole(_timelock.EXECUTOR_ROLE(), governor);

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

        emit ReserveGovernorSystemDeployed(governor, timelock, address(params.token), selectorRegistry);
    }
}
