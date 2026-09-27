// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { StdStorage, stdStorage } from "forge-std/StdStorage.sol";
import { Test } from "forge-std/Test.sol";

import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { GenericTokenJar } from "@reserve-protocol/trusted-fillers/contracts/extras/GenericTokenJar.sol";

import { OptimisticSelectorRegistry } from "@governance/OptimisticSelectorRegistry.sol";
import { ReserveOptimisticGovernor } from "@governance/ReserveOptimisticGovernor.sol";
import { TimelockControllerOptimistic } from "@governance/TimelockControllerOptimistic.sol";
import { GovernanceUpgradeLib } from "@governance/lib/GovernanceUpgradeLib.sol";
import { IReserveOptimisticGovernorDeployer } from "@interfaces/IDeployer.sol";
import { IOptimisticSelectorRegistry } from "@interfaces/IOptimisticSelectorRegistry.sol";
import { IOptimisticVotes } from "@interfaces/IOptimisticVotes.sol";
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
    OPTIMISTIC_PROPOSER_ROLE,
    PROPOSAL_THROTTLE_PERIOD
} from "@utils/Constants.sol";

import { MockERC20 } from "@mocks/MockERC20.sol";
import { MockRoleRegistry } from "@mocks/MockRoleRegistry.sol";
import { ReserveOptimisticGovernorDeployerV2Mock } from "@mocks/ReserveOptimisticGovernorDeployerV2Mock.sol";
import { ReserveOptimisticGovernorV2Mock } from "@mocks/ReserveOptimisticGovernorV2Mock.sol";
import { StakingVaultV2Mock } from "@mocks/StakingVaultV2Mock.sol";
import { TimelockControllerOptimisticV2Mock } from "@mocks/TimelockControllerOptimisticV2Mock.sol";

