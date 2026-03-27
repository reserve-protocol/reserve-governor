// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IERC20, IERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IReserveOptimisticGovernorDeployer } from "@interfaces/IDeployer.sol";
import { IOptimisticSelectorRegistry } from "@interfaces/IOptimisticSelectorRegistry.sol";
import { IReserveOptimisticGovernor } from "@interfaces/IReserveOptimisticGovernor.sol";

import { OptimisticSelectorRegistry } from "@governance/OptimisticSelectorRegistry.sol";
import { ReserveOptimisticGovernor } from "@governance/ReserveOptimisticGovernor.sol";
import { TimelockControllerOptimistic } from "@governance/TimelockControllerOptimistic.sol";
import { ReserveOptimisticGovernorDeployer } from "@src/Deployer.sol";
import { Guardian } from "@src/Guardian.sol";
import { ReserveOptimisticGovernanceVersionRegistry } from "@src/VersionRegistry.sol";
import { StakingVault } from "@src/staking/StakingVault.sol";
import { UnstakingManager } from "@src/staking/UnstakingManager.sol";
import { RewardTokenRegistry } from "@staking/RewardTokenRegistry.sol";

import { MockERC20 } from "@mocks/MockERC20.sol";
import { MockRoleRegistry } from "@mocks/MockRoleRegistry.sol";
import { ReserveOptimisticGovernorDeployerV2Mock } from "@mocks/ReserveOptimisticGovernorDeployerV2Mock.sol";
import { StakingVaultV2Mock } from "@mocks/StakingVaultV2Mock.sol";

