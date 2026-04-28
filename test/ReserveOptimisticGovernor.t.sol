// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { OptimisticSelectorRegistry } from "@governance/OptimisticSelectorRegistry.sol";
import { ReserveOptimisticGovernor } from "@governance/ReserveOptimisticGovernor.sol";
import { TimelockControllerOptimistic } from "@governance/TimelockControllerOptimistic.sol";
import { IReserveOptimisticGovernorDeployer } from "@interfaces/IDeployer.sol";
import { IOptimisticSelectorRegistry } from "@interfaces/IOptimisticSelectorRegistry.sol";
import { IReserveOptimisticGovernor } from "@interfaces/IReserveOptimisticGovernor.sol";
import { ITimelockControllerOptimistic } from "@interfaces/ITimelockControllerOptimistic.sol";
import { ReserveOptimisticGovernorDeployer } from "@src/Deployer.sol";
import { Guardian } from "@src/Guardian.sol";
import { ReserveOptimisticGovernanceVersionRegistry } from "@src/VersionRegistry.sol";
import { RewardTokenRegistry } from "@staking/RewardTokenRegistry.sol";
import { StakingVault } from "@staking/StakingVault.sol";
import {
    CANCELLER_ROLE,
    MAX_PROPOSAL_THROTTLE_CAPACITY,
    MIN_OPTIMISTIC_VETO_PERIOD,
    OPTIMISTIC_PROPOSER_ROLE
} from "@utils/Constants.sol";

import { MockERC20 } from "@mocks/MockERC20.sol";
import { MockRoleRegistry } from "@mocks/MockRoleRegistry.sol";
import { ReserveOptimisticGovernorV2Mock } from "@mocks/ReserveOptimisticGovernorV2Mock.sol";
import { TimelockControllerOptimisticV2Mock } from "@mocks/TimelockControllerOptimisticV2Mock.sol";