contract DummyTarget {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

contract GovernorSignatureWallet is IERC1271 {
    address private immutable governor;
    bytes32 public digest;

    constructor(address _governor) {
        governor = _governor;
    }

    function setDigest(bytes32 _digest) external {
        digest = _digest;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        return msg.sender == governor && hash == digest && keccak256(signature) == keccak256(hex"1271")
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }
}

abstract contract ReserveOptimisticGovernorTestBase is Test {
    using stdStorage for StdStorage;
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
    address public trustedFillerRegistry = makeAddr("trustedFillerRegistry");

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

    // ERC-7201 VotesIntegral namespace; nested mapping stores raw cumulative values per checkpoint.
    bytes32 internal constant VOTE_INTEGRALS_MAPPING_SLOT =
        0x6c8ef2534ba8916a427dbfc162fbce2a165f7cccf4d86d45f25d2b245ed73b00;
    bytes32 internal constant VOTE_INTEGRAL_STATE_SLOT = bytes32(uint256(VOTE_INTEGRALS_MAPPING_SLOT) + 1);
    bytes32 internal constant SUPPLY_INTEGRALS_MAPPING_SLOT = bytes32(uint256(VOTE_INTEGRALS_MAPPING_SLOT) + 2);

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
            trustedFillerRegistry,
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

    function test_timelockInitialization_requiresVersionRegistry() public {
        TimelockControllerOptimistic freshTimelock = TimelockControllerOptimistic(
            payable(address(new ERC1967Proxy(address(new TimelockControllerOptimistic()), "")))
        );
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = alice;
        executors[0] = bob;

        // An uninitialized proxy must reject the inherited selector too.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        TimelockControllerUpgradeable(payable(address(freshTimelock)))
            .initialize(TIMELOCK_DELAY, proposers, executors, alice);
        assertFalse(freshTimelock.hasRole(freshTimelock.DEFAULT_ADMIN_ROLE(), alice));

        address versionRegistry = deployer.versionRegistry();
        freshTimelock.initialize(TIMELOCK_DELAY, proposers, executors, alice, versionRegistry);
        assertEq(address(freshTimelock.versionRegistry()), versionRegistry);
        assertEq(freshTimelock.getMinDelay(), TIMELOCK_DELAY);
        assertTrue(freshTimelock.hasRole(freshTimelock.DEFAULT_ADMIN_ROLE(), alice));
        assertTrue(freshTimelock.hasRole(freshTimelock.PROPOSER_ROLE(), alice));
        assertTrue(freshTimelock.hasRole(freshTimelock.EXECUTOR_ROLE(), bob));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        freshTimelock.initialize(TIMELOCK_DELAY, proposers, executors, alice, versionRegistry);
    }

    function test_deployment_initializesSigningDomain() public view {
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifier,,) =
            governor.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "Reserve Optimistic Governor");
        assertEq(governor.name(), name);
        assertEq(version, "1.1.0");
        assertEq(chainId, block.chainid);
        assertEq(verifier, address(governor));
    }

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
        assertEq(address(governor.versionRegistry()), deployer.versionRegistry());
        assertEq(address(timelock.versionRegistry()), deployer.versionRegistry());

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

        GenericTokenJar jar = GenericTokenJar(stakingVault.tokenJar());
        assertNotEq(address(jar), address(0));
        assertEq(jar.destination(), address(stakingVault));
        assertEq(address(jar.token()), address(underlying));
        assertEq(address(jar.trustedFillerRegistry()), trustedFillerRegistry);
        assertEq(jar.owner(), address(0));

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

    function test_standardProposal_uninitializedAverageVotesFailsClosed() public {
        _clearAverageVoteHistory(alice);
        vm.store(address(stakingVault), VOTE_INTEGRAL_STATE_SLOT, bytes32(0));

        assertEq(stakingVault.getPastAverageVotes(alice, 0, block.timestamp), 0);
        uint256 threshold = governor.proposalThreshold();
        assertGe(governor.getVotes(alice, block.timestamp - PROPOSAL_THROTTLE_PERIOD), threshold);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernor.GovernorInsufficientProposerVotes.selector, alice, 0, threshold)
        );
        governor.propose(targets, values, calldatas, "Uninitialized average voting history");
    }

    function test_standardProposal_unchangedLegacyBalanceRampsFromGlobalActivation() public {
        uint256 threshold = governor.proposalThreshold();
        vm.prank(alice);
        stakingVault.transfer(bob, ALICE_STAKE - threshold);
        _restartAverageVotes(alice);
        uint256 activation = block.timestamp;

        assertEq(stakingVault.getPastAverageVotes(alice, 0, activation), 0);
        vm.warp(activation + 6 hours);
        assertEq(
            stakingVault.getPastAverageVotes(alice, block.timestamp - PROPOSAL_THROTTLE_PERIOD, block.timestamp),
            threshold / 2
        );

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorInsufficientProposerVotes.selector, alice, threshold / 2, threshold
            )
        );
        vm.prank(alice);
        governor.propose(targets, values, calldatas, "Legacy activation ramp halfway");

        vm.warp(activation + 12 hours);
        assertEq(stakingVault.getPastAverageVotes(alice, activation, block.timestamp), threshold);
        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Legacy activation ramp complete");
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_standardProposal_dustDoesNotResetLegacyRampOrEraseArea() public {
        _restartAverageVotes(alice);
        uint256 activation = block.timestamp;
        address dustHolder = makeAddr("dustHolder");

        vm.warp(activation + 6 hours);
        underlying.mint(dustHolder, 1);
        vm.startPrank(dustHolder);
        underlying.approve(address(stakingVault), 1);
        stakingVault.depositAndDelegate(1, alice, dustHolder);
        vm.stopPrank();

        vm.warp(activation + 12 hours);
        assertEq(stakingVault.getPastAverageVotes(alice, activation, block.timestamp), ALICE_STAKE);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Legacy ramp after dust");
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_standardProposal_cannotReplayPreActivationEndpointHop() public {
        address proposer = makeAddr("preActivationHopProposer");
        uint256 threshold = governor.proposalThreshold();

        vm.prank(bob);
        stakingVault.transfer(proposer, threshold);
        vm.prank(proposer);
        stakingVault.delegate(proposer);
        vm.warp(block.timestamp + 4 hours);
        vm.prank(proposer);
        stakingVault.transfer(bob, threshold);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(bob);
        stakingVault.transfer(proposer, threshold);
        vm.warp(block.timestamp + 3 hours);

        _restartAverageVotes(proposer);
        vm.warp(block.timestamp + 6 hours);
        assertEq(governor.getVotes(proposer, block.timestamp - 1), threshold);
        assertGe(governor.getVotes(proposer, block.timestamp - PROPOSAL_THROTTLE_PERIOD), threshold);
        uint256 averageVotes = threshold / 2;

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1)));
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorInsufficientProposerVotes.selector, proposer, averageVotes, threshold
            )
        );
        vm.prank(proposer);
        governor.propose(targets, values, calldatas, "Pre-activation endpoint hop");
    }

    function test_standardProposal_rejectsBriefVotesAtFirstCheckpointAnniversary() public {
        address proposer = makeAddr("anniversaryProposer");
        uint256 threshold = governor.proposalThreshold();
        uint256 start = block.timestamp;

        vm.prank(bob);
        stakingVault.transfer(proposer, threshold);
        vm.prank(proposer);
        stakingVault.delegate(proposer);

        vm.warp(start + 1);
        vm.prank(proposer);
        stakingVault.transfer(bob, threshold);

        vm.warp(start + PROPOSAL_THROTTLE_PERIOD - 2);
        vm.prank(bob);
        stakingVault.transfer(proposer, threshold);

        assertEq(governor.getVotes(proposer, start), threshold);
        assertEq(stakingVault.getPastAverageVotes(proposer, 0, start), 0);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1)));

        // Before the anniversary there are no historical votes; at/after it the tiny exact average rejects.
        for (uint256 i; i < 3; ++i) {
            vm.warp(start + PROPOSAL_THROTTLE_PERIOD - 1 + i);
            assertEq(governor.getVotes(proposer, block.timestamp - 1), threshold);
            uint256 eligibleVotes = (threshold * (i == 0 ? 2 : 3)) / PROPOSAL_THROTTLE_PERIOD;
            assertLt(eligibleVotes, threshold);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IGovernor.GovernorInsufficientProposerVotes.selector, proposer, eligibleVotes, threshold
                )
            );
            vm.prank(proposer);
            governor.propose(targets, values, calldatas, "First checkpoint anniversary");
        }
    }

    function test_standardProposal_averagesTrackedZeroAreaBeforeLaterVotes() public {
        address proposer = makeAddr("zeroAreaProposer");
        uint256 threshold = governor.proposalThreshold();
        uint256 start = block.timestamp;
        vm.prank(bob);
        stakingVault.transfer(proposer, threshold);
        vm.startPrank(proposer);
        stakingVault.delegate(proposer);
        stakingVault.transfer(bob, threshold);
        vm.stopPrank();

        vm.warp(start + PROPOSAL_THROTTLE_PERIOD / 2);
        vm.prank(bob);
        stakingVault.transfer(proposer, 2 * threshold);
        vm.warp(start + PROPOSAL_THROTTLE_PERIOD);

        assertEq(governor.getVotes(proposer, start), 0);
        assertEq(stakingVault.getPastAverageVotes(proposer, 0, start), 0);
        uint256 averageVotes = stakingVault.getPastAverageVotes(proposer, start, block.timestamp);
        assertEq(averageVotes, threshold);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1)));
        vm.prank(proposer);
        governor.propose(targets, values, calldatas, "Tracked zero-area start");
    }

    function test_standardProposal_recentLargeAccountQualifiesProportionally() public {
        address recentVoter = makeAddr("recentVoter");
        uint256 amount = 100_000e18;
        uint256 start = block.timestamp;
        underlying.mint(recentVoter, amount);

        vm.startPrank(recentVoter);
        underlying.approve(address(stakingVault), amount);
        stakingVault.depositAndDelegate(amount);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        uint256 threshold = governor.proposalThreshold();
        uint256 periodStart = block.timestamp - PROPOSAL_THROTTLE_PERIOD;
        IOptimisticVotes votes = IOptimisticVotes(address(stakingVault));
        uint256 averageVotes = votes.getPastAverageVotes(recentVoter, periodStart, block.timestamp);
        uint256 averageSupply = stakingVault.getPastAverageSupply(periodStart, block.timestamp);
        uint256 normalizedAverageVotes =
            Math.mulDiv(averageVotes, stakingVault.getPastTotalSupply(block.timestamp - 1), averageSupply);

        assertGe(governor.getVotes(recentVoter, block.timestamp - 1), threshold);
        assertEq(votes.getPastAverageVotes(recentVoter, 0, periodStart), 0);
        assertEq(governor.getVotes(recentVoter, periodStart), 0);
        vm.prank(recentVoter);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorInsufficientProposerVotes.selector, recentVoter, normalizedAverageVotes, threshold
            )
        );
        governor.propose(targets, values, calldatas, "Recent delegated voter");

        // Higher balances satisfy the fixed-period average before a full lookback elapses.
        uint256 eligibleAfter = (threshold * PROPOSAL_THROTTLE_PERIOD + amount - 1) / amount;
        vm.warp(start + eligibleAfter);
        vm.prank(recentVoter);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Recent delegated voter warmed up");
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_standardProposal_fractionalAverageSupplyRoundsAgainstProposer() public {
        (address[] memory settingsTargets, uint256[] memory settingsValues, bytes[] memory settingsCalldatas) =
            _singleCall(address(governor), 0, abi.encodeCall(governor.setProposalThreshold, (0.5e18)));
        (, bytes32 settingsDescriptionHash) =
            _proposePassAndQueueStandard(settingsTargets, settingsValues, settingsCalldatas, "Set threshold to 50%");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(settingsTargets, settingsValues, settingsCalldatas, settingsDescriptionHash);

        vm.startPrank(alice);
        stakingVault.redeem(stakingVault.balanceOf(alice), alice, alice);
        vm.stopPrank();
        vm.startPrank(bob);
        stakingVault.redeem(stakingVault.balanceOf(bob), bob, bob);
        vm.stopPrank();
        vm.startPrank(carol);
        stakingVault.redeem(stakingVault.balanceOf(carol), carol, carol);
        vm.stopPrank();

        address proposer = makeAddr("roundingProposer");
        address otherHolder = makeAddr("roundingOtherHolder");
        _setupVoter(proposer, 1);
        _setupVoter(otherHolder, 2);

        uint256 periodStart = block.timestamp;
        vm.warp(periodStart + PROPOSAL_THROTTLE_PERIOD - 1);
        vm.prank(otherHolder);
        stakingVault.redeem(1, otherHolder, otherHolder);
        vm.warp(periodStart + PROPOSAL_THROTTLE_PERIOD);

        uint256 averageVotes = stakingVault.getPastAverageVotes(proposer, periodStart, block.timestamp);
        uint256 averageSupply = stakingVault.getPastAverageSupply(periodStart, block.timestamp);
        uint256 currentSupply = stakingVault.getPastTotalSupply(block.timestamp - 1);
        uint256 threshold = governor.proposalThreshold();
        uint256 normalizedVotes = Math.mulDiv(averageVotes, currentSupply, averageSupply);
        uint256 supplySeconds = 3 * (PROPOSAL_THROTTLE_PERIOD - 1) + 2;

        assertEq(averageVotes, 1);
        assertEq(averageSupply, 3, "fractional average supply rounds up");
        assertEq(currentSupply, 2);
        assertEq(threshold, 1);
        assertEq(normalizedVotes, 0);
        assertGt(supplySeconds, 2 * PROPOSAL_THROTTLE_PERIOD, "average share is below 50%");

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1)));
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorInsufficientProposerVotes.selector, proposer, normalizedVotes, threshold
            )
        );
        governor.propose(targets, values, calldatas, "Reject fractional-average below-threshold proposer");
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

    function test_optimisticProposal_stateTimingBoundaries() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, "State boundaries");

        vm.warp(governor.proposalSnapshot(proposalId));
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));
        vm.warp(block.timestamp + 1);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Active));
        vm.warp(governor.proposalDeadline(proposalId));
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Active));
        vm.warp(block.timestamp + 1);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));
    }

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

    function testFuzz_optimisticProposal_confirmationPreservesPayload(string memory description, bytes memory suffix)
        public
    {
        DummyTarget target = new DummyTarget();
        _allowSelector(address(target), DummyTarget.ping.selector);

        // Exercise distinct targets and values, plus both short and long bytes storage encodings.
        address[] memory targets = new address[](2);
        targets[0] = address(target);
        targets[1] = address(underlying);
        uint256[] memory values = new uint256[](2);
        values[0] = 7;
        values[1] = 19;
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeCall(DummyTarget.ping, ());
        calldatas[1] = bytes.concat(abi.encodeCall(IERC20.transfer, (bob, 123e18)), suffix);
        // Keep arbitrary fuzz input clear of the reserved prefix and proposer suffix validation.
        description = string.concat("Batch: ", description, ".");

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);
        assertEq(governor.vetoThreshold(proposalId), VETO_THRESHOLD);
        _warpToActive(proposalId);

        vm.prank(alice);
        governor.castVote(proposalId, 0);

        // The expected id uses the original inputs; the transition computes it from the stored payload.
        uint256 confirmationId = _confirmationProposalId(targets, values, calldatas, description);
        assertEq(uint256(governor.state(confirmationId)), uint256(IGovernor.ProposalState.Pending));
        assertEq(governor.proposalProposer(confirmationId), optimisticProposer);
        assertEq(governor.vetoThreshold(confirmationId), 0);
        assertEq(governor.vetoThreshold(proposalId), type(uint256).max);
    }

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

    function test_proposalThrottle_isSharedAcrossOptimisticAndStandard() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));

        _setupVoter(optimisticProposer, ALICE_STAKE);
        vm.warp(block.timestamp + PROPOSAL_THROTTLE_PERIOD);

        vm.prank(optimisticProposer);
        governor.proposeOptimistic(targets, values, calldatas, "optimistic #1");
        vm.prank(optimisticProposer);
        governor.propose(targets, values, calldatas, "standard #1");

        vm.prank(optimisticProposer);
        vm.expectRevert(IReserveOptimisticGovernor.OptimisticGovernor__ProposalThrottleExceeded.selector);
        governor.proposeOptimistic(targets, values, calldatas, "optimistic #2");
        vm.prank(optimisticProposer);
        vm.expectRevert(IReserveOptimisticGovernor.OptimisticGovernor__ProposalThrottleExceeded.selector);
        governor.propose(targets, values, calldatas, "standard #2");

        vm.warp(block.timestamp + 6 hours);
        vm.prank(optimisticProposer);
        governor.propose(targets, values, calldatas, "standard #2 after recharge");
        vm.prank(optimisticProposer);
        vm.expectRevert(IReserveOptimisticGovernor.OptimisticGovernor__ProposalThrottleExceeded.selector);
        governor.proposeOptimistic(targets, values, calldatas, "optimistic #2 after shared consume");

        vm.prank(bob);
        governor.propose(targets, values, calldatas, "bob standard #1");
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
        _registerV2Version(address(newImpl), address(timelock));

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(governor), 0, abi.encodeCall(governor.upgradeToAndCall, (address(newImpl), "")));

        (, bytes32 descriptionHash) = _proposePassAndQueueStandard(targets, values, calldatas, "Upgrade governor");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(ReserveOptimisticGovernorV2Mock(payable(address(governor))).version(), "2.0.0");
    }

    function test_upgradeGovernor_revertsForUnwhitelistedImplementation() public {
        ReserveOptimisticGovernorV2Mock newImpl = new ReserveOptimisticGovernorV2Mock();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(governor), 0, abi.encodeCall(governor.upgradeToAndCall, (address(newImpl), "")));

        (, bytes32 descriptionHash) =
            _proposePassAndQueueStandard(targets, values, calldatas, "Upgrade governor without whitelist");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceUpgradeLib.Governance__NotLatestGovernor.selector, address(newImpl))
        );
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function test_cannotUpgradeGovernor_unauthorized() public {
        ReserveOptimisticGovernorV2Mock newImpl = new ReserveOptimisticGovernorV2Mock();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, alice));
        governor.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgradeTimelock_viaGovernance() public {
        TimelockControllerOptimisticV2Mock newImpl = new TimelockControllerOptimisticV2Mock();
        _registerV2Version(address(governor), address(newImpl));

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(timelock), 0, abi.encodeCall(timelock.upgradeToAndCall, (address(newImpl), "")));

        (, bytes32 descriptionHash) = _proposePassAndQueueStandard(targets, values, calldatas, "Upgrade timelock");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(TimelockControllerOptimisticV2Mock(payable(address(timelock))).version(), "2.0.0");
    }

    function test_upgradeAllComponents_succeedsInEveryOrder() public {
        StakingVaultV2Mock stakingVaultImpl = new StakingVaultV2Mock();
        ReserveOptimisticGovernorV2Mock governorImpl = new ReserveOptimisticGovernorV2Mock();
        TimelockControllerOptimisticV2Mock timelockImpl = new TimelockControllerOptimisticV2Mock();
        _registerFullV2Version(address(stakingVaultImpl), address(governorImpl), address(timelockImpl));
        uint256 snapshotId = vm.snapshotState();

        for (uint8 first; first < 3; ++first) {
            for (uint8 second; second < 3; ++second) {
                if (second == first) {
                    continue;
                }
                uint8 third = 3 - first - second;
                vm.revertToState(snapshotId);

                _upgradeComponent(first, address(stakingVaultImpl), address(governorImpl), address(timelockImpl));
                _upgradeComponent(second, address(stakingVaultImpl), address(governorImpl), address(timelockImpl));
                _upgradeComponent(third, address(stakingVaultImpl), address(governorImpl), address(timelockImpl));

                assertEq(stakingVault.version(), "2.0.0");
                assertEq(governor.version(), "2.0.0");
                assertEq(timelock.version(), "2.0.0");
            }
        }
    }

    function test_upgradeTimelock_revertsForUnwhitelistedImplementation() public {
        TimelockControllerOptimisticV2Mock newImpl = new TimelockControllerOptimisticV2Mock();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(timelock), 0, abi.encodeCall(timelock.upgradeToAndCall, (address(newImpl), "")));

        (, bytes32 descriptionHash) =
            _proposePassAndQueueStandard(targets, values, calldatas, "Upgrade timelock without whitelist");
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceUpgradeLib.Governance__NotLatestTimelock.selector, address(newImpl))
        );
        governor.execute(targets, values, calldatas, descriptionHash);
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

    function test_versionRegistry_reinitializerCannotReplaceConfiguredRegistry() public {
        address replacement = address(stakingVault); // nonzero contract, but not the configured registry
        vm.expectRevert(IReserveOptimisticGovernor.OptimisticGovernor__VersionRegistryAlreadySet.selector);
        vm.prank(address(timelock));
        governor.initializeVersionRegistry(replacement);
        vm.expectRevert(ITimelockControllerOptimistic.TimelockControllerOptimistic__VersionRegistryAlreadySet.selector);
        vm.prank(address(timelock));
        timelock.initializeVersionRegistry(replacement);
    }

    function _registerV2Version(address governorImpl, address timelockImpl) internal {
        ReserveOptimisticGovernorDeployerV2Mock v2Deployer = new ReserveOptimisticGovernorDeployerV2Mock(
            address(StakingVault(address(governor.token())).versionRegistry()),
            address(deployer.rewardTokenRegistry()),
            trustedFillerRegistry,
            address(guardianContract),
            address(stakingVault),
            governorImpl,
            timelockImpl,
            address(registry)
        );
        StakingVault(address(governor.token())).versionRegistry().registerVersion(v2Deployer);
    }

    function _registerFullV2Version(address stakingVaultImpl, address governorImpl, address timelockImpl) internal {
        ReserveOptimisticGovernorDeployerV2Mock v2Deployer = new ReserveOptimisticGovernorDeployerV2Mock(
            address(governor.versionRegistry()),
            address(deployer.rewardTokenRegistry()),
            trustedFillerRegistry,
            address(guardianContract),
            stakingVaultImpl,
            governorImpl,
            timelockImpl,
            address(registry)
        );
        governor.versionRegistry().registerVersion(v2Deployer);
    }

    function _upgradeComponent(uint8 component, address stakingVaultImpl, address governorImpl, address timelockImpl)
        internal
    {
        if (component == 0) {
            vm.prank(_useExistingStakingVaultDeployment() ? originalStakingVaultAdmin : address(timelock));
            stakingVault.upgradeToAndCall(stakingVaultImpl, "");
            return;
        }

        address target = component == 1 ? address(governor) : address(timelock);
        bytes memory callData = component == 1
            ? abi.encodeCall(governor.upgradeToAndCall, (governorImpl, ""))
            : abi.encodeCall(timelock.upgradeToAndCall, (timelockImpl, ""));
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleCall(target, 0, callData);
        (, bytes32 descriptionHash) = _proposePassAndQueueStandard(
            targets, values, calldatas, string.concat("Upgrade component ", vm.toString(component))
        );
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
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

    function testFuzz_voteBySig_validatesSignaturesAndNonces(bool optimistic, bool extended, bool contractVoter)
        public
    {
        uint256 privateKey = 0xA11CE;
        address voter = contractVoter ? address(new GovernorSignatureWallet(address(governor))) : vm.addr(privateKey);
        _setupVoter(voter, 11_000e18);
        vm.warp(block.timestamp + 1);

        uint256 proposalId;
        {
            (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
                _singleCall(address(underlying), 0, abi.encodeCall(IERC20.transfer, (alice, 1_000e18)));
            if (optimistic) {
                vm.prank(optimisticProposer);
                proposalId = governor.proposeOptimistic(targets, values, calldatas, "Signed vote");
            } else {
                vm.prank(alice);
                proposalId = governor.propose(targets, values, calldatas, "Signed vote");
            }
        }
        _warpToActive(proposalId);

        uint8 support = optimistic ? 0 : 1;
        bytes32 digest = _ballotDigest(proposalId, support, voter, extended);
        bytes memory signature;
        if (contractVoter) {
            GovernorSignatureWallet(voter).setDigest(digest);
            signature = hex"1271";
        } else {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
            signature = abi.encodePacked(r, s, v);
        }

        // A changed ballot must fail without consuming a nonce or casting a vote.
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, voter));
        _castSignedVote(proposalId, support ^ 1, voter, signature, extended);
        assertEq(governor.nonces(voter), 0);
        assertFalse(governor.hasVoted(proposalId, voter));

        assertEq(_castSignedVote(proposalId, support, voter, signature, extended), 11_000e18);
        assertEq(governor.nonces(voter), 1);
        assertTrue(governor.hasVoted(proposalId, voter));
        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(proposalId);
        assertEq(againstVotes, optimistic ? 11_000e18 : 0);
        assertEq(forVotes, optimistic ? 0 : 11_000e18);
        assertEq(abstainVotes, 0);

        // Replay fails signature validation, rather than reaching the already-voted check.
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, voter));
        _castSignedVote(proposalId, support, voter, signature, extended);
        assertEq(governor.nonces(voter), 1);
    }

    // ===== Helpers =====

    function _ballotDigest(uint256 proposalId, uint8 support, address voter, bool extended)
        internal
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Reserve Optimistic Governor"),
                keccak256("1.1.0"),
                block.chainid,
                address(governor)
            )
        );
        bytes32 ballot = extended
            ? keccak256(
                abi.encode(
                    keccak256(
                        "ExtendedBallot(uint256 proposalId,uint8 support,address voter,uint256 nonce,string reason,bytes params)"
                    ),
                    proposalId,
                    support,
                    voter,
                    uint256(0),
                    keccak256("Signed reason"),
                    keccak256(hex"1234")
                )
            )
            : keccak256(
                abi.encode(
                    keccak256("Ballot(uint256 proposalId,uint8 support,address voter,uint256 nonce)"),
                    proposalId,
                    support,
                    voter,
                    uint256(0)
                )
            );
        return keccak256(abi.encodePacked(hex"1901", domain, ballot));
    }

    function _castSignedVote(uint256 proposalId, uint8 support, address voter, bytes memory signature, bool extended)
        internal
        returns (uint256)
    {
        return extended
            ? governor.castVoteWithReasonAndParamsBySig(
                proposalId, support, voter, "Signed reason", hex"1234", signature
            )
            : governor.castVoteBySig(proposalId, support, voter, signature);
    }

    function _clearAverageVoteHistory(address account) internal {
        bytes32 accountSlot = keccak256(abi.encode(account, VOTE_INTEGRALS_MAPPING_SLOT));
        for (uint32 i; i < stakingVault.numCheckpoints(account); ++i) {
            vm.store(address(stakingVault), keccak256(abi.encode(i, accountSlot)), bytes32(0));
        }
    }

    function _restartAverageVotes(address account) internal {
        _clearAverageVoteHistory(account);
        for (uint32 i; i < 32; ++i) {
            vm.store(address(stakingVault), keccak256(abi.encode(i, SUPPLY_INTEGRALS_MAPPING_SLOT)), bytes32(0));
        }
        uint256 activationState = (stakingVault.totalSupply() << 48) | uint48(block.timestamp);
        vm.store(address(stakingVault), VOTE_INTEGRAL_STATE_SLOT, bytes32(activationState));
    }

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
