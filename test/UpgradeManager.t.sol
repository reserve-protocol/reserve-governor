// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IReserveOptimisticGovernorDeployer } from "@interfaces/IDeployer.sol";
import { IOptimisticSelectorRegistry } from "@interfaces/IOptimisticSelectorRegistry.sol";
import { IReserveOptimisticGovernor } from "@interfaces/IReserveOptimisticGovernor.sol";

import { OptimisticSelectorRegistry } from "@governance/OptimisticSelectorRegistry.sol";
import { ReserveOptimisticGovernor } from "@governance/ReserveOptimisticGovernor.sol";
import { TimelockControllerOptimistic } from "@governance/TimelockControllerOptimistic.sol";
import { ReserveOptimisticGovernorDeployer } from "@src/Deployer.sol";
import { ReserveOptimisticGovernanceUpgradeManager } from "@src/UpgradeManager.sol";
import { ReserveOptimisticGovernanceVersionRegistry } from "@src/VersionRegistry.sol";
import { StakingVault } from "@src/staking/StakingVault.sol";

import { MockERC20 } from "@mocks/MockERC20.sol";
import { MockRoleRegistry } from "@mocks/MockRoleRegistry.sol";
import { ReserveOptimisticGovernorDeployerV2Mock } from "@mocks/ReserveOptimisticGovernorDeployerV2Mock.sol";
import { ReserveOptimisticGovernorV2Mock } from "@mocks/ReserveOptimisticGovernorV2Mock.sol";
import { StakingVaultV2Mock } from "@mocks/StakingVaultV2Mock.sol";
import { TimelockControllerOptimisticV2Mock } from "@mocks/TimelockControllerOptimisticV2Mock.sol";

abstract contract UpgradeManagerTestBase is Test {
    MockERC20 internal underlying;
    MockERC20 internal reward;
    StakingVault internal stakingVault;
    ReserveOptimisticGovernor internal governor;
    TimelockControllerOptimistic internal timelock;
    ReserveOptimisticGovernanceUpgradeManager internal upgradeManager;
    ReserveOptimisticGovernor internal freshGovernor;
    TimelockControllerOptimistic internal freshTimelock;
    ReserveOptimisticGovernanceUpgradeManager internal freshUpgradeManager;
    ReserveOptimisticGovernanceVersionRegistry internal versionRegistry;

    address internal selectorRegistryImplementation;
    address internal originalStakingVaultAdmin;

    address internal alice = makeAddr("alice");

    uint48 internal constant VETO_DELAY = 1 hours;
    uint32 internal constant VETO_PERIOD = 2 hours;
    uint256 internal constant VETO_THRESHOLD = 0.2e18;

    uint48 internal constant VOTING_DELAY = 1 days;
    uint32 internal constant VOTING_PERIOD = 1 weeks;
    uint48 internal constant VOTE_EXTENSION = 1 days;
    uint256 internal constant PROPOSAL_THRESHOLD = 0.01e18;
    uint256 internal constant QUORUM_NUMERATOR = 0.1e18;
    uint256 internal constant PROPOSAL_THROTTLE_CAPACITY = 2;

    uint256 internal constant TIMELOCK_DELAY = 2 days;
    uint256 internal constant REWARD_HALF_LIFE = 1 days;
    uint256 internal constant UNSTAKING_DELAY = 1 weeks;
    uint256 internal constant ALICE_STAKE = 1_000e18;

    function _useExistingStakingVaultDeployment() internal pure virtual returns (bool);

    function setUp() public {
        underlying = new MockERC20("Underlying Token", "UNDL");
        reward = new MockERC20("Reward Token", "RWRD");

        StakingVault stakingVaultImpl = new StakingVault();
        ReserveOptimisticGovernor governorImpl = new ReserveOptimisticGovernor();
        TimelockControllerOptimistic timelockImpl = new TimelockControllerOptimistic();
        OptimisticSelectorRegistry registryImpl = new OptimisticSelectorRegistry();
        MockRoleRegistry roleRegistry = new MockRoleRegistry(address(this));

        selectorRegistryImplementation = address(registryImpl);
        versionRegistry = new ReserveOptimisticGovernanceVersionRegistry(roleRegistry);

        ReserveOptimisticGovernorDeployer deployer = new ReserveOptimisticGovernorDeployer(
            address(versionRegistry),
            address(stakingVaultImpl),
            address(governorImpl),
            address(timelockImpl),
            selectorRegistryImplementation
        );
        versionRegistry.registerVersion(deployer);

        IReserveOptimisticGovernorDeployer.BaseDeploymentParams memory baseParams =
            IReserveOptimisticGovernorDeployer.BaseDeploymentParams({
                optimisticParams: IReserveOptimisticGovernor.OptimisticGovernanceParams({
                    vetoDelay: VETO_DELAY, vetoPeriod: VETO_PERIOD, vetoThreshold: VETO_THRESHOLD
                }),
                standardParams: IReserveOptimisticGovernor.StandardGovernanceParams({
                    votingDelay: VOTING_DELAY,
                    votingPeriod: VOTING_PERIOD,
                    voteExtension: VOTE_EXTENSION,
                    proposalThreshold: PROPOSAL_THRESHOLD,
                    quorumNumerator: QUORUM_NUMERATOR
                }),
                selectorData: new IOptimisticSelectorRegistry.SelectorData[](0),
                optimisticProposers: new address[](0),
                optimisticGuardians: new address[](0),
                guardians: new address[](0),
                timelockDelay: TIMELOCK_DELAY,
                proposalThrottleCapacity: PROPOSAL_THROTTLE_CAPACITY
            });

        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(reward);

        IReserveOptimisticGovernorDeployer.NewStakingVaultParams memory newStakingVaultParams =
            IReserveOptimisticGovernorDeployer.NewStakingVaultParams({
                underlying: IERC20Metadata(address(underlying)),
                rewardTokens: rewardTokens,
                rewardHalfLife: REWARD_HALF_LIFE,
                unstakingDelay: UNSTAKING_DELAY
            });

        (address baseUpgradeManager, address stakingVaultAddr, address governorAddr, address timelockAddr,) =
            deployer.deployWithNewStakingVault(baseParams, newStakingVaultParams, bytes32(0));
        originalStakingVaultAdmin = timelockAddr;
        freshGovernor = ReserveOptimisticGovernor(payable(governorAddr));
        freshTimelock = TimelockControllerOptimistic(payable(timelockAddr));
        freshUpgradeManager = ReserveOptimisticGovernanceUpgradeManager(baseUpgradeManager);

        if (_useExistingStakingVaultDeployment()) {
            (address upgradeManagerAddr,, address existingGovernorAddr, address existingTimelockAddr,) =
                deployer.deployWithExistingStakingVault(baseParams, stakingVaultAddr, bytes32(uint256(1)));

            stakingVault = StakingVault(stakingVaultAddr);
            governor = ReserveOptimisticGovernor(payable(existingGovernorAddr));
            timelock = TimelockControllerOptimistic(payable(existingTimelockAddr));
            upgradeManager = ReserveOptimisticGovernanceUpgradeManager(upgradeManagerAddr);
        } else {
            stakingVault = StakingVault(stakingVaultAddr);
            governor = freshGovernor;
            timelock = freshTimelock;
            upgradeManager = freshUpgradeManager;
        }

        underlying.mint(address(this), ALICE_STAKE);
        underlying.approve(address(stakingVault), ALICE_STAKE);
        stakingVault.deposit(ALICE_STAKE, alice);
    }

    function test_upgradeToLatestVersion_revertsForUnauthorizedCaller() public {
        _registerV2Version();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveOptimisticGovernanceUpgradeManager.UpgradeManager__UnauthorizedCaller.selector, alice
            )
        );
        upgradeManager.upgradeToLatestVersion();
    }

    function _registerV2Version() internal {
        ReserveOptimisticGovernorDeployerV2Mock deployer = new ReserveOptimisticGovernorDeployerV2Mock(
            address(versionRegistry),
            address(new StakingVaultV2Mock()),
            address(new ReserveOptimisticGovernorV2Mock()),
            address(new TimelockControllerOptimisticV2Mock()),
            selectorRegistryImplementation
        );
        versionRegistry.registerVersion(deployer);
    }

    function _assertCommonState() internal view {
        assertEq(
            upgradeManager.stakingVault(), _useExistingStakingVaultDeployment() ? address(0) : address(stakingVault)
        );
        assertEq(address(governor.token()), address(stakingVault));
        assertEq(governor.timelock(), address(timelock));
        assertEq(governor.proposalThrottleCapacity(), PROPOSAL_THROTTLE_CAPACITY);
        assertEq(timelock.getMinDelay(), TIMELOCK_DELAY);
        assertEq(stakingVault.balanceOf(alice), ALICE_STAKE);

        address[] memory rewardTokens = stakingVault.getAllRewardTokens();
        assertEq(rewardTokens.length, 1);
        assertEq(rewardTokens[0], address(reward));
    }
}