contract DummyTarget {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

abstract contract ReserveOptimisticGovernorTestBase is Test {
    // Contracts
    MockERC20 public underlying;
    StakingVault public stakingVault;
    OptimisticSelectorRegistry public registry;
    Guardian public guardianContract;
    ReserveOptimisticGovernorDeployer public deployer;
    ReserveOptimisticGovernor public governor;
    TimelockControllerOptimistic public timelock;
    address public originalStakingVaultAdmin;

    // Accounts
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public guardian = makeAddr("guardian");
    address public additionalGuardian = makeAddr("additionalGuardian");
    address public optimisticGuardianManager = makeAddr("optimisticGuardianManager");
    address public optimisticGuardian = makeAddr("optimisticGuardian");
    address public optimisticProposer = makeAddr("optimisticProposer");
    address public optimisticProposer2 = makeAddr("optimisticProposer2");

    // Governance params
    uint48 internal constant VETO_DELAY = 1 hours;
    uint32 internal constant VETO_PERIOD = 2 hours;
    uint256 internal constant VETO_THRESHOLD = 0.2e18; // 20%

    uint48 internal constant VOTING_DELAY = 1 days;
    uint32 internal constant VOTING_PERIOD = 1 weeks;
    uint48 internal constant VOTE_EXTENSION = 1 days;
    uint256 internal constant PROPOSAL_THRESHOLD = 0.01e18; // 1%
    uint256 internal constant QUORUM_NUMERATOR = 0.1e18; // 10%
    uint256 internal constant PROPOSAL_THROTTLE_CAPACITY = 2; // proposals per 12h

    uint256 internal constant TIMELOCK_DELAY = 2 days;
    string internal constant CONFIRMATION_PREFIX = "Confirmation For: ";

    // StakingVault params
    uint256 internal constant REWARD_HALF_LIFE = 1 days;
    uint256 internal constant UNSTAKING_DELAY = 0;

    // Voting distribution
    uint256 internal constant ALICE_STAKE = 400_000e18;
    uint256 internal constant BOB_STAKE = 400_000e18;
    uint256 internal constant CAROL_STAKE = 200_000e18;

    function _useExistingStakingVaultDeployment() internal pure virtual returns (bool);

    function setUp() public {
        underlying = new MockERC20("Underlying Token", "UNDL");

        MockRoleRegistry roleRegistry = new MockRoleRegistry(address(this));
        ReserveOptimisticGovernanceVersionRegistry versionRegistry =
            new ReserveOptimisticGovernanceVersionRegistry(roleRegistry);
        RewardTokenRegistry rewardTokenRegistry = new RewardTokenRegistry(roleRegistry);

        StakingVault stakingVaultImpl = new StakingVault();
        ReserveOptimisticGovernor governorImpl = new ReserveOptimisticGovernor();
        TimelockControllerOptimistic timelockImpl = new TimelockControllerOptimistic();
        OptimisticSelectorRegistry registryImpl = new OptimisticSelectorRegistry();
        address[] memory optimisticGuardians = new address[](1);
        optimisticGuardians[0] = optimisticGuardian;

        guardianContract = new Guardian(guardian, optimisticGuardianManager, optimisticGuardians);

        deployer = new ReserveOptimisticGovernorDeployer(
            address(versionRegistry),
            address(rewardTokenRegistry),
            address(guardianContract),
            address(stakingVaultImpl),
            address(governorImpl),
            address(timelockImpl),
            address(registryImpl)
        );
        versionRegistry.registerVersion(deployer);

        address[] memory optimisticProposers = new address[](2);
        optimisticProposers[0] = optimisticProposer;
        optimisticProposers[1] = optimisticProposer2;

        bytes4[] memory transferSelectors = new bytes4[](1);
        transferSelectors[0] = IERC20.transfer.selector;

        IOptimisticSelectorRegistry.SelectorData[] memory selectorData =
            new IOptimisticSelectorRegistry.SelectorData[](1);
        selectorData[0] = IOptimisticSelectorRegistry.SelectorData(address(underlying), transferSelectors);

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
                selectorData: selectorData,
                optimisticProposers: optimisticProposers,
                additionalGuardians: _additionalGuardians(),
                timelockDelay: TIMELOCK_DELAY,
                proposalThrottleCapacity: PROPOSAL_THROTTLE_CAPACITY
            });

        IReserveOptimisticGovernorDeployer.NewStakingVaultParams memory newStakingVaultParams =
            IReserveOptimisticGovernorDeployer.NewStakingVaultParams({
                underlying: IERC20Metadata(address(underlying)),
                rewardTokens: new address[](0),
                rewardHalfLife: REWARD_HALF_LIFE,
                unstakingDelay: UNSTAKING_DELAY
            });

        // Baseline deployment used directly in new-vault mode and reused as the preexisting vault in existing-vault
        // mode.
        (address stakingVaultAddr, address governorAddr, address timelockAddr, address selectorRegistryAddr) =
            deployer.deployWithNewStakingVault(baseParams, newStakingVaultParams, bytes32(0));
        originalStakingVaultAdmin = timelockAddr;

        if (_useExistingStakingVaultDeployment()) {
            (address existingGovernorAddr, address existingTimelockAddr, address existingSelectorRegistryAddr) =
                deployer.deployWithExistingStakingVault(baseParams, stakingVaultAddr, bytes32(uint256(1)));

            governor = ReserveOptimisticGovernor(payable(existingGovernorAddr));
            timelock = TimelockControllerOptimistic(payable(existingTimelockAddr));
            registry = OptimisticSelectorRegistry(existingSelectorRegistryAddr);

            address existingStakingVaultAddr = address(governor.token());
            assertEq(existingStakingVaultAddr, stakingVaultAddr, "existing-vault deploy should reuse staking vault");

            stakingVault = StakingVault(existingStakingVaultAddr);
        } else {
            governor = ReserveOptimisticGovernor(payable(governorAddr));
            timelock = TimelockControllerOptimistic(payable(timelockAddr));
            registry = OptimisticSelectorRegistry(selectorRegistryAddr);

            stakingVault = StakingVault(stakingVaultAddr);
        }

        _setupVoter(alice, ALICE_STAKE);
        _setupVoter(bob, BOB_STAKE);
        _setupVoter(carol, CAROL_STAKE);

        // Charge throttles
        vm.warp(block.timestamp + 12 hours);
    }

    // ===== Deployment / Initialization =====

    function test_deployment_initializesConfigAndRoles() public view {
        (uint48 vetoDelay, uint32 vetoPeriod, uint256 vetoThreshold) = governor.optimisticParams();
        assertEq(vetoDelay, VETO_DELAY);
        assertEq(vetoPeriod, VETO_PERIOD);
        assertEq(vetoThreshold, VETO_THRESHOLD);
        assertEq(governor.proposalThrottleCharges(optimisticProposer), PROPOSAL_THROTTLE_CAPACITY);

        assertEq(governor.votingDelay(), VOTING_DELAY);
        assertEq(governor.votingPeriod(), VOTING_PERIOD);
        assertEq(governor.lateQuorumVoteExtension(), VOTE_EXTENSION);
        assertEq(governor.quorumNumerator(), QUORUM_NUMERATOR);

        assertEq(address(governor.token()), address(stakingVault));
        assertEq(governor.timelock(), address(timelock));

        assertTrue(timelock.hasRole(OPTIMISTIC_PROPOSER_ROLE, optimisticProposer));
        assertTrue(timelock.hasRole(OPTIMISTIC_PROPOSER_ROLE, optimisticProposer2));
        assertTrue(timelock.hasRole(CANCELLER_ROLE, address(guardianContract)));
        assertTrue(timelock.hasRole(CANCELLER_ROLE, additionalGuardian));
        assertFalse(timelock.hasRole(CANCELLER_ROLE, guardian));
        assertTrue(guardianContract.hasRole(guardianContract.DEFAULT_ADMIN_ROLE(), guardian));
        assertTrue(guardianContract.hasRole(guardianContract.OPTIMISTIC_GUARDIAN_MANAGER_ROLE(), guardian));
        assertTrue(
            guardianContract.hasRole(guardianContract.OPTIMISTIC_GUARDIAN_MANAGER_ROLE(), optimisticGuardianManager)
        );
        assertTrue(guardianContract.hasRole(guardianContract.OPTIMISTIC_GUARDIAN_ROLE(), optimisticGuardian));

        assertTrue(registry.isAllowed(address(underlying), IERC20.transfer.selector));

        uint256 supply = stakingVault.getPastTotalSupply(block.timestamp - 1);
        uint256 expectedThreshold = (PROPOSAL_THRESHOLD * supply + (1e18 - 1)) / 1e18;
        assertEq(governor.proposalThreshold(), expectedThreshold);

        if (_useExistingStakingVaultDeployment()) {
            assertTrue(stakingVault.hasRole(stakingVault.DEFAULT_ADMIN_ROLE(), originalStakingVaultAdmin));
            assertFalse(stakingVault.hasRole(stakingVault.DEFAULT_ADMIN_ROLE(), address(timelock)));
        } else {
            assertTrue(stakingVault.hasRole(stakingVault.DEFAULT_ADMIN_ROLE(), address(timelock)));
        }
    }

    function _additionalGuardians() internal view returns (address[] memory guardians) {
        guardians = new address[](1);
        guardians[0] = additionalGuardian;
    }

    function test_guardian_roleAdminsConfigured() public view {
        assertEq(
            guardianContract.getRoleAdmin(guardianContract.DEFAULT_ADMIN_ROLE()), guardianContract.DEFAULT_ADMIN_ROLE()
        );
        assertEq(
            guardianContract.getRoleAdmin(guardianContract.OPTIMISTIC_GUARDIAN_MANAGER_ROLE()),
            guardianContract.DEFAULT_ADMIN_ROLE()
        );
        assertEq(
            guardianContract.getRoleAdmin(guardianContract.OPTIMISTIC_GUARDIAN_ROLE()),
            guardianContract.DEFAULT_ADMIN_ROLE()
        );
    }

    function test_optimisticGuardianManagerCanGrantOptimisticGuardianRole() public {
        address newOptimisticGuardian = makeAddr("newOptimisticGuardian");
        bytes32 optimisticGuardianRole = guardianContract.OPTIMISTIC_GUARDIAN_ROLE();

        assertFalse(guardianContract.hasRole(optimisticGuardianRole, newOptimisticGuardian));

        vm.prank(optimisticGuardianManager);
        guardianContract.grantOptimisticGuardian(newOptimisticGuardian);

        assertTrue(guardianContract.hasRole(optimisticGuardianRole, newOptimisticGuardian));
    }

    function test_nonManagerCannotGrantOptimisticGuardianRole() public {
        address newOptimisticGuardian = makeAddr("newOptimisticGuardian");
        bytes32 optimisticGuardianManagerRole = guardianContract.OPTIMISTIC_GUARDIAN_MANAGER_ROLE();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, optimisticGuardianManagerRole
            )
        );
        guardianContract.grantOptimisticGuardian(newOptimisticGuardian);
    }

    function test_optimisticGuardianManagerCannotRevokeOptimisticGuardianRole() public {
        bytes32 optimisticGuardianRole = guardianContract.OPTIMISTIC_GUARDIAN_ROLE();
        bytes32 defaultAdminRole = guardianContract.DEFAULT_ADMIN_ROLE();

        assertTrue(guardianContract.hasRole(optimisticGuardianRole, optimisticGuardian));

        vm.prank(optimisticGuardianManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, optimisticGuardianManager, defaultAdminRole
            )
        );
        guardianContract.revokeRole(optimisticGuardianRole, optimisticGuardian);

        assertTrue(guardianContract.hasRole(optimisticGuardianRole, optimisticGuardian));
    }

    function test_optimisticGuardianManagerCannotCancelOptimisticProposal() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Manager cannot cancel optimistic proposal";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);
        uint256 proposalStateBeforeCancelAttempt = uint256(governor.state(proposalId));

        vm.prank(optimisticGuardianManager);
        vm.expectRevert(abi.encodeWithSelector(Guardian.Guardian__UnauthorizedCaller.selector));
        guardianContract.cancel(address(governor), targets, values, calldatas, keccak256(bytes(description)));

        assertEq(uint256(governor.state(proposalId)), proposalStateBeforeCancelAttempt);
    }

    function test_vetoThreshold_isZeroForNonexistentProposal() public view {
        uint256 proposalId = 123456;
        assertEq(governor.vetoThreshold(proposalId), 0);
    }

    // ===== Standard (Slow) Flow =====

    function test_standardProposal_fullLifecycle() public {
        uint256 transferAmount = 1_000e18;
        underlying.mint(address(timelock), transferAmount);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, transferAmount)));
        string memory description = "Standard transfer to alice";

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));

        _warpToActive(proposalId);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Active));

        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(bob);
        governor.castVote(proposalId, 1);

        _warpPastDeadline(proposalId);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));

        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Queued));

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        uint256 aliceBalanceBefore = underlying.balanceOf(alice);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed));
        assertEq(underlying.balanceOf(alice), aliceBalanceBefore + transferAmount);
    }

    function test_standardProposal_usesStandardDelegationWeights() public {
        vm.prank(alice);
        stakingVault.delegate(bob);
        vm.prank(alice);
        stakingVault.delegateOptimistic(carol);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Standard delegation split";

        vm.prank(bob);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        _warpToActive(proposalId);
        uint256 snapshot = governor.proposalSnapshot(proposalId);

        assertEq(governor.getVotes(bob, snapshot), ALICE_STAKE + BOB_STAKE);
        assertEq(governor.getVotes(carol, snapshot), CAROL_STAKE);
        assertEq(governor.getOptimisticVotes(carol, snapshot), ALICE_STAKE + CAROL_STAKE);

        vm.prank(bob);
        governor.castVote(proposalId, 1);

        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(proposalId);
        assertEq(againstVotes, 0);
        assertEq(forVotes, ALICE_STAKE + BOB_STAKE);
        assertEq(abstainVotes, 0);
    }

    function test_standardProposal_defeatedWhenAgainstWins() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Defeated standard proposal";

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        _warpToActive(proposalId);

        vm.prank(alice);
        governor.castVote(proposalId, 0);
        vm.prank(bob);
        governor.castVote(proposalId, 0);
        vm.prank(carol);
        governor.castVote(proposalId, 1);

        _warpPastDeadline(proposalId);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_standardProposal_requiresProposerThreshold() public {
        address noVotes = makeAddr("noVotes");
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        uint256 threshold = governor.proposalThreshold();

        vm.prank(noVotes);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernor.GovernorInsufficientProposerVotes.selector, noVotes, 0, threshold)
        );
        governor.propose(targets, values, calldatas, "No votes proposer");
    }

    function test_standardProposal_rejectsConfirmationPrefixDescription() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveOptimisticGovernor.OptimisticGovernor__ConfirmationPrefixNotAllowed.selector)
        );
        governor.propose(targets, values, calldatas, _confirmationDescription("manual confirmation"));
    }

    function test_standardProposal_rejectsExactConfirmationPrefixDescription() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveOptimisticGovernor.OptimisticGovernor__ConfirmationPrefixNotAllowed.selector)
        );
        governor.propose(targets, values, calldatas, _confirmationDescription(""));
    }

    function test_standardProposal_allowsConfirmationPrefixIfNotAtStart() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = string.concat("Intro ", _confirmationDescription("manual confirmation"));

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_standardProposal_allowsDescriptionShorterThanConfirmationPrefix() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Conf:");
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_standardProposal_rejectsFunctionCallToEOA() public {
        address eoaTarget = makeAddr("eoaTarget");
        bytes memory callData = abi.encodeWithSelector(bytes4(keccak256("doThing(uint256)")), 1);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(eoaTarget, 0, callData);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveOptimisticGovernor.OptimisticGovernor__InvalidCall.selector, eoaTarget, callData
            )
        );
        governor.propose(targets, values, calldatas, "EOA call should fail");
    }

    function test_standardProposal_canSendEthToEOAWithEmptyCalldata() public {
        address eoaTarget = makeAddr("eoaTarget");
        vm.deal(address(timelock), 1 ether);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(eoaTarget, 0.1 ether, bytes(""));
        string memory description = "Send ETH to EOA";

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        _warpToActive(proposalId);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(bob);
        governor.castVote(proposalId, 1);

        _warpPastDeadline(proposalId);
        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        uint256 beforeBalance = eoaTarget.balance;
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(eoaTarget.balance, beforeBalance + 0.1 ether);
    }

    function test_standardProposal_guardianCanCancel() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Cancel me";

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.prank(guardian);
        guardianContract.cancel(address(governor), targets, values, calldatas, keccak256(bytes(description)));

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Canceled));
    }

    function test_standardProposal_randomUserCannotCancel() public {
        address random = makeAddr("random");
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Unauthorized cancel";

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.prank(random);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, random));
        governor.cancel(targets, values, calldatas, keccak256(bytes(description)));
    }

    function test_standardProposal_optimisticGuardianCannotCancelWhilePending() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Optimistic guardian cannot cancel pending standard";

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.prank(optimisticGuardian);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, optimisticGuardian)
        );
        governor.cancel(targets, values, calldatas, keccak256(bytes(description)));
    }

    // ===== Optimistic (Fast) Creation Validations =====

    function test_proposeOptimistic_requiresRole() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveOptimisticGovernor.OptimisticGovernor__NotOptimisticProposer.selector, alice)
        );
        governor.proposeOptimistic(targets, values, calldatas, "Role-gated optimistic proposal");
    }

    function test_proposeOptimistic_rejectsEmptyProposal() public {
        address[] memory targets = new address[](0);
        uint256[] memory values = new uint256[](0);
        bytes[] memory calldatas = new bytes[](0);

        vm.prank(optimisticProposer);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidProposalLength.selector, 0, 0, 0));
        governor.proposeOptimistic(targets, values, calldatas, "empty");
    }

    function test_proposeOptimistic_rejectsMismatchedArrays() public {
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](0);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1));

        vm.prank(optimisticProposer);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidProposalLength.selector, 1, 1, 0));
        governor.proposeOptimistic(targets, values, calldatas, "mismatched arrays");
    }

    function test_proposeOptimistic_rejectsEOATarget() public {
        address eoaTarget = makeAddr("eoaTarget");
        bytes memory callData = abi.encodeWithSelector(bytes4(keccak256("doThing(uint256)")), 1);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(eoaTarget, 0, callData);

        vm.prank(optimisticProposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveOptimisticGovernor.OptimisticGovernor__InvalidCall.selector, eoaTarget, callData
            )
        );
        governor.proposeOptimistic(targets, values, calldatas, "EOA target");
    }

    function test_proposeOptimistic_rejectsEmptyCalldata() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, bytes(""));

        vm.prank(optimisticProposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveOptimisticGovernor.OptimisticGovernor__InvalidCall.selector, address(underlying), bytes("")
            )
        );
        governor.proposeOptimistic(targets, values, calldatas, "empty calldata");
    }

    function test_proposeOptimistic_rejectsDisallowedSelector() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.approve, (alice, 1_000e18)));

        vm.prank(optimisticProposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveOptimisticGovernor.OptimisticGovernor__InvalidCall.selector,
                address(underlying),
                abi.encodeCall(IERC20.approve, (alice, 1_000e18))
            )
        );
        governor.proposeOptimistic(targets, values, calldatas, "approve not whitelisted");
    }

    function test_proposeOptimistic_rejectsConfirmationPrefixDescription() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        vm.prank(optimisticProposer);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveOptimisticGovernor.OptimisticGovernor__ConfirmationPrefixNotAllowed.selector)
        );
        governor.proposeOptimistic(targets, values, calldatas, _confirmationDescription("manual confirmation"));
    }

    function test_proposeOptimistic_rejectsExactConfirmationPrefixDescription() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        vm.prank(optimisticProposer);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveOptimisticGovernor.OptimisticGovernor__ConfirmationPrefixNotAllowed.selector)
        );
        governor.proposeOptimistic(targets, values, calldatas, _confirmationDescription(""));
    }

    function test_proposeOptimistic_allowsConfirmationPrefixIfNotAtStart() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = string.concat("Intro ", _confirmationDescription("manual confirmation"));

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_proposeOptimistic_allowsDescriptionShorterThanConfirmationPrefix() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, "Conf:");
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_proposeOptimistic_rejectsDescriptionSuffixForDifferentProposer() public {
        string memory description = string.concat("Restricted suffix#proposer=", vm.toString(alice));
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        vm.prank(optimisticProposer);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorRestrictedProposer.selector, optimisticProposer));
        governor.proposeOptimistic(targets, values, calldatas, description);
    }

    function test_proposeOptimistic_allowsDescriptionSuffixForCaller() public {
        string memory description = string.concat("Restricted suffix#proposer=", vm.toString(optimisticProposer));
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_proposeOptimistic_rejectsDuplicateProposalId() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "duplicate optimistic proposal";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        vm.prank(optimisticProposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                proposalId,
                IGovernor.ProposalState.Pending,
                bytes32(0)
            )
        );
        governor.proposeOptimistic(targets, values, calldatas, description);
    }

    function test_optimisticProposal_cannotSendEthToEOA() public {
        address eoaTarget = makeAddr("eoaTarget");
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(eoaTarget, 0.1 ether, bytes(""));

        vm.prank(optimisticProposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveOptimisticGovernor.OptimisticGovernor__InvalidCall.selector, eoaTarget, bytes("")
            )
        );
        governor.proposeOptimistic(targets, values, calldatas, "EOA ETH transfer");
    }

    // ===== Optimistic (Fast) Uncontested Flow =====

    function test_optimisticProposal_uncontestedLifecycle() public {
        uint256 transferAmount = 1_000e18;
        underlying.mint(address(timelock), transferAmount);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, transferAmount)));
        string memory description = "Optimistic transfer";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        assertTrue(governor.vetoThreshold(proposalId) != 0);
        assertEq(governor.vetoThreshold(proposalId), VETO_THRESHOLD);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));

        _warpToActive(proposalId);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Active));

        _warpPastDeadline(proposalId);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));
        assertTrue(governor.vetoThreshold(proposalId) != 0);

        uint256 aliceBalanceBefore = underlying.balanceOf(alice);
        bytes32 descriptionHash = keccak256(bytes(description));
        vm.prank(optimisticProposer);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed));
        assertEq(underlying.balanceOf(alice), aliceBalanceBefore + transferAmount);
    }

    function test_optimisticProposal_usesOptimisticDelegationWeights() public {
        vm.prank(alice);
        stakingVault.delegate(bob);
        vm.prank(alice);
        stakingVault.delegateOptimistic(carol);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Optimistic delegation split";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        _warpToActive(proposalId);
        uint256 snapshot = governor.proposalSnapshot(proposalId);

        assertEq(governor.getOptimisticVotes(carol, snapshot), ALICE_STAKE + CAROL_STAKE);
        assertEq(governor.getOptimisticVotes(bob, snapshot), BOB_STAKE);
        assertEq(governor.getVotes(bob, snapshot), ALICE_STAKE + BOB_STAKE);

        vm.prank(carol);
        governor.castVote(proposalId, 0);

        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(proposalId);
        assertEq(againstVotes, ALICE_STAKE + CAROL_STAKE);
        assertEq(forVotes, 0);
        assertEq(abstainVotes, 0);
    }

    function test_optimisticProposal_executeCanBeCalledByNonProposer() public {
        uint256 transferAmount = 1_000e18;
        underlying.mint(address(timelock), transferAmount);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, transferAmount)));
        string memory description = "Proposer-restricted execution";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);
        _warpPastDeadline(proposalId);

        uint256 aliceBalanceBefore = underlying.balanceOf(alice);
        bytes32 descriptionHash = keccak256(bytes(description));
        vm.prank(optimisticProposer2);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed));
        assertEq(underlying.balanceOf(alice), aliceBalanceBefore + transferAmount);
    }

    function test_optimisticProposal_executeRevertsWhenNotSucceeded() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Premature execute";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        vm.prank(optimisticProposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                proposalId,
                IGovernor.ProposalState.Pending,
                bytes32(
                    uint256(
                        (1 << uint8(IGovernor.ProposalState.Succeeded)) | (1 << uint8(IGovernor.ProposalState.Queued))
                    )
                )
            )
        );
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
    }

    function test_optimisticProposal_proposerCanCancelDuringVeto() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Cancelable optimistic proposal";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        vm.prank(optimisticProposer);
        governor.cancel(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Canceled));
    }

    function test_optimisticProposal_guardianCanCancelDuringVeto() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Guardian-cancelable optimistic proposal";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        vm.prank(guardian);
        guardianContract.cancel(address(governor), targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Canceled));
    }

    function test_optimisticProposal_optimisticGuardianCanCancelDuringVeto() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Optimistic guardian-cancelable optimistic proposal";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        vm.prank(optimisticGuardian);
        guardianContract.cancel(address(governor), targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Canceled));
    }

    function test_optimisticProposal_randomUserCannotCancel() public {
        address random = makeAddr("random");
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Unauthorized optimistic cancel";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        vm.prank(random);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, random));
        governor.cancel(targets, values, calldatas, keccak256(bytes(description)));
    }

    // ===== Optimistic -> Confirmation Transition =====

    function test_optimisticProposal_againstThresholdSchedulesConfirmation() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Threshold-triggered confirmation";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);
        _warpToActive(proposalId);

        uint256 expectedConfirmationVoteStart = block.timestamp + VOTING_DELAY;
        uint256 expectedConfirmationVoteEnd = expectedConfirmationVoteStart + VOTING_PERIOD;

        // Alice's 40% AGAINST vote exceeds the 20% veto threshold and schedules confirmation.
        vm.prank(alice);
        governor.castVote(proposalId, 0);

        uint256 confirmationProposalId = _confirmationProposalId(targets, values, calldatas, description);
        assertNotEq(proposalId, confirmationProposalId);

        assertTrue(governor.vetoThreshold(proposalId) != 0);
        assertEq(governor.vetoThreshold(proposalId), type(uint256).max);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Defeated));

        assertEq(governor.vetoThreshold(confirmationProposalId), 0);
        assertEq(uint256(governor.state(confirmationProposalId)), uint256(IGovernor.ProposalState.Pending));
        assertEq(governor.proposalSnapshot(confirmationProposalId), expectedConfirmationVoteStart);
        assertEq(governor.proposalDeadline(confirmationProposalId), expectedConfirmationVoteEnd);

        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(proposalId);
        assertEq(againstVotes, ALICE_STAKE);
        assertEq(forVotes, 0);
        assertEq(abstainVotes, 0);
    }

    function test_optimisticProposal_proposerCannotCancelWhenDefeated() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Defeated optimistic proposal cannot be canceled";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);
        _warpToActive(proposalId);

        vm.prank(alice);
        governor.castVote(proposalId, 0); // trigger optimistic -> confirmation transition

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Defeated));

        vm.prank(optimisticProposer);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, optimisticProposer)
        );
        governor.cancel(targets, values, calldatas, keccak256(bytes(description)));
    }

    function test_optimisticProposal_optimisticGuardianCannotCancelWhenDefeated() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Defeated optimistic proposal cannot be canceled by optimistic guardian";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);
        _warpToActive(proposalId);

        vm.prank(alice);
        governor.castVote(proposalId, 0); // trigger optimistic -> confirmation transition

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Defeated));

        vm.prank(optimisticGuardian);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, optimisticGuardian)
        );
        governor.cancel(targets, values, calldatas, keccak256(bytes(description)));
    }

    function test_confirmationVote_startsPendingAfterTransition() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Confirmation starts pending";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);
        _warpToActive(proposalId);

        vm.prank(alice);
        governor.castVote(proposalId, 0); // trigger optimistic -> confirmation transition

        uint256 confirmationProposalId = _confirmationProposalId(targets, values, calldatas, description);

        assertEq(uint256(governor.state(confirmationProposalId)), uint256(IGovernor.ProposalState.Pending));

        vm.prank(bob);
        vm.expectRevert();
        governor.castVote(confirmationProposalId, 1);

        _warpToActive(confirmationProposalId);
        vm.prank(bob);
        governor.castVote(confirmationProposalId, 1);

        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(confirmationProposalId);
        assertEq(againstVotes, 0);
        assertEq(forVotes, BOB_STAKE);
        assertEq(abstainVotes, 0);
    }

    function test_confirmationVote_transitionWorksWhenOptimisticProposerHasNoVotingWeight() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Transition with zero-vote proposer";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);
        _warpToActive(proposalId);

        uint256 snapshot = governor.proposalSnapshot(proposalId);
        assertEq(governor.getVotes(optimisticProposer, snapshot - 1), 0);

        vm.prank(alice);
        governor.castVote(proposalId, 0); // trigger optimistic -> confirmation transition

        uint256 confirmationProposalId = _confirmationProposalId(targets, values, calldatas, description);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Defeated));
        assertEq(uint256(governor.state(confirmationProposalId)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_optimisticProposal_forAndAbstainRevert() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Only AGAINST allowed";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);
        _warpToActive(proposalId);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveOptimisticGovernor.OptimisticGovernor__OptimisticProposalCanOnlyBeVetoed.selector, proposalId
            )
        );
        governor.castVote(proposalId, 1);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveOptimisticGovernor.OptimisticGovernor__OptimisticProposalCanOnlyBeVetoed.selector, proposalId
            )
        );
        governor.castVote(proposalId, 2);

        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(proposalId);
        assertEq(againstVotes, 0);
        assertEq(forVotes, 0);
        assertEq(abstainVotes, 0);

        assertTrue(governor.vetoThreshold(proposalId) != 0);
        assertEq(governor.vetoThreshold(proposalId), VETO_THRESHOLD);

        _warpPastDeadline(proposalId);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));
    }

    function test_confirmationVote_voteDoesNotCarryOverFromVetoPhase() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "carry-over vote state";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);
        _warpToActive(proposalId);

        vm.prank(alice);
        governor.castVote(proposalId, 0); // triggers confirmation

        uint256 confirmationProposalId = _confirmationProposalId(targets, values, calldatas, description);
        _warpToActive(confirmationProposalId);
        assertEq(uint256(governor.state(confirmationProposalId)), uint256(IGovernor.ProposalState.Active));

        vm.prank(alice);
        governor.castVote(confirmationProposalId, 1);

        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(confirmationProposalId);
        assertEq(againstVotes, 0);
        assertEq(forVotes, ALICE_STAKE);
        assertEq(abstainVotes, 0);
    }

    function test_confirmationVote_successLifecycle() public {
        uint256 transferAmount = 2_000e18;
        address recipient = makeAddr("recipient");
        underlying.mint(address(timelock), transferAmount);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (recipient, transferAmount)));
        string memory description = "Confirmation vote succeeds";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        _warpToActive(proposalId);
        vm.prank(alice);
        governor.castVote(proposalId, 0); // trigger confirmation

        uint256 confirmationProposalId = _confirmationProposalId(targets, values, calldatas, description);

        _warpToActive(confirmationProposalId);
        vm.prank(bob);
        governor.castVote(confirmationProposalId, 1);
        vm.prank(carol);
        governor.castVote(confirmationProposalId, 1);

        _warpPastDeadline(confirmationProposalId);
        assertEq(uint256(governor.state(confirmationProposalId)), uint256(IGovernor.ProposalState.Succeeded));

        bytes32 descriptionHash = keccak256(bytes(_confirmationDescription(description)));
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        uint256 recipientBalanceBefore = underlying.balanceOf(recipient);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(uint256(governor.state(confirmationProposalId)), uint256(IGovernor.ProposalState.Executed));
        assertEq(underlying.balanceOf(recipient), recipientBalanceBefore + transferAmount);
    }

    function test_confirmationVote_defeatedWhenAgainstWins() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Confirmation defeated by against votes";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        _warpToActive(proposalId);
        vm.prank(alice);
        governor.castVote(proposalId, 0); // trigger confirmation

        uint256 confirmationProposalId = _confirmationProposalId(targets, values, calldatas, description);
        _warpToActive(confirmationProposalId);
        vm.prank(bob);
        governor.castVote(confirmationProposalId, 0);
        vm.prank(carol);
        governor.castVote(confirmationProposalId, 2);

        _warpPastDeadline(confirmationProposalId);
        assertEq(uint256(governor.state(confirmationProposalId)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_confirmationVote_defeatedWhenQuorumNotReached() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Confirmation defeated due to no quorum";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        _warpToActive(proposalId);
        vm.prank(alice);
        governor.castVote(proposalId, 0); // trigger confirmation

        uint256 confirmationProposalId = _confirmationProposalId(targets, values, calldatas, description);

        // No additional FOR/ABSTAIN votes in confirmation phase.
        _warpPastDeadline(confirmationProposalId);

        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(confirmationProposalId);
        assertEq(againstVotes, 0);
        assertEq(forVotes + abstainVotes, 0);
        assertEq(uint256(governor.state(confirmationProposalId)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_confirmationVote_originalOptimisticProposerCanCancel() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Proposer cancels confirmation";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        _warpToActive(proposalId);
        vm.prank(alice);
        governor.castVote(proposalId, 0); // trigger confirmation

        uint256 confirmationProposalId = _confirmationProposalId(targets, values, calldatas, description);

        vm.prank(optimisticProposer);
        governor.cancel(targets, values, calldatas, keccak256(bytes(_confirmationDescription(description))));

        assertEq(uint256(governor.state(confirmationProposalId)), uint256(IGovernor.ProposalState.Canceled));
    }

    function test_confirmationVote_guardianCanCancel() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Guardian cancels confirmation";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        _warpToActive(proposalId);
        vm.prank(alice);
        governor.castVote(proposalId, 0); // trigger confirmation

        uint256 confirmationProposalId = _confirmationProposalId(targets, values, calldatas, description);

        vm.prank(guardian);
        guardianContract.cancel(
            address(governor), targets, values, calldatas, keccak256(bytes(_confirmationDescription(description)))
        );

        assertEq(uint256(governor.state(confirmationProposalId)), uint256(IGovernor.ProposalState.Canceled));
    }

    function test_confirmationVote_optimisticGuardianCannotCancelWhilePending() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Optimistic guardian cannot cancel confirmation";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        _warpToActive(proposalId);
        vm.prank(alice);
        governor.castVote(proposalId, 0); // trigger confirmation

        uint256 confirmationProposalId = _confirmationProposalId(targets, values, calldatas, description);

        vm.prank(optimisticGuardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnableToCancel.selector, confirmationProposalId, optimisticGuardian
            )
        );
        governor.cancel(targets, values, calldatas, keccak256(bytes(_confirmationDescription(description))));
    }

    function test_execute_revertsAfterConfirmationTransition() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "execute must fail while confirmation is active";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        _warpToActive(proposalId);
        vm.prank(alice);
        governor.castVote(proposalId, 0); // trigger confirmation

        vm.prank(optimisticProposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                proposalId,
                IGovernor.ProposalState.Defeated,
                bytes32(
                    uint256(
                        (1 << uint8(IGovernor.ProposalState.Succeeded)) | (1 << uint8(IGovernor.ProposalState.Queued))
                    )
                )
            )
        );
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
    }

    function test_optimisticProposal_autoCancelsWhenPastSupplyIsZero() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        string memory description = "Auto-cancel at zero supply";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        vm.prank(alice);
        stakingVault.redeem(ALICE_STAKE, alice, alice);
        vm.prank(bob);
        stakingVault.redeem(BOB_STAKE, bob, bob);
        vm.prank(carol);
        stakingVault.redeem(CAROL_STAKE, carol, carol);

        // Move forward so the zero-supply point becomes observable via getPastTotalSupply(snapshot).
        vm.warp(block.timestamp + 1);

        _warpToActive(proposalId);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Canceled));
    }

    // ===== Proposal Throttle =====

    function test_proposalThrottle_isIsolatedPerAccountAcrossOptimisticAndStandard() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        vm.prank(alice);
        governor.propose(targets, values, calldatas, "standard #1");
        vm.prank(alice);
        governor.propose(targets, values, calldatas, "standard #2");
        vm.prank(alice);
        governor.propose(targets, values, calldatas, "standard #3");

        vm.prank(optimisticProposer);
        governor.proposeOptimistic(targets, values, calldatas, "optimistic #1");
        vm.prank(optimisticProposer);
        governor.proposeOptimistic(targets, values, calldatas, "optimistic #2");

        vm.prank(optimisticProposer);
        vm.expectRevert(IReserveOptimisticGovernor.OptimisticGovernor__ProposalThrottleExceeded.selector);
        governor.proposeOptimistic(targets, values, calldatas, "optimistic #3");

        // Throttling is account-specific.
        vm.prank(optimisticProposer2);
        governor.proposeOptimistic(targets, values, calldatas, "optimistic proposer2 #1");
    }

    function test_proposalThrottle_rechargesLinearlyOverTime() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        vm.prank(optimisticProposer);
        governor.proposeOptimistic(targets, values, calldatas, "Consume charge #1");
        vm.prank(optimisticProposer);
        governor.proposeOptimistic(targets, values, calldatas, "Consume charge #2");

        vm.prank(optimisticProposer);
        vm.expectRevert(IReserveOptimisticGovernor.OptimisticGovernor__ProposalThrottleExceeded.selector);
        governor.proposeOptimistic(targets, values, calldatas, "No charge available");

        // With capacity=2/12h, each proposal charge refills in 6h.
        vm.warp(block.timestamp + 6 hours);

        vm.prank(optimisticProposer);
        governor.proposeOptimistic(targets, values, calldatas, "Recharged charge #1");

        vm.prank(optimisticProposer);
        vm.expectRevert(IReserveOptimisticGovernor.OptimisticGovernor__ProposalThrottleExceeded.selector);
        governor.proposeOptimistic(targets, values, calldatas, "Charge consumed again");
    }

    function test_proposalThrottle_canAtomicallyCreateCapacityProposals() public {
        uint256 capacity = 3;

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(governor), 0, abi.encodeCall(governor.setProposalThrottle, (capacity)));

        (, bytes32 descriptionHash) =
            _proposePassAndQueueStandard(targets, values, calldatas, "Set proposal throttle to three");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(governor.proposalThrottleCapacity(), capacity);

        (address[] memory callTargets, uint256[] memory callValues, bytes[] memory callCalldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        assertEq(governor.proposalThrottleCharges(optimisticProposer), capacity);

        for (uint256 i = 0; i < capacity; i++) {
            vm.prank(optimisticProposer);
            governor.proposeOptimistic(
                callTargets, callValues, callCalldatas, string.concat("Atomic capacity consume #", vm.toString(i + 1))
            );
            assertEq(governor.proposalThrottleCharges(optimisticProposer), capacity - i - 1);
        }

        vm.prank(optimisticProposer);
        vm.expectRevert(IReserveOptimisticGovernor.OptimisticGovernor__ProposalThrottleExceeded.selector);
        governor.proposeOptimistic(callTargets, callValues, callCalldatas, "Atomic capacity consume overflow");
    }

    // ===== Registry Tests =====

    function test_registry_onlyTimelockCanRegister() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IERC20.approve.selector;

        IOptimisticSelectorRegistry.SelectorData[] memory selectorData =
            new IOptimisticSelectorRegistry.SelectorData[](1);
        selectorData[0] = IOptimisticSelectorRegistry.SelectorData(address(underlying), selectors);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptimisticSelectorRegistry.SelectorRegistry__OnlyOwner.selector, alice));
        registry.registerSelectors(selectorData);
    }

    function test_registry_onlyTimelockCanUnregister() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IERC20.transfer.selector;

        IOptimisticSelectorRegistry.SelectorData[] memory selectorData =
            new IOptimisticSelectorRegistry.SelectorData[](1);
        selectorData[0] = IOptimisticSelectorRegistry.SelectorData(address(underlying), selectors);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOptimisticSelectorRegistry.SelectorRegistry__OnlyOwner.selector, alice));
        registry.unregisterSelectors(selectorData);
    }

    function test_registry_registerAndUnregister() public {
        _allowSelector(address(underlying), IERC20.approve.selector);
        assertTrue(registry.isAllowed(address(underlying), IERC20.approve.selector));

        _disallowSelector(address(underlying), IERC20.approve.selector);
        assertFalse(registry.isAllowed(address(underlying), IERC20.approve.selector));

        _disallowSelector(address(underlying), IERC20.transfer.selector);
        assertEq(registry.targets().length, 0);
    }

    function test_registry_registerSelectors_emitsSelectorAddedPerSelector() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IERC20.approve.selector;
        selectors[1] = IERC20.transferFrom.selector;

        IOptimisticSelectorRegistry.SelectorData[] memory selectorData =
            new IOptimisticSelectorRegistry.SelectorData[](1);
        selectorData[0] = IOptimisticSelectorRegistry.SelectorData(address(underlying), selectors);

        vm.expectEmit(true, true, false, false, address(registry));
        emit IOptimisticSelectorRegistry.SelectorAdded(address(underlying), selectors[0]);

        vm.expectEmit(true, true, false, false, address(registry));
        emit IOptimisticSelectorRegistry.SelectorAdded(address(underlying), selectors[1]);

        vm.prank(address(timelock));
        registry.registerSelectors(selectorData);

        assertTrue(registry.isAllowed(address(underlying), selectors[0]));
        assertTrue(registry.isAllowed(address(underlying), selectors[1]));
    }

    function test_registry_unregisterSelectors_emitsSelectorRemovedPerSelector() public {
        _allowSelector(address(underlying), IERC20.approve.selector);
        _allowSelector(address(underlying), IERC20.transferFrom.selector);

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IERC20.approve.selector;
        selectors[1] = IERC20.transferFrom.selector;

        IOptimisticSelectorRegistry.SelectorData[] memory selectorData =
            new IOptimisticSelectorRegistry.SelectorData[](1);
        selectorData[0] = IOptimisticSelectorRegistry.SelectorData(address(underlying), selectors);

        vm.expectEmit(true, true, false, false, address(registry));
        emit IOptimisticSelectorRegistry.SelectorRemoved(address(underlying), selectors[0]);

        vm.expectEmit(true, true, false, false, address(registry));
        emit IOptimisticSelectorRegistry.SelectorRemoved(address(underlying), selectors[1]);

        vm.prank(address(timelock));
        registry.unregisterSelectors(selectorData);

        assertFalse(registry.isAllowed(address(underlying), selectors[0]));
        assertFalse(registry.isAllowed(address(underlying), selectors[1]));
    }

    function test_registry_whitelistSharedAcrossProposers() public {
        bytes4 approveSelector = IERC20.approve.selector;

        assertFalse(registry.isAllowed(address(underlying), approveSelector));

        _allowSelector(address(underlying), approveSelector);
        assertTrue(registry.isAllowed(address(underlying), approveSelector));

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.approve, (alice, 1_000e18)));

        vm.prank(optimisticProposer);
        uint256 firstProposalId = governor.proposeOptimistic(targets, values, calldatas, "approve proposer 1");

        vm.prank(optimisticProposer2);
        uint256 secondProposalId = governor.proposeOptimistic(targets, values, calldatas, "approve proposer 2");

        assertEq(uint256(governor.state(firstProposalId)), uint256(IGovernor.ProposalState.Pending));
        assertEq(uint256(governor.state(secondProposalId)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_registry_cannotRegisterBlockedTargetsOrZeroSelector() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IERC20.transfer.selector;
        IOptimisticSelectorRegistry.SelectorData[] memory selectorData =
            new IOptimisticSelectorRegistry.SelectorData[](1);

        selectorData[0] = IOptimisticSelectorRegistry.SelectorData(address(registry), selectors);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptimisticSelectorRegistry.SelectorRegistry__InvalidTarget.selector, address(registry)
            )
        );
        registry.registerSelectors(selectorData);

        selectorData[0] = IOptimisticSelectorRegistry.SelectorData(address(governor), selectors);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptimisticSelectorRegistry.SelectorRegistry__InvalidTarget.selector, address(governor)
            )
        );
        registry.registerSelectors(selectorData);

        selectorData[0] = IOptimisticSelectorRegistry.SelectorData(address(timelock), selectors);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptimisticSelectorRegistry.SelectorRegistry__InvalidTarget.selector, address(timelock)
            )
        );
        registry.registerSelectors(selectorData);

        selectorData[0] = IOptimisticSelectorRegistry.SelectorData(address(stakingVault), selectors);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptimisticSelectorRegistry.SelectorRegistry__InvalidTarget.selector, address(stakingVault)
            )
        );
        registry.registerSelectors(selectorData);

        DummyTarget dummy = new DummyTarget();
        selectors[0] = bytes4(0);
        selectorData[0] = IOptimisticSelectorRegistry.SelectorData(address(dummy), selectors);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IOptimisticSelectorRegistry.SelectorRegistry__InvalidSelector.selector, bytes4(0))
        );
        registry.registerSelectors(selectorData);
    }

    // ===== Timelock / Role Management =====

    function test_guardianCanRevokeOptimisticProposer() public {
        assertTrue(timelock.hasRole(OPTIMISTIC_PROPOSER_ROLE, optimisticProposer2));

        vm.prank(guardian);
        guardianContract.revokeOptimisticProposer(address(governor), optimisticProposer2);

        assertFalse(timelock.hasRole(OPTIMISTIC_PROPOSER_ROLE, optimisticProposer2));

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        vm.prank(optimisticProposer2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveOptimisticGovernor.OptimisticGovernor__NotOptimisticProposer.selector, optimisticProposer2
            )
        );
        governor.proposeOptimistic(targets, values, calldatas, "revoked proposer cannot propose");
    }

    function test_nonGuardianCannotRevokeOptimisticProposer() public {
        vm.prank(alice);
        vm.expectRevert();
        timelock.revokeOptimisticProposer(optimisticProposer2);
    }

    function test_optimisticGuardianCannotRevokeOptimisticProposer() public {
        vm.prank(optimisticGuardian);
        vm.expectRevert();
        timelock.revokeOptimisticProposer(optimisticProposer2);
    }

    // ===== Governance Parameter Validation =====

    function test_setOptimisticParams_viaGovernance() public {
        IReserveOptimisticGovernor.OptimisticGovernanceParams memory newParams =
            IReserveOptimisticGovernor.OptimisticGovernanceParams({
                vetoDelay: 2 hours, vetoPeriod: 3 hours, vetoThreshold: 0.25e18
            });

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(governor), 0, abi.encodeCall(governor.setOptimisticParams, (newParams)));

        (, bytes32 descriptionHash) =
            _proposePassAndQueueStandard(targets, values, calldatas, "Update optimistic params");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        (uint48 vetoDelay, uint32 vetoPeriod, uint256 vetoThreshold) = governor.optimisticParams();
        assertEq(vetoDelay, 2 hours);
        assertEq(vetoPeriod, 3 hours);
        assertEq(vetoThreshold, 0.25e18);
        assertEq(governor.proposalThrottleCharges(optimisticProposer), PROPOSAL_THROTTLE_CAPACITY);
    }

    function test_setOptimisticParams_allowsMinimumVetoPeriod() public {
        IReserveOptimisticGovernor.OptimisticGovernanceParams memory newParams =
            IReserveOptimisticGovernor.OptimisticGovernanceParams({
                vetoDelay: 2 hours, vetoPeriod: uint32(MIN_OPTIMISTIC_VETO_PERIOD), vetoThreshold: 0.25e18
            });

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(governor), 0, abi.encodeCall(governor.setOptimisticParams, (newParams)));

        (, bytes32 descriptionHash) =
            _proposePassAndQueueStandard(targets, values, calldatas, "Set minimum veto period");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        (, uint32 vetoPeriod,) = governor.optimisticParams();
        assertEq(vetoPeriod, uint32(MIN_OPTIMISTIC_VETO_PERIOD));
    }

    function test_setOptimisticParams_revertsWhenVetoDelayBelowMinimum() public {
        IReserveOptimisticGovernor.OptimisticGovernanceParams memory badParams =
            IReserveOptimisticGovernor.OptimisticGovernanceParams({
                vetoDelay: 0, // below MIN_OPTIMISTIC_VETO_DELAY
                vetoPeriod: VETO_PERIOD,
                vetoThreshold: VETO_THRESHOLD
            });

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(governor), 0, abi.encodeCall(governor.setOptimisticParams, (badParams)));

        (, bytes32 descriptionHash) =
            _proposePassAndQueueStandard(targets, values, calldatas, "Invalid optimistic params");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.expectRevert(IReserveOptimisticGovernor.OptimisticGovernor__InvalidOptimisticParameters.selector);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function test_setOptimisticParams_revertsWhenVetoPeriodBelowMinimum() public {
        IReserveOptimisticGovernor.OptimisticGovernanceParams memory badParams =
            IReserveOptimisticGovernor.OptimisticGovernanceParams({
                vetoDelay: VETO_DELAY, vetoPeriod: uint32(MIN_OPTIMISTIC_VETO_PERIOD - 1), vetoThreshold: VETO_THRESHOLD
            });

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(governor), 0, abi.encodeCall(governor.setOptimisticParams, (badParams)));

        (, bytes32 descriptionHash) =
            _proposePassAndQueueStandard(targets, values, calldatas, "Set veto period below minimum");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.expectRevert(IReserveOptimisticGovernor.OptimisticGovernor__InvalidOptimisticParameters.selector);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function test_setProposalThreshold_revertsAbove100Percent() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(governor), 0, abi.encodeCall(governor.setProposalThreshold, (1e18 + 1)));

        (, bytes32 descriptionHash) =
            _proposePassAndQueueStandard(targets, values, calldatas, "Set proposalThreshold > 100%");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.expectRevert(IReserveOptimisticGovernor.OptimisticGovernor__InvalidProposalThreshold.selector);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function test_setProposalThreshold_revertsAtZero() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(governor), 0, abi.encodeCall(governor.setProposalThreshold, (0)));

        (, bytes32 descriptionHash) =
            _proposePassAndQueueStandard(targets, values, calldatas, "Set proposalThreshold to 0%");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.expectRevert(IReserveOptimisticGovernor.OptimisticGovernor__InvalidProposalThreshold.selector);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function test_setProposalThreshold_updatesProposerEligibility() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(governor), 0, abi.encodeCall(governor.setProposalThreshold, (0.6e18)));

        (, bytes32 descriptionHash) =
            _proposePassAndQueueStandard(targets, values, calldatas, "Set proposalThreshold to 60%");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertGt(governor.proposalThreshold(), ALICE_STAKE);

        (address[] memory callTargets, uint256[] memory callValues, bytes[] memory callCalldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        vm.prank(alice);
        vm.expectRevert();
        governor.propose(callTargets, callValues, callCalldatas, "alice can no longer propose");
    }

    function test_setProposalThrottle_viaGovernance() public {
        uint256 newProposalThrottle = MAX_PROPOSAL_THROTTLE_CAPACITY;
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(governor), 0, abi.encodeCall(governor.setProposalThrottle, (newProposalThrottle)));

        (, bytes32 descriptionHash) =
            _proposePassAndQueueStandard(targets, values, calldatas, "Update proposal throttle");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(governor.proposalThrottleCapacity(), newProposalThrottle);

        (address[] memory callTargets, uint256[] memory callValues, bytes[] memory callCalldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        for (uint256 i = 0; i < newProposalThrottle; i++) {
            vm.prank(optimisticProposer);
            governor.proposeOptimistic(
                callTargets, callValues, callCalldatas, string.concat("Throttle reset propose #", vm.toString(i))
            );
        }

        vm.prank(optimisticProposer);
        vm.expectRevert(IReserveOptimisticGovernor.OptimisticGovernor__ProposalThrottleExceeded.selector);
        governor.proposeOptimistic(callTargets, callValues, callCalldatas, "Throttle reset should be exhausted");
    }

    function test_setProposalThrottle_revertsWhenInvalid() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(governor), 0, abi.encodeCall(governor.setProposalThrottle, (0)));

        (, bytes32 descriptionHash) =
            _proposePassAndQueueStandard(targets, values, calldatas, "Set proposal throttle to zero");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.expectRevert(IReserveOptimisticGovernor.OptimisticGovernor__InvalidProposalThrottle.selector);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function test_setProposalThrottle_revertsWhenAboveMaximum() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleCall(
            address(governor), 0, abi.encodeCall(governor.setProposalThrottle, (MAX_PROPOSAL_THROTTLE_CAPACITY + 1))
        );

        (, bytes32 descriptionHash) =
            _proposePassAndQueueStandard(targets, values, calldatas, "Set proposal throttle above maximum");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.expectRevert(IReserveOptimisticGovernor.OptimisticGovernor__InvalidProposalThrottle.selector);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    // ===== Upgrades =====

    function test_upgradeGovernor_viaGovernance() public {
        ReserveOptimisticGovernorV2Mock newImpl = new ReserveOptimisticGovernorV2Mock();

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(governor), 0, abi.encodeCall(governor.upgradeToAndCall, (address(newImpl), "")));

        (, bytes32 descriptionHash) = _proposePassAndQueueStandard(targets, values, calldatas, "Upgrade governor");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(ReserveOptimisticGovernorV2Mock(payable(address(governor))).version(), "2.0.0");
    }

    function test_cannotUpgradeGovernor_unauthorized() public {
        ReserveOptimisticGovernorV2Mock newImpl = new ReserveOptimisticGovernorV2Mock();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, alice));
        governor.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgradeTimelock_viaGovernance() public {
        TimelockControllerOptimisticV2Mock newImpl = new TimelockControllerOptimisticV2Mock();

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(timelock), 0, abi.encodeCall(timelock.upgradeToAndCall, (address(newImpl), "")));

        (, bytes32 descriptionHash) = _proposePassAndQueueStandard(targets, values, calldatas, "Upgrade timelock");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(TimelockControllerOptimisticV2Mock(payable(address(timelock))).version(), "2.0.0");
    }

    function test_updateTimelock_reverts() public {
        vm.expectRevert(IReserveOptimisticGovernor.OptimisticGovernor__TimelockCannotBeUpdated.selector);
        governor.updateTimelock(TimelockControllerUpgradeable(payable(address(timelock))));
    }

    function test_updateTimelock_revertsViaGovernance() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleCall(
            address(governor),
            0,
            abi.encodeCall(governor.updateTimelock, (TimelockControllerUpgradeable(payable(address(timelock)))))
        );

        (, bytes32 descriptionHash) = _proposePassAndQueueStandard(targets, values, calldatas, "Update timelock");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.expectRevert(IReserveOptimisticGovernor.OptimisticGovernor__TimelockCannotBeUpdated.selector);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function test_cannotUpgradeTimelock_unauthorized() public {
        TimelockControllerOptimisticV2Mock newImpl = new TimelockControllerOptimisticV2Mock();

        vm.prank(alice);
        vm.expectRevert(ITimelockControllerOptimistic.TimelockControllerOptimistic__UnauthorizedUpgrade.selector);
        timelock.upgradeToAndCall(address(newImpl), "");
    }

    // ===== Misc Vote Validation =====

    function test_castVote_rejectsInvalidSupportValue() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, "invalid support");
        _warpToActive(proposalId);

        vm.prank(alice);
        vm.expectRevert(IGovernor.GovernorInvalidVoteType.selector);
        governor.castVote(proposalId, 3);
    }

    // ===== Helpers =====

    function _setupVoter(address voter, uint256 amount) internal {
        underlying.mint(voter, amount);

        vm.startPrank(voter);
        underlying.approve(address(stakingVault), amount);
        stakingVault.depositAndDelegate(amount);
        vm.stopPrank();
    }

    function _singleCall(address target, uint256 value, bytes memory callData)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);

        targets[0] = target;
        values[0] = value;
        calldatas[0] = callData;
    }

    function _allowSelector(address target, bytes4 selector) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;

        IOptimisticSelectorRegistry.SelectorData[] memory selectorData =
            new IOptimisticSelectorRegistry.SelectorData[](1);
        selectorData[0] = IOptimisticSelectorRegistry.SelectorData(target, selectors);

        vm.prank(address(timelock));
        registry.registerSelectors(selectorData);
    }

    function _disallowSelector(address target, bytes4 selector) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;

        IOptimisticSelectorRegistry.SelectorData[] memory selectorData =
            new IOptimisticSelectorRegistry.SelectorData[](1);
        selectorData[0] = IOptimisticSelectorRegistry.SelectorData(target, selectors);

        vm.prank(address(timelock));
        registry.unregisterSelectors(selectorData);
    }

    function _confirmationDescription(string memory description) internal pure returns (string memory) {
        return string.concat(CONFIRMATION_PREFIX, description);
    }

    function _confirmationProposalId(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal view returns (uint256) {
        return governor.getProposalId(
            targets, values, calldatas, keccak256(bytes(_confirmationDescription(description)))
        );
    }

    function _warpToActive(uint256 proposalId) internal {
        vm.warp(governor.proposalSnapshot(proposalId) + 1);
    }

    function _warpPastDeadline(uint256 proposalId) internal {
        vm.warp(governor.proposalDeadline(proposalId) + 1);
    }

    function _proposePassAndQueueStandard(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256 proposalId, bytes32 descriptionHash) {
        vm.prank(alice);
        proposalId = governor.propose(targets, values, calldatas, description);

        _warpToActive(proposalId);

        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(bob);
        governor.castVote(proposalId, 1);
        vm.prank(carol);
        governor.castVote(proposalId, 1);

        _warpPastDeadline(proposalId);
        descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);
    }
}

contract ReserveOptimisticGovernorNewStakingVaultTest is ReserveOptimisticGovernorTestBase {
    function _useExistingStakingVaultDeployment() internal pure override returns (bool) {
        return false;
    }
}

contract ReserveOptimisticGovernorExistingStakingVaultTest is ReserveOptimisticGovernorTestBase {
    function _useExistingStakingVaultDeployment() internal pure override returns (bool) {
        return true;
    }
}
