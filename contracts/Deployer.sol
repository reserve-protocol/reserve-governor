// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC5805 } from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { IReserveOptimisticGovernorDeployer } from "@interfaces/IDeployer.sol";

import { OptimisticSelectorRegistry } from "@governance/OptimisticSelectorRegistry.sol";
import { ReserveOptimisticGovernor } from "@governance/ReserveOptimisticGovernor.sol";
import { TimelockControllerOptimistic } from "@governance/TimelockControllerOptimistic.sol";
import { ReserveOptimisticGovernanceUpgradeManager } from "@src/UpgradeManager.sol";
import { StakingVault } from "@staking/StakingVault.sol";
import {
    CANCELLER_ROLE,
    EXECUTOR_ROLE,
    OPTIMISTIC_CANCELLER_ROLE,
    OPTIMISTIC_PROPOSER_ROLE,
    PROPOSER_ROLE
} from "@utils/Constants.sol";
import { Versioned } from "@utils/Versioned.sol";

contract ReserveOptimisticGovernorDeployer is Versioned, IReserveOptimisticGovernorDeployer {
    error Deployer__InvalidStakingVaultClockMode();

    address public immutable versionRegistry;
    address public immutable stakingVaultImpl;
    address public immutable governorImpl;
    address public immutable timelockImpl;
    address public immutable selectorRegistryImpl;

    constructor(
        address _versionRegistry,
        address _stakingVaultImpl,
        address _governorImpl,
        address _timelockImpl,
        address _selectorRegistryImpl
    ) {
        versionRegistry = _versionRegistry;
        stakingVaultImpl = _stakingVaultImpl;
        governorImpl = _governorImpl;
        timelockImpl = _timelockImpl;
        selectorRegistryImpl = _selectorRegistryImpl;
    }

    /// @notice Deploy a complete Reserve Governor system via proxies using a newly deployed StakingVault
    /// @param baseParams.optimisticParams.vetoDelay {s} Delay before optimistic snapshot.
    /// @param baseParams.optimisticParams.vetoPeriod {s} Veto period for optimistic proposals.
    /// @param baseParams.optimisticParams.vetoThreshold D18{1} Stake fraction to start confirmation.
    /// @param baseParams.standardParams.votingDelay {s} Delay before standard voting starts.
    /// @param baseParams.standardParams.votingPeriod {s} Standard voting duration.
    /// @param baseParams.standardParams.voteExtension {s} Late-quorum extension window.
    /// @param baseParams.standardParams.proposalThreshold D18{1} Stake fraction required to propose.
    /// @param baseParams.standardParams.quorumNumerator D18{1} Stake fraction required for quorum.
    /// @param baseParams.selectorData Initial selector registry entries.
    /// @param baseParams.optimisticProposers Addresses granted optimistic proposer role.
    /// @param baseParams.optimisticGuardians Addresses granted optimistic canceller role.
    /// @param baseParams.guardians Addresses granted canceller role.
    /// @param baseParams.timelockDelay {s} Timelock execution delay.
    /// @param baseParams.proposalThrottleCapacity Optimistic proposal throttle capacity.
    /// @param newStakingVaultParams.underlying Underlying token for the newly deployed vault.
    /// @param newStakingVaultParams.rewardTokens Additional reward tokens for the new vault.
    /// @param newStakingVaultParams.rewardHalfLife {s} Reward streaming half-life for the new vault.
    /// @param newStakingVaultParams.unstakingDelay {s} Unstaking delay for the new vault.
    /// @return upgradeManager The deployed UpgradeManager address
    /// @return stakingVault The deployed StakingVault address
    /// @return governor The deployed Governor address
    /// @return timelock The deployed Timelock address
    /// @return selectorRegistry The deployed OptimisticSelectorRegistry address
    function deployWithNewStakingVault(
        BaseDeploymentParams calldata baseParams,
        NewStakingVaultParams calldata newStakingVaultParams,
        bytes32 deploymentNonce
    )
        external
        returns (
            address upgradeManager,
            address stakingVault,
            address governor,
            address timelock,
            address selectorRegistry
        )
    {
        bytes32 deploymentSalt = keccak256(abi.encode(msg.sender, baseParams, newStakingVaultParams, deploymentNonce));

        // Step 1: Deploy StakingVault proxy without initialization
        stakingVault = address(new ERC1967Proxy{ salt: deploymentSalt }(stakingVaultImpl, ""));

        // Step 2: Deploy UpgradeManager, Timelock, Governor, and OptimisticSelectorRegistry
        (upgradeManager, timelock, governor, selectorRegistry) =
            _deployOptimisticGovernance(baseParams, stakingVault, deploymentSalt, true);

        // Step 3: Initialize StakingVault now that the UpgradeManager exists
        StakingVault(stakingVault)
            .initialize(
                string.concat("Vote-Locked ", newStakingVaultParams.underlying.name()),
                string.concat("vl", newStakingVaultParams.underlying.symbol()),
                newStakingVaultParams.underlying,
                address(this),
                newStakingVaultParams.rewardHalfLife,
                newStakingVaultParams.unstakingDelay,
                upgradeManager
            );

        // Step 3.5: Register additional reward tokens while Deployer is temporary vault admin
        for (uint256 i = 0; i < newStakingVaultParams.rewardTokens.length; ++i) {
            StakingVault(stakingVault).addRewardToken(newStakingVaultParams.rewardTokens[i]);
        }

        // Step 4: Transfer StakingVault admin role to Timelock
        StakingVault(stakingVault).grantRole(StakingVault(stakingVault).DEFAULT_ADMIN_ROLE(), timelock);
        StakingVault(stakingVault).renounceRole(StakingVault(stakingVault).DEFAULT_ADMIN_ROLE(), address(this));
    }

    /// @notice Deploy a complete Reserve Governor system via proxies using an existing StakingVault
    /// @dev Does NOT leave the old StakingVault owned by the newly-deployed system
    /// @param baseParams.optimisticParams.vetoDelay {s} Delay before optimistic snapshot.
    /// @param baseParams.optimisticParams.vetoPeriod {s} Veto period for optimistic proposals.
    /// @param baseParams.optimisticParams.vetoThreshold D18{1} Stake fraction to start confirmation.
    /// @param baseParams.standardParams.votingDelay {s} Delay before standard voting starts.
    /// @param baseParams.standardParams.votingPeriod {s} Standard voting duration.
    /// @param baseParams.standardParams.voteExtension {s} Late-quorum extension window.
    /// @param baseParams.standardParams.proposalThreshold D18{1} Stake fraction required to propose.
    /// @param baseParams.standardParams.quorumNumerator D18{1} Stake fraction required for quorum.
    /// @param baseParams.selectorData Initial selector registry entries.
    /// @param baseParams.optimisticProposers Addresses granted optimistic proposer role.
    /// @param baseParams.guardians Addresses granted canceller role.
    /// @param baseParams.timelockDelay {s} Timelock execution delay.
    /// @param baseParams.proposalThrottleCapacity Optimistic proposals-per-account per 24h
    /// @param existingStakingVault Address of a pre-deployed StakingVault to use as governance token.
    /// @param deploymentNonce Arbitrary nonce used to derive deterministic deployment salt.
    /// @return upgradeManager The deployed UpgradeManager address
    /// @return stakingVault The provided StakingVault address.
    /// @return governor The deployed Governor address.
    /// @return timelock The deployed Timelock address.
    /// @return selectorRegistry The deployed OptimisticSelectorRegistry address.
    function deployWithExistingStakingVault(
        BaseDeploymentParams calldata baseParams,
        address existingStakingVault,
        bytes32 deploymentNonce
    )
        external
        returns (
            address upgradeManager,
            address stakingVault,
            address governor,
            address timelock,
            address selectorRegistry
        )
    {
        bytes32 deploymentSalt = keccak256(abi.encode(msg.sender, baseParams, existingStakingVault, deploymentNonce));

        stakingVault = existingStakingVault;

        // Step 2: Deploy UpgradeManager, Timelock, Governor, and OptimisticSelectorRegistry
        // The existing StakingVault predates this deployment and is not rewired to this system's UpgradeManager
        (upgradeManager, timelock, governor, selectorRegistry) =
            _deployOptimisticGovernance(baseParams, stakingVault, deploymentSalt, false);
    }

    // === Internal ===

    function _deployOptimisticGovernance(
        BaseDeploymentParams calldata baseParams,
        address stakingVault,
        bytes32 deploymentSalt,
        bool isNewStakingVault
    ) internal returns (address upgradeManager, address timelock, address governor, address selectorRegistry) {
        require(
            keccak256(bytes(IERC5805(stakingVault).CLOCK_MODE())) == keccak256("mode=timestamp"),
            Deployer__InvalidStakingVaultClockMode()
        );

        // Step 2.1: Deploy Timelock proxy without initialization
        timelock = address(new ERC1967Proxy{ salt: deploymentSalt }(timelockImpl, ""));

        // Step 2.2: Deploy OptimisticSelectorRegistry proxy
        selectorRegistry = Clones.cloneDeterministic(selectorRegistryImpl, deploymentSalt);

        // Step 2.3: Deploy Governor proxy without initialization
        governor = address(new ERC1967Proxy{ salt: deploymentSalt }(governorImpl, ""));

        // Step 2.4: Deploy UpgradeManager
        address managedStakingVault = isNewStakingVault ? stakingVault : address(0);
        upgradeManager = address(
            new ReserveOptimisticGovernanceUpgradeManager(versionRegistry, managedStakingVault, governor, timelock)
        );

        // Step 2.5: Initialize Timelock, Governor, and OptimisticSelectorRegistry now that UpgradeManager exists
        TimelockControllerOptimistic(payable(timelock))
            .initialize(baseParams.timelockDelay, new address[](0), new address[](0), address(this), upgradeManager);
        ReserveOptimisticGovernor(payable(governor))
            .initialize(
                baseParams.optimisticParams,
                baseParams.standardParams,
                baseParams.proposalThrottleCapacity,
                stakingVault,
                timelock,
                selectorRegistry,
                upgradeManager
            );
        OptimisticSelectorRegistry(payable(selectorRegistry)).initialize(baseParams.selectorData, upgradeManager);

        // Step 2.6: Configure Timelock roles
        TimelockControllerOptimistic _timelock = TimelockControllerOptimistic(payable(timelock));

        // Grant Governor the PROPOSER_ROLE
        _timelock.grantRole(PROPOSER_ROLE, governor);

        // Grant Governor the EXECUTOR_ROLE
        _timelock.grantRole(EXECUTOR_ROLE, governor);

        // Grant Governor the CANCELLER_ROLE
        _timelock.grantRole(CANCELLER_ROLE, governor);

        // Grant CANCELLER_ROLE to all guardians
        for (uint256 i = 0; i < baseParams.guardians.length; ++i) {
            _timelock.grantRole(CANCELLER_ROLE, baseParams.guardians[i]);
        }

        // Grant OPTIMISTIC_CANCELLER_ROLE to all optimistic guardians
        for (uint256 i = 0; i < baseParams.optimisticGuardians.length; ++i) {
            _timelock.grantRole(OPTIMISTIC_CANCELLER_ROLE, baseParams.optimisticGuardians[i]);
        }

        // Grant OPTIMISTIC_PROPOSER_ROLE to all optimistic proposers
        for (uint256 i = 0; i < baseParams.optimisticProposers.length; ++i) {
            _timelock.grantRole(OPTIMISTIC_PROPOSER_ROLE, baseParams.optimisticProposers[i]);
        }

        // Step 2.7: Renounce admin role
        _timelock.renounceRole(_timelock.DEFAULT_ADMIN_ROLE(), address(this));

        emit ReserveOptimisticGovernorSystemDeployed(upgradeManager, stakingVault, governor, timelock, selectorRegistry);
    }
}
