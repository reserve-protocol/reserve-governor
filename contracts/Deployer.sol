// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { IReserveOptimisticGovernorDeployer } from "./interfaces/IDeployer.sol";

import { OptimisticSelectorRegistry } from "./governance/OptimisticSelectorRegistry.sol";
import { ReserveOptimisticGovernor } from "./governance/ReserveOptimisticGovernor.sol";
import { TimelockControllerOptimistic } from "./governance/TimelockControllerOptimistic.sol";
import { StakingVault } from "./staking/StakingVault.sol";
import { CANCELLER_ROLE, EXECUTOR_ROLE, OPTIMISTIC_PROPOSER_ROLE, PROPOSER_ROLE } from "./utils/Constants.sol";
import { Versioned } from "./utils/Versioned.sol";

contract ReserveOptimisticGovernorDeployer is Versioned, IReserveOptimisticGovernorDeployer {
    error Deployer__InvalidStakingVault();

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

    /// @notice Deploy a complete Reserve Governor system via proxies using a newly deployed StakingVault
    /// @param baseParams.optimisticParams.vetoDelay {s} Delay before optimistic snapshot.
    /// @param baseParams.optimisticParams.vetoPeriod {s} Veto period for optimistic proposals.
    /// @param baseParams.optimisticParams.vetoThreshold D18{1} Stake fraction to start confirmation.
    /// @param baseParams.standardParams.votingDelay {s} Delay before standard voting starts.
    /// @param baseParams.standardParams.votingPeriod {s} Standard voting duration.
    /// @param baseParams.standardParams.voteExtension {s} Late-quorum extension window.
    /// @param baseParams.standardParams.proposalThreshold D18{1} Stake fraction required to propose.
    /// @param baseParams.standardParams.quorumNumerator D18{1} Stake fraction required for quorum.
    /// @param baseParams.standardParams.proposalThrottleCapacity Standard proposal throttle capacity.
    /// @param baseParams.selectorData Initial selector registry entries.
    /// @param baseParams.optimisticProposers Addresses granted optimistic proposer role.
    /// @param baseParams.guardians Addresses granted canceller role.
    /// @param baseParams.timelockDelay {s} Timelock execution delay.
    /// @param newStakingVaultParams.underlying Underlying token for the newly deployed vault.
    /// @param newStakingVaultParams.rewardTokens Additional reward tokens for the new vault.
    /// @param newStakingVaultParams.rewardHalfLife {s} Reward streaming half-life for the new vault.
    /// @param newStakingVaultParams.unstakingDelay {s} Unstaking delay for the new vault.
    /// @return stakingVault The deployed StakingVault address
    /// @return governor The deployed Governor address
    /// @return timelock The deployed Timelock address
    /// @return selectorRegistry The deployed OptimisticSelectorRegistry address
    function deployWithNewStakingVault(
        BaseDeploymentParams calldata baseParams,
        NewStakingVaultParams calldata newStakingVaultParams,
        bytes32 deploymentNonce
    ) external returns (address stakingVault, address governor, address timelock, address selectorRegistry) {
        bytes32 deploymentSalt = keccak256(abi.encode(msg.sender, baseParams, newStakingVaultParams, deploymentNonce));

        // Step 1: Deploy StakingVault proxy
        bytes memory stakingVaultInitData = abi.encodeCall(
            StakingVault.initialize,
            (
                string.concat("Vote-Locked ", newStakingVaultParams.underlying.name()),
                string.concat("vl", newStakingVaultParams.underlying.symbol()),
                newStakingVaultParams.underlying,
                address(this),
                newStakingVaultParams.rewardHalfLife,
                newStakingVaultParams.unstakingDelay
            )
        );
        stakingVault = address(new ERC1967Proxy{ salt: deploymentSalt }(stakingVaultImpl, stakingVaultInitData));

        // Step 1.5: Register additional reward tokens while Deployer is temporary owner
        for (uint256 i = 0; i < newStakingVaultParams.rewardTokens.length; ++i) {
            StakingVault(stakingVault).addRewardToken(newStakingVaultParams.rewardTokens[i]);
        }

        // Step 2: Deploy Timelock, OptimisticSelectorRegistry, and Governor
        (timelock, governor, selectorRegistry) = _deployOptimisticGovernance(baseParams, stakingVault, deploymentSalt);

        // Step 3: Transfer StakingVault ownership to Timelock
        StakingVault(stakingVault).transferOwnership(timelock);

        emit ReserveOptimisticGovernorSystemDeployed(stakingVault, governor, timelock, selectorRegistry);
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
    /// @param baseParams.standardParams.proposalThrottleCapacity Standard proposal throttle capacity.
    /// @param baseParams.selectorData Initial selector registry entries.
    /// @param baseParams.optimisticProposers Addresses granted optimistic proposer role.
    /// @param baseParams.guardians Addresses granted canceller role.
    /// @param baseParams.timelockDelay {s} Timelock execution delay.
    /// @param existingStakingVault Address of a pre-deployed StakingVault to use as governance token.
    /// @param deploymentNonce Arbitrary nonce used to derive deterministic deployment salt.
    /// @return stakingVault The provided StakingVault address.
    /// @return governor The deployed Governor address.
    /// @return timelock The deployed Timelock address.
    /// @return selectorRegistry The deployed OptimisticSelectorRegistry address.
    function deployWithExistingStakingVault(
        BaseDeploymentParams calldata baseParams,
        address existingStakingVault,
        bytes32 deploymentNonce
    ) external returns (address stakingVault, address governor, address timelock, address selectorRegistry) {
        // Step 1: Validate existing StakingVault
        require(existingStakingVault.code.length != 0, Deployer__InvalidStakingVault());

        bytes32 deploymentSalt = keccak256(abi.encode(msg.sender, baseParams, existingStakingVault, deploymentNonce));

        stakingVault = existingStakingVault;

        // Step 2: Deploy Timelock, OptimisticSelectorRegistry, and Governor
        (timelock, governor, selectorRegistry) = _deployOptimisticGovernance(baseParams, stakingVault, deploymentSalt);

        emit ReserveOptimisticGovernorSystemDeployed(stakingVault, governor, timelock, selectorRegistry);
    }

    // === Internal ===

    function _deployOptimisticGovernance(
        BaseDeploymentParams calldata baseParams,
        address stakingVault,
        bytes32 deploymentSalt
    ) internal returns (address timelock, address governor, address selectorRegistry) {
        // Step 2.1: Deploy Timelock proxy with Deployer as temporary admin
        bytes memory timelockInitData = abi.encodeCall(
            TimelockControllerOptimistic.initialize,
            (baseParams.timelockDelay, new address[](0), new address[](0), address(this))
        );
        timelock = address(new ERC1967Proxy{ salt: deploymentSalt }(timelockImpl, timelockInitData));

        // Step 2.2: Deploy OptimisticSelectorRegistry proxy
        selectorRegistry = Clones.cloneDeterministic(selectorRegistryImpl, deploymentSalt);

        // Step 2.3: Deploy Governor proxy
        bytes memory governorInitData = abi.encodeCall(
            ReserveOptimisticGovernor.initialize,
            (baseParams.optimisticParams, baseParams.standardParams, stakingVault, timelock, selectorRegistry)
        );
        governor = address(new ERC1967Proxy{ salt: deploymentSalt }(governorImpl, governorInitData));

        // Step 2.4: Finalize OptimisticSelectorRegistry proxy
        OptimisticSelectorRegistry(payable(selectorRegistry)).initialize(governor, baseParams.selectorData);

        // Step 2.5: Configure Timelock roles
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

        // Grant OPTIMISTIC_PROPOSER_ROLE to all optimistic proposers
        for (uint256 i = 0; i < baseParams.optimisticProposers.length; ++i) {
            _timelock.grantRole(OPTIMISTIC_PROPOSER_ROLE, baseParams.optimisticProposers[i]);
        }

        // Step 2.6: Renounce admin role
        _timelock.renounceRole(_timelock.DEFAULT_ADMIN_ROLE(), address(this));
    }
}