contract UpgradeManagerNewStakingVaultTest is UpgradeManagerTestBase {
    function _useExistingStakingVaultDeployment() internal pure override returns (bool) {
        return false;
    }

    function test_upgradeToLatestVersion_upgradesAllConfiguredComponents() public {
        _registerV2Version();

        vm.prank(address(timelock));
        upgradeManager.upgradeToLatestVersion();

        assertEq(stakingVault.version(), "2.0.0");
        assertEq(governor.version(), "2.0.0");
        assertEq(timelock.version(), "2.0.0");
        assertEq(upgradeManager.stakingVault(), address(stakingVault));
        assertTrue(stakingVault.hasRole(stakingVault.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertEq(stakingVault.unstakingDelay(), UNSTAKING_DELAY);

        _assertCommonState();
    }
}

contract UpgradeManagerExistingStakingVaultTest is UpgradeManagerTestBase {
    function _useExistingStakingVaultDeployment() internal pure override returns (bool) {
        return true;
    }

    function test_upgradeToLatestVersion_revertsWhenAssociatedStakingVaultIsNotLatest() public {
        _registerV2Version();

        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveOptimisticGovernanceUpgradeManager.UpgradeManager__OldStakingVaultVersion.selector,
                address(stakingVault)
            )
        );
        upgradeManager.upgradeToLatestVersion();
    }

    function test_upgradeToLatestVersion_upgradesOnlyGovernanceComponentsAfterVaultMatchesLatest() public {
        _registerV2Version();

        vm.prank(address(freshTimelock));
        freshUpgradeManager.upgradeToLatestVersion();

        vm.prank(address(timelock));
        upgradeManager.upgradeToLatestVersion();

        assertEq(stakingVault.version(), "2.0.0");
        assertEq(governor.version(), "2.0.0");
        assertEq(timelock.version(), "2.0.0");
        assertEq(upgradeManager.stakingVault(), address(0));
        assertTrue(stakingVault.hasRole(stakingVault.DEFAULT_ADMIN_ROLE(), originalStakingVaultAdmin));
        assertFalse(stakingVault.hasRole(stakingVault.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertEq(stakingVault.unstakingDelay(), UNSTAKING_DELAY);

        _assertCommonState();
    }
}