contract StakingVaultTest is Test {
    MockRoleRegistry private roleRegistry;
    ReserveOptimisticGovernanceVersionRegistry private versionRegistry;
    RewardTokenRegistry private rewardTokenRegistry;

    MockERC20 private token;
    MockERC20 private reward;

    StakingVault private vault;
    address private vaultImpl;

    address private timelock;

    uint256 private constant REWARD_HALF_LIFE = 3 days;
    uint256 private constant UNSTAKING_DELAY = 1 weeks;

    address constant ACTOR_ALICE = address(0x123123001);
    address constant ACTOR_BOB = address(0x123123002);

    function setUp() public {
        token = new MockERC20("Test Token", "TEST");
        reward = new MockERC20("Reward Token", "REWARD");
        vm.label(address(token), "Test Token");
        vm.label(address(reward), "Reward Token");

        // Deploy mock role registry
        roleRegistry = new MockRoleRegistry(address(this));

        // Deploy registries
        versionRegistry = new ReserveOptimisticGovernanceVersionRegistry(roleRegistry);
        rewardTokenRegistry = new RewardTokenRegistry(roleRegistry);

        // Deploy implementations
        vaultImpl = address(new StakingVault());
        address governorImpl = address(new ReserveOptimisticGovernor());
        address timelockImpl = address(new TimelockControllerOptimistic());
        address registryImpl = address(new OptimisticSelectorRegistry());
        Guardian guardian = new Guardian(address(this), new address[](0));

        // Deploy Deployer
        ReserveOptimisticGovernorDeployer deployer = new ReserveOptimisticGovernorDeployer(
            address(versionRegistry),
            address(rewardTokenRegistry),
            address(guardian),
            vaultImpl,
            governorImpl,
            timelockImpl,
            registryImpl
        );

        rewardTokenRegistry.registerRewardToken(address(reward));
        versionRegistry.registerVersion(deployer);

        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(reward);

        IReserveOptimisticGovernorDeployer.BaseDeploymentParams memory baseParams =
            IReserveOptimisticGovernorDeployer.BaseDeploymentParams({
                optimisticParams: IReserveOptimisticGovernor.OptimisticGovernanceParams({
                    vetoDelay: 1 hours, vetoPeriod: 2 hours, vetoThreshold: 0.05e18
                }),
                standardParams: IReserveOptimisticGovernor.StandardGovernanceParams({
                    votingDelay: 1 days,
                    votingPeriod: 1 weeks,
                    voteExtension: 1 days,
                    proposalThreshold: 0.01e18,
                    quorumNumerator: 0.1e18
                }),
                selectorData: new IOptimisticSelectorRegistry.SelectorData[](0),
                optimisticProposers: new address[](0),
                timelockDelay: 2 days,
                proposalThrottleCapacity: 10
            });

        IReserveOptimisticGovernorDeployer.NewStakingVaultParams memory newStakingVaultParams =
            IReserveOptimisticGovernorDeployer.NewStakingVaultParams({
                underlying: IERC20Metadata(address(token)),
                rewardTokens: rewardTokens,
                rewardHalfLife: REWARD_HALF_LIFE,
                unstakingDelay: UNSTAKING_DELAY
            });

        // Deploy system
        (address stakingVaultAddr,, address timelockAddr,) =
            deployer.deployWithNewStakingVault(baseParams, newStakingVaultParams, bytes32(0));
        vault = StakingVault(stakingVaultAddr);
        timelock = timelockAddr;

        vm.label(ACTOR_ALICE, "Alice");
        vm.label(ACTOR_BOB, "Bob");
    }

    function _payoutRewards(uint256 cycles) internal {
        vm.warp(block.timestamp + REWARD_HALF_LIFE * cycles);
    }

    function _mintAndDepositFor(address receiver, uint256 amount) internal {
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount, receiver);
    }

    function _withdrawAs(address actor, uint256 amount) internal {
        vm.startPrank(actor);
        vault.redeem(amount, actor, actor);
        vm.stopPrank();
    }

    function _claimRewardsAs(address actor) internal {
        vm.startPrank(actor);
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(reward);
        vault.claimRewards(rewardTokens);
        vm.stopPrank();
    }

    function _registerRewardToken(address rewardToken) internal {
        rewardTokenRegistry.registerRewardToken(rewardToken);
    }

    function _registerV2Deployer(address stakingVaultImplementation)
        internal
        returns (ReserveOptimisticGovernorDeployerV2Mock deployer)
    {
        deployer = new ReserveOptimisticGovernorDeployerV2Mock(
            address(versionRegistry),
            address(rewardTokenRegistry),
            address(new Guardian(address(this), new address[](0))),
            stakingVaultImplementation,
            address(new ReserveOptimisticGovernor()),
            address(new TimelockControllerOptimistic()),
            address(new OptimisticSelectorRegistry())
        );
        versionRegistry.registerVersion(deployer);
    }

    function _v2VersionHash() internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("2.0.0"));
    }

    function test_deployment() public view {
        assertEq(vault.name(), "Vote-Locked Test Token");
        assertEq(vault.symbol(), "vlTEST");
        assertEq(address(vault.asset()), address(token));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertEq(vault.unstakingDelay(), UNSTAKING_DELAY);
        assertEq(vault.clock(), block.timestamp);
        assertEq(vault.CLOCK_MODE(), "mode=timestamp");
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.balanceOf(ACTOR_ALICE), 0);
        assertEq(vault.balanceOf(ACTOR_BOB), 0);
        assertEq(vault.nonces(ACTOR_ALICE), 0);
        assertEq(vault.nonces(ACTOR_BOB), 0);
        assertEq(vault.decimals(), 18);
        assertEq(reward.balanceOf(address(vault)), 0);
        assertEq(reward.balanceOf(ACTOR_ALICE), 0);
        assertEq(reward.balanceOf(ACTOR_BOB), 0);

        address[] memory _rewardTokens = vault.getAllRewardTokens();
        assertEq(_rewardTokens.length, 1);
        assertEq(_rewardTokens[0], address(reward));
    }

    // @todo Remove this later
    function test_check() public {
        _mintAndDepositFor(address(this), 1000 * 1e18);
        vm.warp(block.timestamp + 1);

        reward.mint(address(vault), 1000 * 1e18);

        vm.startSnapshotGas("poke with one token");
        vault.poke();
        vm.stopSnapshotGas();

        vm.warp(block.timestamp + 3 days);

        vault.poke();

        vm.warp(block.timestamp + 3 days);

        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(reward);
        vault.claimRewards(rewardTokens);

        vm.warp(block.timestamp + 3 days);

        vault.poke();
    }

    function testGas_pokeWithTokens() public {
        uint8[4] memory rewardTokens = [1, 10, 15, 20];

        for (uint8 i = 0; i < rewardTokens.length; i++) {
            uint256 snap = vm.snapshotState();

            vm.prank(address(timelock));
            vault.setUnstakingDelay(0);
            vm.prank(address(timelock));
            vault.removeRewardToken(address(reward));

            token.mint(address(this), 1000 * 1e18);
            token.approve(address(vault), 1000 * 1e18);
            vault.deposit(1000 * 1e18, address(this));

            vm.warp(block.timestamp + 1);
            vault.poke();

            for (uint8 j = 0; j < rewardTokens[i]; j++) {
                MockERC20 rewardToken = new MockERC20("Reward Token", "REWARD");
                rewardToken.mint(address(vault), 1000 * 1e18);

                _registerRewardToken(address(rewardToken));
                vm.prank(address(timelock));
                vault.addRewardToken(address(rewardToken));
            }

            string memory gasTag1 = string.concat("poke(1, ", vm.toString(rewardTokens[i]), " tokens)");
            _payoutRewards(1);
            vault.poke();
            vm.snapshotGasLastCall(gasTag1);

            string memory gasTag2 = string.concat("poke(2, ", vm.toString(rewardTokens[i]), " tokens)");
            _payoutRewards(1);
            vault.poke();
            vm.snapshotGasLastCall(gasTag2);

            vm.revertToStateAndDelete(snap);
        }
    }

    function test__accrual_singleRewardTokenMultipleEvenActors() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);
        _mintAndDepositFor(ACTOR_BOB, 1000e18);

        vm.warp(block.timestamp + 1);
        reward.mint(address(vault), 1000e18);
        vault.poke();

        _payoutRewards(1);

        _claimRewardsAs(ACTOR_ALICE);
        _claimRewardsAs(ACTOR_BOB);

        assertEq(reward.balanceOf(ACTOR_ALICE), reward.balanceOf(ACTOR_BOB));
        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 250e18, 0.001e18);

        _payoutRewards(1);
        _claimRewardsAs(ACTOR_ALICE);
        _claimRewardsAs(ACTOR_BOB);

        assertEq(reward.balanceOf(ACTOR_ALICE), reward.balanceOf(ACTOR_BOB));
        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 375e18, 0.001e18);
    }

    function test__accrual_singleRewardTokenMultipleUnevenActors() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);
        _mintAndDepositFor(ACTOR_BOB, 3000e18);

        vm.warp(block.timestamp + 1);
        reward.mint(address(vault), 1000e18);
        vault.poke();

        _payoutRewards(1);

        _claimRewardsAs(ACTOR_ALICE);
        _claimRewardsAs(ACTOR_BOB);

        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 125e18, 0.001e18);
        assertApproxEqRel(reward.balanceOf(ACTOR_BOB), 375e18, 0.001e18);

        _payoutRewards(1);
        _claimRewardsAs(ACTOR_ALICE);
        _claimRewardsAs(ACTOR_BOB);

        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 187.5e18, 0.001e18);
        assertApproxEqRel(reward.balanceOf(ACTOR_BOB), 562.5e18, 0.001e18);
    }

    function test__accrual_complexSerialEntry() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);

        vm.warp(block.timestamp + 1);
        reward.mint(address(vault), 1000e18);
        vault.poke();

        _payoutRewards(1);

        _withdrawAs(ACTOR_ALICE, 1000e18);
        _claimRewardsAs(ACTOR_ALICE);

        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 500e18, 0.001e18);

        _mintAndDepositFor(ACTOR_BOB, 1000e18);

        _payoutRewards(1);

        _withdrawAs(ACTOR_BOB, 1000e18);
        _claimRewardsAs(ACTOR_BOB);

        assertApproxEqRel(reward.balanceOf(ACTOR_BOB), 250e18, 0.001e18);
    }

    function test__accrual_simpleTransferActors() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);

        vm.warp(block.timestamp + 1);
        reward.mint(address(vault), 1000e18);
        vault.poke();

        _payoutRewards(1);

        vm.prank(ACTOR_ALICE);
        vault.transfer(ACTOR_BOB, 1000e18);

        _payoutRewards(1);

        _claimRewardsAs(ACTOR_ALICE);
        _claimRewardsAs(ACTOR_BOB);

        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 500e18, 0.001e18);
        assertApproxEqRel(reward.balanceOf(ACTOR_BOB), 250e18, 0.001e18);
    }

    function test__accrual_complexTransferActors() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);

        vm.warp(block.timestamp + 1);
        reward.mint(address(vault), 1000e18);
        vault.poke();

        _payoutRewards(1);

        vm.prank(ACTOR_ALICE);
        vault.transfer(ACTOR_BOB, 500e18);

        _payoutRewards(1);

        _claimRewardsAs(ACTOR_ALICE);
        _claimRewardsAs(ACTOR_BOB);

        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 625e18, 0.001e18);
        assertApproxEqRel(reward.balanceOf(ACTOR_BOB), 125e18, 0.001e18);
    }

    function test_accrual_composesOverTime() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);
        _mintAndDepositFor(ACTOR_BOB, 1000e18);

        vm.warp(block.timestamp + 1);
        reward.mint(address(vault), 2000e18);
        vault.poke();

        // paying out 1 cycle 10 times should be the same as paying out 10 cycles once
        for (uint256 i = 0; i < 10; i++) {
            _payoutRewards(1);
            _claimRewardsAs(ACTOR_ALICE);
        }
        _claimRewardsAs(ACTOR_BOB);

        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 999.02344e18, 0.0001e18);
        assertApproxEqRel(reward.balanceOf(ACTOR_BOB), 999.02344e18, 0.0001e18);
    }

    function test__accrual_emitsEventWhenClaimingRewards() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);

        vm.warp(block.timestamp + 1);
        reward.mint(address(vault), 1000e18);
        vault.poke();

        _payoutRewards(1);

        vm.recordLogs();
        _claimRewardsAs(ACTOR_ALICE);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries[1].topics[0], keccak256("RewardsClaimed(address,address,uint256)"));
        assertEq(entries[1].data, abi.encode(address(ACTOR_ALICE), address(reward), reward.balanceOf(ACTOR_ALICE)));
        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 500e18, 0.001e18);
    }

    function test_addRewardToken() public {
        MockERC20 newReward = new MockERC20("New Reward Token", "NREWARD");
        _registerRewardToken(address(newReward));
        vm.expectEmit(true, false, false, true);
        emit StakingVault.RewardTokenAdded(address(newReward));
        vm.prank(address(timelock));
        vault.addRewardToken(address(newReward));

        address[] memory _rewardTokens = vault.getAllRewardTokens();
        assertEq(_rewardTokens.length, 2);
        assertEq(_rewardTokens[0], address(reward));
        assertEq(_rewardTokens[1], address(newReward));
    }

    function test_cannotAddRewardTokenIfNotOwner() public {
        MockERC20 newReward = new MockERC20("New Reward Token", "NREWARD");
        _registerRewardToken(address(newReward));
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(ACTOR_ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ACTOR_ALICE, adminRole)
        );
        vault.addRewardToken(address(newReward));
    }

    function test_cannotAddRewardTokenIfInvalid() public {
        vm.startPrank(address(timelock));
        vm.expectRevert();
        vault.addRewardToken(address(0));

        vm.expectRevert(abi.encodeWithSelector(StakingVault.Vault__InvalidRewardToken.selector, address(token)));
        vault.addRewardToken(address(token));

        vm.expectRevert(abi.encodeWithSelector(StakingVault.Vault__InvalidRewardToken.selector, address(vault)));
        vault.addRewardToken(address(vault));
        vm.stopPrank();
    }

    function test_cannotAddRewardTokenIfPreviouslyRemoved() public {
        // Remove reward token
        vm.prank(address(timelock));
        vault.removeRewardToken(address(reward));
        address[] memory _rewardTokens = vault.getAllRewardTokens();
        assertEq(_rewardTokens.length, 0);

        // Cannot re-add token
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(StakingVault.Vault__DisallowedRewardToken.selector, address(reward)));
        vault.addRewardToken(address(reward));
    }

    function test_cannotAddRewardTokenIfAlreadyRegistered() public {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(StakingVault.Vault__RewardAlreadyRegistered.selector));
        vault.addRewardToken(address(reward));
    }

    function test_removeRewardToken() public {
        vm.expectEmit(true, false, false, true);
        emit StakingVault.RewardTokenRemoved(address(reward));
        vm.prank(address(timelock));
        vault.removeRewardToken(address(reward));
        address[] memory _rewardTokens = vault.getAllRewardTokens();
        assertEq(_rewardTokens.length, 0);
    }

    function test_cannotRemoveRewardTokenIfNotOwner() public {
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(ACTOR_ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ACTOR_ALICE, adminRole)
        );
        vault.removeRewardToken(address(reward));
    }

    function test_cannotRemoveRewardTokenIfNotRegistered() public {
        MockERC20 newReward = new MockERC20("New Reward Token", "NREWARD");
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(StakingVault.Vault__RewardNotRegistered.selector));
        vault.removeRewardToken(address(newReward));
    }

    function test_setRewardRatio() public {
        uint256 rewardRatioPrev = vault.rewardRatio();
        vm.expectEmit(true, true, false, true);
        emit StakingVault.RewardRatioSet(rewardRatioPrev * 2, REWARD_HALF_LIFE / 2);

        vm.prank(address(timelock));
        vault.setRewardRatio(REWARD_HALF_LIFE / 2);
        assertEq(vault.rewardRatio(), rewardRatioPrev * 2);
    }

    function test_cannotSetRewardRatioIfNotOwner() public {
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(ACTOR_ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ACTOR_ALICE, adminRole)
        );
        vault.setRewardRatio(REWARD_HALF_LIFE / 2);
    }

    function test_cannotSetRewardRatioWithInvalidValue() public {
        vm.prank(address(timelock));
        vm.expectRevert(StakingVault.Vault__InvalidRewardsHalfLife.selector);
        vault.setRewardRatio(2 weeks + 1);
    }

    function test_depositAndDelegate() public {
        token.mint(address(this), 1000e18);
        token.approve(address(vault), 1000e18);

        // normal deposit (no delegation)
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(address(this), address(this), 500e18, 500e18);
        vault.deposit(500e18, address(this));
        assertEq(vault.balanceOf(address(this)), 500e18);
        assertEq(vault.delegates(address(this)), address(0));

        // deposit and delegate
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(address(this), address(this), 500e18, 500e18);
        vm.expectEmit(true, true, true, true);
        emit IVotes.DelegateChanged(address(this), address(0), address(this));
        vault.depositAndDelegate(500e18);

        assertEq(vault.delegates(address(this)), address(this)); // delegated
        assertEq(vault.balanceOf(address(this)), 1000e18); // has full balance
    }

    function test_unstake_noDelay() public {
        vm.prank(address(timelock));
        vault.setUnstakingDelay(0);

        token.mint(address(this), 1000e18);
        token.approve(address(vault), 1000e18);

        vault.deposit(1000e18, address(this));
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(address(this), address(this), address(this), 1000e18, 1000e18);
        vault.redeem(1000e18, address(this), address(this));
        assertEq(token.balanceOf(address(this)), 1000e18);
    }

    function test_unstake_noDelay_redeemOnBehalf() public {
        vm.prank(address(timelock));
        vault.setUnstakingDelay(0);

        token.mint(address(this), 1000e18);
        token.approve(address(vault), 1000e18);

        vault.deposit(1000e18, address(this));

        // Reedem on behalf
        vault.approve(ACTOR_ALICE, 1000e18);

        vm.startPrank(ACTOR_ALICE);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(ACTOR_ALICE, address(this), address(this), 1000e18, 1000e18);
        vault.redeem(1000e18, address(this), address(this));
        vm.stopPrank();

        assertEq(token.balanceOf(address(this)), 1000e18);
    }

    function test_unstakingDelay_claimLock() public {
        vm.prank(address(timelock));
        vault.setUnstakingDelay(14 days);
        UnstakingManager manager = vault.unstakingManager();

        token.mint(address(this), 1000e18);
        token.approve(address(vault), 1000e18);

        vault.deposit(1000e18, address(this));
        vm.expectEmit(true, true, true, true);
        emit UnstakingManager.LockCreated(0, address(this), 1000e18, block.timestamp + vault.unstakingDelay());
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(address(this), address(this), address(this), 1000e18, 1000e18);
        vault.redeem(1000e18, address(this), address(this));

        assertEq(token.balanceOf(address(this)), 0);

        vm.expectRevert(UnstakingManager.UnstakingManager__NotUnlockedYet.selector);
        manager.claimLock(0);

        vm.warp(block.timestamp + 14 days);
        vm.expectEmit(true, false, false, true);
        emit UnstakingManager.LockClaimed(0);
        manager.claimLock(0);

        assertEq(token.balanceOf(address(this)), 1000e18);

        // Cannot claim again
        vm.expectRevert(UnstakingManager.UnstakingManager__AlreadyClaimed.selector);
        manager.claimLock(0);
    }

    function test_unstakingDelay_cancelLock() public {
        vm.prank(address(timelock));
        vault.setUnstakingDelay(14 days);
        UnstakingManager manager = vault.unstakingManager();

        token.mint(address(this), 1000e18);
        token.approve(address(vault), 1000e18);

        vault.deposit(1000e18, address(this));
        vm.expectEmit(true, true, true, true);
        emit UnstakingManager.LockCreated(0, address(this), 1000e18, block.timestamp + vault.unstakingDelay());
        vault.redeem(1000e18, address(this), address(this));

        assertEq(token.balanceOf(address(this)), 0);

        vm.expectRevert(UnstakingManager.UnstakingManager__NotUnlockedYet.selector);
        manager.claimLock(0);

        vm.expectEmit(true, false, false, true);
        emit UnstakingManager.LockCancelled(0);
        manager.cancelLock(0);

        assertEq(token.balanceOf(address(this)), 0);
        assertEq(vault.balanceOf(address(this)), 1000e18);

        // Cannot claim
        vm.expectRevert(UnstakingManager.UnstakingManager__NotUnlockedYet.selector);
        manager.claimLock(0);
    }

    function test_unstakingDelay_redeemOnBehalf() public {
        vm.prank(address(timelock));
        vault.setUnstakingDelay(14 days);
        UnstakingManager manager = vault.unstakingManager();

        token.mint(address(this), 1000e18);
        token.approve(address(vault), 1000e18);
        vault.deposit(1000e18, address(this));

        // Reedem on behalf
        vault.approve(ACTOR_ALICE, 1000e18);

        vm.startPrank(ACTOR_ALICE);
        vm.expectEmit(true, true, true, true);
        emit UnstakingManager.LockCreated(0, address(this), 1000e18, block.timestamp + vault.unstakingDelay());
        vault.redeem(1000e18, address(this), address(this));
        vm.stopPrank();

        assertEq(token.balanceOf(address(this)), 0);

        vm.warp(block.timestamp + 14 days);
        vm.expectEmit(true, false, false, true);
        emit UnstakingManager.LockClaimed(0);
        manager.claimLock(0);

        assertEq(token.balanceOf(address(this)), 1000e18);
    }

    function test_cannotCancelLockIfNotUser() public {
        vm.prank(address(timelock));
        vault.setUnstakingDelay(14 days);
        UnstakingManager manager = vault.unstakingManager();

        token.mint(address(this), 1000e18);
        token.approve(address(vault), 1000e18);

        vault.deposit(1000e18, address(this));
        vm.expectEmit(true, true, true, true);
        emit UnstakingManager.LockCreated(0, address(this), 1000e18, block.timestamp + vault.unstakingDelay());
        vault.redeem(1000e18, address(this), address(this));

        assertEq(token.balanceOf(address(this)), 0);

        vm.prank(ACTOR_BOB);
        vm.expectRevert(UnstakingManager.UnstakingManager__Unauthorized.selector);
        manager.cancelLock(0);
    }

    function test_cannotCancelLockIfAlreadyClaimed() public {
        vm.prank(address(timelock));
        vault.setUnstakingDelay(14 days);
        UnstakingManager manager = vault.unstakingManager();

        token.mint(address(this), 1000e18);
        token.approve(address(vault), 1000e18);

        vault.deposit(1000e18, address(this));
        vm.expectEmit(true, true, true, true);
        emit UnstakingManager.LockCreated(0, address(this), 1000e18, block.timestamp + vault.unstakingDelay());
        vault.redeem(1000e18, address(this), address(this));

        assertEq(token.balanceOf(address(this)), 0);

        vm.warp(block.timestamp + 14 days);
        vm.expectEmit(true, false, false, true);
        emit UnstakingManager.LockClaimed(0);
        manager.claimLock(0);

        assertEq(token.balanceOf(address(this)), 1000e18);

        // Cannot cancel
        vm.expectRevert(UnstakingManager.UnstakingManager__AlreadyClaimed.selector);
        manager.cancelLock(0);
    }

    function test_cannotCreateLockIfNotVault() public {
        UnstakingManager manager = vault.unstakingManager();

        vm.expectRevert(UnstakingManager.UnstakingManager__Unauthorized.selector);
        manager.createLock(ACTOR_ALICE, 100e18, 10000);
    }

    function test_setUnstakingDelay() public {
        uint256 newUnstakingDelay = 2 weeks;
        vm.expectEmit(true, false, false, true);
        emit StakingVault.UnstakingDelaySet(newUnstakingDelay);
        vm.prank(address(timelock));
        vault.setUnstakingDelay(newUnstakingDelay);
        assertEq(vault.unstakingDelay(), newUnstakingDelay, "wrong unstaking delay");
    }

    function test_cannotSetUnstakingDelayIfNotOwner() public {
        uint256 newUnstakingDelay = 2 weeks;
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(ACTOR_ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ACTOR_ALICE, adminRole)
        );
        vault.setUnstakingDelay(newUnstakingDelay);
    }

    function test_cannotSetUnstakingDelayIfNotValid() public {
        uint256 newUnstakingDelay = 4 weeks + 1; // invalid
        vm.prank(address(timelock));
        vm.expectRevert(StakingVault.Vault__InvalidUnstakingDelay.selector);
        vault.setUnstakingDelay(newUnstakingDelay);
    }

    function test__StackingVault__ZeroSupply() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);

        reward.mint(address(vault), 1000e18);
        vault.poke();
        _payoutRewards(1);

        _withdrawAs(ACTOR_ALICE, 1000e18);
        _claimRewardsAs(ACTOR_ALICE);

        assertApproxEqRel(reward.balanceOf(ACTOR_ALICE), 500e18, 0.01e18);
        assertApproxEqRel(vault.totalSupply(), 0, 0);

        for (uint256 i = 0; i < 10; i++) {
            // 10 cycles without any supply, but still poking.
            _payoutRewards(1);
            vault.poke();
        }

        _mintAndDepositFor(ACTOR_BOB, 1000e18);
        vault.poke();

        _payoutRewards(1);

        _withdrawAs(ACTOR_BOB, 1000e18);
        _claimRewardsAs(ACTOR_BOB);

        assertApproxEqRel(reward.balanceOf(ACTOR_BOB), 250e18, 0.01e18);
    }

    function test__accrual_nativeAssetRewardsIncreaseTotalAssets() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);
        _mintAndDepositFor(ACTOR_BOB, 1000e18);

        uint256 initialTotalAssets = vault.totalAssets();
        assertEq(initialTotalAssets, 2000e18);

        // Mint native asset rewards to the vault
        vm.warp(block.timestamp + 1);
        token.mint(address(vault), 1000e18);
        vault.poke();

        // After one reward half-life, totalAssets should increase
        _payoutRewards(1);
        vault.poke(); // Accrue rewards
        uint256 totalAssetsAfterOneCycle = vault.totalAssets();
        assertGt(totalAssetsAfterOneCycle, initialTotalAssets);
        // Approximately 50% of the 1000e18 rewards should be accounted for
        assertApproxEqRel(totalAssetsAfterOneCycle, 2500e18, 0.001e18);

        // After another cycle, more rewards should accrue
        _payoutRewards(1);
        vault.poke(); // Accrue rewards
        uint256 totalAssetsAfterTwoCycles = vault.totalAssets();
        assertGt(totalAssetsAfterTwoCycles, totalAssetsAfterOneCycle);
        // Approximately 75% of the 1000e18 rewards should be accounted for
        assertApproxEqRel(totalAssetsAfterTwoCycles, 2750e18, 0.001e18);
    }

    function test__accrual_nativeAssetRewardsDonationIsDelayedByOneIteration() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);

        uint256 initialTotalAssets = vault.totalAssets();
        assertEq(initialTotalAssets, 1000e18);

        // Let one full cycle pass with no native rewards, then donate.
        _payoutRewards(1);
        token.mint(address(vault), 1000e18);

        // First poke should only snapshot the donation, not distribute it yet.
        vault.poke();
        uint256 totalAssetsAfterFirstPoke = vault.totalAssets();
        assertEq(totalAssetsAfterFirstPoke, initialTotalAssets);

        // Distribution starts on the next iteration.
        _payoutRewards(1);
        vault.poke();
        uint256 totalAssetsAfterSecondPoke = vault.totalAssets();
        assertGt(totalAssetsAfterSecondPoke, initialTotalAssets);
        assertApproxEqRel(totalAssetsAfterSecondPoke, 1500e18, 0.001e18);
    }

    function test__accrual_nativeAssetRewardsPreciseMultiActionAccounting() public {
        vm.prank(address(timelock));
        vault.setUnstakingDelay(0);

        _mintAndDepositFor(ACTOR_ALICE, 1000e18);
        _mintAndDepositFor(ACTOR_BOB, 2000e18);

        uint256 bobFirstRedeemBase = 500e18;
        uint256 bobFirstRedeemHandout = 0;

        uint256 alicePartialRedeemBase = 400e18;
        uint256 alicePartialRedeemHandout = 72_000_066_729_680_005_535;

        uint256 aliceSecondDepositBaseShares = 300e18;
        uint256 aliceSecondDepositShareDiscount = 45_762_747_807_564_585_356;

        uint256 bobFinalRedeemBase = 1_500e18;
        uint256 bobFinalRedeemHandout = 604_503_672_237_134_043_237;

        uint256 aliceFinalRedeemBase = 854_237_252_192_435_414_644;
        uint256 aliceFinalRedeemHandout = 344_259_703_941_390_661_515;

        // No donation cycle should not change totalAssets.
        _payoutRewards(1);
        vault.poke();
        _payoutRewards(1);
        vault.poke();
        assertEq(vault.totalAssets(), 3000e18);

        // Donation #1: should not be distributed on the next state-changing action.
        token.mint(address(vault), 900e18);
        assertEq(vault.totalAssets(), 3000e18);

        // Bob redeems before donation #1 starts streaming.
        {
            uint256 sharesToRedeem = 500e18;
            uint256 expectedAssets = bobFirstRedeemBase + bobFirstRedeemHandout;

            uint256 before = token.balanceOf(ACTOR_BOB);
            _withdrawAs(ACTOR_BOB, sharesToRedeem);
            uint256 received = token.balanceOf(ACTOR_BOB) - before;

            assertEq(received, expectedAssets, "bob first redeem");
            assertEq(vault.balanceOf(ACTOR_BOB), 1500e18);
            assertEq(vault.totalAssets(), 2500e18);
        }

        // First streaming cycle from donation #1.
        _payoutRewards(1);
        vault.poke();

        // Alice partially exits after first stream.
        {
            uint256 sharesToRedeem = 400e18;
            uint256 expectedAssets = alicePartialRedeemBase + alicePartialRedeemHandout;

            uint256 before = token.balanceOf(ACTOR_ALICE);
            _withdrawAs(ACTOR_ALICE, sharesToRedeem);
            uint256 received = token.balanceOf(ACTOR_ALICE) - before;

            assertEq(received, expectedAssets, "alice partial redeem");
            assertEq(vault.balanceOf(ACTOR_ALICE), 600e18);
        }

        // Donation #2, then Alice deposits again before the first stream for donation #2.
        uint256 totalAssetsBeforeDonation2 = vault.totalAssets();
        token.mint(address(vault), 600e18);
        assertEq(vault.totalAssets(), totalAssetsBeforeDonation2);
        {
            uint256 depositAssets = 300e18;
            uint256 expectedShares = aliceSecondDepositBaseShares - aliceSecondDepositShareDiscount;
            uint256 beforeShares = vault.balanceOf(ACTOR_ALICE);

            _mintAndDepositFor(ACTOR_ALICE, depositAssets);

            uint256 mintedShares = vault.balanceOf(ACTOR_ALICE) - beforeShares;
            assertEq(mintedShares, expectedShares, "alice second deposit shares");
        }

        // Stream again, then Bob exits fully.
        _payoutRewards(1);
        vault.poke();
        {
            uint256 sharesToRedeem = bobFinalRedeemBase;
            uint256 expectedAssets = bobFinalRedeemBase + bobFinalRedeemHandout;
            assertEq(vault.balanceOf(ACTOR_BOB), sharesToRedeem, "bob final shares");

            uint256 before = token.balanceOf(ACTOR_BOB);
            _withdrawAs(ACTOR_BOB, sharesToRedeem);
            uint256 received = token.balanceOf(ACTOR_BOB) - before;

            assertEq(received, expectedAssets, "bob final redeem");
            assertEq(vault.balanceOf(ACTOR_BOB), 0);
        }

        // Alice exits fully.
        {
            uint256 sharesToRedeem = aliceFinalRedeemBase;
            uint256 expectedAssets = aliceFinalRedeemBase + aliceFinalRedeemHandout;
            assertEq(vault.balanceOf(ACTOR_ALICE), sharesToRedeem, "alice final shares");

            uint256 before = token.balanceOf(ACTOR_ALICE);
            _withdrawAs(ACTOR_ALICE, sharesToRedeem);
            uint256 received = token.balanceOf(ACTOR_ALICE) - before;

            assertEq(received, expectedAssets, "alice final redeem");
            assertEq(vault.balanceOf(ACTOR_ALICE), 0);
        }

        uint256 bobShareBaseTotal = bobFirstRedeemBase + bobFinalRedeemBase;
        uint256 bobTotalHandout = bobFirstRedeemHandout + bobFinalRedeemHandout;
        assertEq(token.balanceOf(ACTOR_BOB), bobShareBaseTotal + bobTotalHandout, "bob payout");

        uint256 aliceShareBaseTotal = (1_000e18 + aliceSecondDepositBaseShares) - aliceSecondDepositShareDiscount;
        uint256 aliceTotalHandout = alicePartialRedeemHandout + aliceFinalRedeemHandout;
        assertEq(token.balanceOf(ACTOR_ALICE), aliceShareBaseTotal + aliceTotalHandout, "alice payout");

        // Conservation check across deposits, donations, payouts, and remaining vault balance.
        uint256 totalInflow = 1000e18 + 2000e18 + 300e18 + 900e18 + 600e18;
        uint256 totalOutflow = token.balanceOf(ACTOR_ALICE) + token.balanceOf(ACTOR_BOB);
        assertEq(totalOutflow + token.balanceOf(address(vault)), totalInflow, "conservation");
    }

    function test__accrual_nativeAssetRewardsImproveExchangeRate() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);

        uint256 aliceShares = vault.balanceOf(ACTOR_ALICE);
        assertEq(aliceShares, 1000e18);

        // Mint native asset rewards to the vault
        vm.warp(block.timestamp + 1);
        token.mint(address(vault), 1000e18);
        vault.poke();

        // After one reward half-life, Alice should be able to redeem more than she deposited
        _payoutRewards(1);
        vault.poke(); // Accrue rewards

        // Calculate how much Alice can redeem
        uint256 redeemableAssets = vault.previewRedeem(aliceShares);
        assertGt(redeemableAssets, 1000e18);
        // Approximately 50% of the 1000e18 rewards should be distributed, and Alice has 100% of shares
        assertApproxEqRel(redeemableAssets, 1500e18, 0.001e18);

        // After another cycle, even more should be redeemable
        _payoutRewards(1);
        vault.poke(); // Accrue rewards
        uint256 redeemableAssetsAfterTwoCycles = vault.previewRedeem(aliceShares);
        assertGt(redeemableAssetsAfterTwoCycles, redeemableAssets);
        // Approximately 75% of the 1000e18 rewards should be distributed, and Alice has 100% of shares
        assertApproxEqRel(redeemableAssetsAfterTwoCycles, 1750e18, 0.001e18);
    }

    function test__accrual_nativeAssetRewardsMultipleEvenActors() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);
        _mintAndDepositFor(ACTOR_BOB, 1000e18);

        uint256 aliceShares = vault.balanceOf(ACTOR_ALICE);
        uint256 bobShares = vault.balanceOf(ACTOR_BOB);
        assertEq(aliceShares, 1000e18);
        assertEq(bobShares, 1000e18);

        // Mint native asset rewards to the vault
        vm.warp(block.timestamp + 1);
        token.mint(address(vault), 1000e18);
        vault.poke();

        _payoutRewards(1);
        vault.poke(); // Accrue rewards

        // Both should be able to redeem the same amount (equal shares)
        uint256 aliceRedeemable = vault.previewRedeem(aliceShares);
        uint256 bobRedeemable = vault.previewRedeem(bobShares);
        assertEq(aliceRedeemable, bobRedeemable);
        assertGt(aliceRedeemable, 1000e18);
        assertApproxEqRel(aliceRedeemable, 1250e18, 0.001e18);

        // Both should be able to actually redeem and get more than they deposited
        uint256 aliceBalanceBefore = token.balanceOf(ACTOR_ALICE);
        uint256 bobBalanceBefore = token.balanceOf(ACTOR_BOB);

        _withdrawAs(ACTOR_ALICE, aliceShares);
        _withdrawAs(ACTOR_BOB, bobShares);

        // Wait for unstaking delay and claim locks
        vm.warp(block.timestamp + UNSTAKING_DELAY);
        vault.unstakingManager().claimLock(0);
        vault.unstakingManager().claimLock(1);

        uint256 aliceBalanceAfter = token.balanceOf(ACTOR_ALICE);
        uint256 bobBalanceAfter = token.balanceOf(ACTOR_BOB);

        assertGt(aliceBalanceAfter - aliceBalanceBefore, 1000e18);
        assertGt(bobBalanceAfter - bobBalanceBefore, 1000e18);
        assertApproxEqRel(aliceBalanceAfter - aliceBalanceBefore, bobBalanceAfter - bobBalanceBefore, 0.001e18);
    }

    function test__accrual_nativeAssetRewardsMultipleUnevenActors() public {
        _mintAndDepositFor(ACTOR_ALICE, 1000e18);
        _mintAndDepositFor(ACTOR_BOB, 3000e18);

        uint256 aliceShares = vault.balanceOf(ACTOR_ALICE);
        uint256 bobShares = vault.balanceOf(ACTOR_BOB);
        assertEq(aliceShares, 1000e18);
        assertEq(bobShares, 3000e18);

        // Mint native asset rewards to the vault
        vm.warp(block.timestamp + 1);
        token.mint(address(vault), 1000e18);
        vault.poke();

        _payoutRewards(1);
        vault.poke(); // Accrue rewards

        // Bob should be able to redeem 3x more than Alice (proportional to shares)
        uint256 aliceRedeemable = vault.previewRedeem(aliceShares);
        uint256 bobRedeemable = vault.previewRedeem(bobShares);

        assertGt(aliceRedeemable, 1000e18);
        assertGt(bobRedeemable, 3000e18);
        // Bob should get 3x Alice's total (proportional to shares)
        assertApproxEqRel(bobRedeemable, aliceRedeemable * 3, 0.001e18);
        // Alice has 25% of shares, Bob has 75% of shares
        // After one cycle, ~50% of 1000e18 rewards = 500e18 distributed
        // Alice gets 25% = 125e18, Bob gets 75% = 375e18
        assertApproxEqRel(aliceRedeemable, 1125e18, 0.001e18);
        assertApproxEqRel(bobRedeemable, 3375e18, 0.001e18);
    }

    function test__accrual_redeemOnBehalfAccruesOwnerRewards() public {
        // Deposit for owner (address(this))
        _mintAndDepositFor(address(this), 1000e18);

        // Mint reward tokens to the vault
        vm.warp(block.timestamp + 1);
        reward.mint(address(vault), 1000e18);
        vault.poke();

        // Advance time to accrue rewards
        _payoutRewards(1);

        // Approve ACTOR_ALICE to redeem on behalf of owner
        vault.approve(ACTOR_ALICE, 1000e18);

        // Record owner's reward balance before redemption
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(reward);

        // Accrue rewards for owner to see what they should have
        vault.poke();

        // Calculate expected rewards: owner has 100% of shares, so gets 100% of distributed rewards
        // After one cycle, ~50% of 1000e18 = 500e18 should be distributed
        uint256 expectedOwnerRewards = 500e18;

        // Redeem on behalf of owner (caller != owner)
        vm.startPrank(ACTOR_ALICE);
        vault.redeem(1000e18, address(this), address(this));
        vm.stopPrank();

        // Claim rewards for owner and verify they received the expected amount
        vm.startPrank(address(this));
        uint256[] memory claimedRewards = vault.claimRewards(rewardTokens);
        vm.stopPrank();

        // Owner should have received their rewards (not lost due to missing accrual)
        assertApproxEqRel(claimedRewards[0], expectedOwnerRewards, 0.001e18);
        assertApproxEqRel(reward.balanceOf(address(this)), expectedOwnerRewards, 0.001e18);
    }

    function test_upgradeToLatestRegisteredVersion() public {
        _mintAndDepositFor(address(this), 100e18);
        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 unstakingDelayBefore = vault.unstakingDelay();

        StakingVaultV2Mock newImpl = new StakingVaultV2Mock();
        _registerV2Deployer(address(newImpl));

        vm.prank(address(timelock));
        vault.upgradeToAndCall(address(newImpl), "");

        StakingVaultV2Mock upgradedVault = StakingVaultV2Mock(address(vault));
        assertEq(upgradedVault.version(), "2.0.0");
        assertEq(upgradedVault.totalSupply(), totalSupplyBefore);
        assertEq(upgradedVault.unstakingDelay(), unstakingDelayBefore);
        assertEq(address(upgradedVault.asset()), address(token));
        assertEq(address(upgradedVault.versionRegistry()), address(versionRegistry));
        assertTrue(upgradedVault.hasRole(upgradedVault.DEFAULT_ADMIN_ROLE(), address(timelock)));
    }

    function test_cannotUpgradeIfNotAdmin() public {
        StakingVaultV2Mock newImpl = new StakingVaultV2Mock();

        vm.startPrank(ACTOR_ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, ACTOR_ALICE, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vault.upgradeToAndCall(address(newImpl), "");
        vm.stopPrank();
    }

    function test_cannotUpgradeIfVersionIsNotLatest() public {
        StakingVaultV2Mock newImpl = new StakingVaultV2Mock();

        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(StakingVault.Vault__NotLatestStakingVault.selector, address(newImpl)));
        vault.upgradeToAndCall(address(newImpl), "");
    }

    function test_cannotUpgradeIfImplementationDoesNotMatchRegisteredLatestVersion() public {
        StakingVaultV2Mock registeredImpl = new StakingVaultV2Mock();
        _registerV2Deployer(address(registeredImpl));

        StakingVaultV2Mock rogueImpl = new StakingVaultV2Mock();

        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(StakingVault.Vault__NotLatestStakingVault.selector, address(rogueImpl)));
        vault.upgradeToAndCall(address(rogueImpl), "");
    }

    function test_cannotUpgradeIfLatestVersionIsDeprecated() public {
        StakingVaultV2Mock newImpl = new StakingVaultV2Mock();
        _registerV2Deployer(address(newImpl));

        bytes32 versionHash = _v2VersionHash();
        versionRegistry.deprecateVersion(versionHash);

        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(StakingVault.Vault__VersionDeprecated.selector, versionHash));
        vault.upgradeToAndCall(address(newImpl), "");
    }

    function test_cannotInitializeTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize("New Name", "NEW", IERC20(address(token)), address(this), REWARD_HALF_LIFE, 0);
    }

    function test_implementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        StakingVault(vaultImpl)
            .initialize("Staked Test Token", "sTEST", IERC20(address(token)), address(this), REWARD_HALF_LIFE, 0);
    }
}
