// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    CANCELLER_ROLE,
    DEFAULT_REWARD_PERIOD,
    DEFAULT_UNSTAKING_DELAY,
    EXECUTOR_ROLE,
    OPTIMISTIC_PROPOSER_ROLE,
    PROPOSER_ROLE
} from "./interfaces/Constants.sol";
import { IReserveOptimisticGovernorDeployer } from "./interfaces/IDeployer.sol";

import { OptimisticSelectorRegistry } from "./governance/OptimisticSelectorRegistry.sol";
import { ReserveOptimisticGovernor } from "./governance/ReserveOptimisticGovernor.sol";
import { TimelockControllerOptimistic } from "./governance/TimelockControllerOptimistic.sol";
import { StakingVault } from "./staking/StakingVault.sol";

contract ReserveOptimisticGovernorDeployer is IReserveOptimisticGovernorDeployer {
    address public immutable stakingVaultImpl;
    address public immutable governorImpl;
    address public immutable timelockImpl;
    address public immutable selectorRegistryImpl;

    constructor(
        address _stakingVaultImpl,
        address _governorImpl,
        address _timelockImpl,
        address _selectorRegistryImpl
    ) {
        stakingVaultImpl = _stakingVaultImpl;
        governorImpl = _governorImpl;
        timelockImpl = _timelockImpl;
        selectorRegistryImpl = _selectorRegistryImpl;
    }

    /// @notice Deploy a complete Reserve Governor system via proxies
    /// @param params.optimisticParams.vetoPeriod {s} Veto period
    /// @param params.optimisticParams.vetoThreshold D18{1} Fraction of staked supply required to start confirmation
    /// @param params.optimisticParams.slashingPercentage D18{1} Fraction of staked tokens to be slashed
    /// @param params.optimisticParams.numParallelProposals Number of optimistic proposals that can be live in parallel
    /// @param params.standardParams.votingDelay {s} Delay before snapshot
    /// @param params.standardParams.votingPeriod {s} Voting period
    /// @param params.standardParams.voteExtension {s} Time extension for late quorum
    /// @param params.standardParams.proposalThreshold D18{1} Fraction of staked supply required to propose
    /// @param params.standardParams.quorumNumerator D18{1} Fraction of staked supply required to reach quorum
    /// @param params.underlying The underlying token to be vote-locked
    /// @param params.optimisticProposers Addresses that can propose optimistic proposals
    /// @param params.guardians Addresses that can cancel proposals
    /// @param params.timelockDelay {s} Delay before timelock can execute
    /// @return stakingVault The deployed StakingVault proxy address
    /// @return governor The deployed Governor proxy address
    /// @return timelock The deployed Timelock proxy address
    /// @return selectorRegistry The deployed OptimisticSelectorRegistry proxy address
    function deploy(DeploymentParams calldata params, bytes32 deploymentNonce)
        external
        returns (address stakingVault, address governor, address timelock, address selectorRegistry)
    {
        bytes32 deploymentSalt = keccak256(abi.encode(msg.sender, params, deploymentNonce));

        // Step 1: Deploy StakingVault proxy
        bytes memory stakingVaultInitData = abi.encodeCall(
            StakingVault.initialize,
            (
                string.concat("Vote-Locked ", params.underlying.name()),
                string.concat("vl", params.underlying.symbol()),
                params.underlying,
                address(this),
                DEFAULT_REWARD_PERIOD,
                DEFAULT_UNSTAKING_DELAY
            )
        );
        stakingVault = address(new ERC1967Proxy{ salt: deploymentSalt }(stakingVaultImpl, stakingVaultInitData));

        // Step 2: Deploy Timelock proxy with Deployer as temporary admin
        bytes memory timelockInitData = abi.encodeCall(
            TimelockControllerOptimistic.initialize,
            (params.timelockDelay, new address[](0), new address[](0), address(this))
        );
        timelock = address(new ERC1967Proxy{ salt: deploymentSalt }(timelockImpl, timelockInitData));

        // Step 3: Deploy OptimisticSelectorRegistry proxy
        selectorRegistry = Clones.cloneDeterministic(selectorRegistryImpl, deploymentSalt);

        // Step 4: Deploy Governor proxy
        bytes memory governorInitData = abi.encodeCall(
            ReserveOptimisticGovernor.initialize,
            (params.optimisticParams, params.standardParams, stakingVault, timelock, selectorRegistry)
        );
        governor = address(new ERC1967Proxy{ salt: deploymentSalt }(governorImpl, governorInitData));

        // Step 5: Finalize OptimisticSelectorRegistry proxy
        OptimisticSelectorRegistry(payable(selectorRegistry)).initialize(governor, params.selectorData);

        // Step 6: Configure timelock roles
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

        emit ReserveOptimisticGovernorSystemDeployed(address(params.underlying), governor, timelock, selectorRegistry);
    }
}
