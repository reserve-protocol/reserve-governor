// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IReserveGovernor } from "@interfaces/IReserveGovernor.sol";
import { CANCELLER_ROLE, OPTIMISTIC_PROPOSER_ROLE } from "@interfaces/IReserveGovernor.sol";
import { IVetoToken } from "@interfaces/IVetoToken.sol";
import { Deployer, DeploymentParams } from "@src/Deployer.sol";
import { OptimisticProposal } from "@src/OptimisticProposal.sol";
import { ReserveGovernor } from "@src/ReserveGovernor.sol";
import { TimelockControllerOptimistic } from "@src/TimelockControllerOptimistic.sol";

import { StakingVault } from "@reserve-protocol/reserve-index-dtf/staking/StakingVault.sol";

import { MockERC20 } from "./mocks/MockERC20.sol";

contract ReserveGovernorTest is Test {
    // Contracts
    MockERC20 public underlying;
    StakingVault public stakingVault;
    Deployer public deployer;
    ReserveGovernor public governor;
    TimelockControllerOptimistic public timelock;

    // Test accounts
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public guardian = makeAddr("guardian");
    address public optimisticProposer = makeAddr("optimisticProposer");

    // Test parameters
    uint32 constant VETO_PERIOD = 2 hours;
    uint256 constant VETO_THRESHOLD = 0.05e18; // 5%
    uint256 constant SLASHING_PERCENTAGE = 0.1e18; // 10%
    uint256 constant NUM_PARALLEL_PROPOSALS = 3;

    uint48 constant VOTING_DELAY = 1 days;
    uint32 constant VOTING_PERIOD = 1 weeks;
    uint48 constant VOTE_EXTENSION = 1 days;
    uint256 constant PROPOSAL_THRESHOLD = 0.01e18; // 1%
    uint256 constant QUORUM_NUMERATOR = 10; // 10%

    uint256 constant TIMELOCK_DELAY = 2 days;

    // StakingVault parameters
    uint256 constant REWARD_HALF_LIFE = 1 days;
    uint256 constant UNSTAKING_DELAY = 0;

    // Token amounts
    uint256 constant INITIAL_SUPPLY = 1_000_000e18;

    function setUp() public {
        // Deploy underlying token
        underlying = new MockERC20("Underlying Token", "UNDL");

        // Deploy StakingVault
        stakingVault = new StakingVault(
            "Staked Token",
            "stTKN",
            IERC20(address(underlying)),
            address(this), // owner
            REWARD_HALF_LIFE,
            UNSTAKING_DELAY
        );

        // Deploy implementations
        ReserveGovernor governorImpl = new ReserveGovernor();
        TimelockControllerOptimistic timelockImpl = new TimelockControllerOptimistic();

        // Deploy Deployer
        deployer = new Deployer(address(governorImpl), address(timelockImpl));

        // Prepare deployment parameters
        address[] memory optimisticProposers = new address[](1);
        optimisticProposers[0] = optimisticProposer;

        address[] memory guardians = new address[](1);
        guardians[0] = guardian;

        DeploymentParams memory params = DeploymentParams({
            optimisticParams: IReserveGovernor.OptimisticGovernanceParams({
                vetoPeriod: VETO_PERIOD,
                vetoThreshold: VETO_THRESHOLD,
                slashingPercentage: SLASHING_PERCENTAGE,
                numParallelProposals: NUM_PARALLEL_PROPOSALS
            }),
            standardParams: IReserveGovernor.StandardGovernanceParams({
                votingDelay: VOTING_DELAY,
                votingPeriod: VOTING_PERIOD,
                voteExtension: VOTE_EXTENSION,
                proposalThreshold: PROPOSAL_THRESHOLD,
                quorumNumerator: QUORUM_NUMERATOR
            }),
            token: IVetoToken(address(stakingVault)),
            optimisticProposers: optimisticProposers,
            guardians: guardians,
            timelockDelay: TIMELOCK_DELAY
        });

        // Deploy governance system
        (address governorAddr, address timelockAddr) = deployer.deploy(params);
        governor = ReserveGovernor(payable(governorAddr));
        timelock = TimelockControllerOptimistic(payable(timelockAddr));

        // Mint tokens to test users and have them deposit into StakingVault
        _setupVoter(alice, INITIAL_SUPPLY / 2);
        _setupVoter(bob, INITIAL_SUPPLY / 2);
    }

    function _setupVoter(address voter, uint256 amount) internal {
        underlying.mint(voter, amount);

        vm.startPrank(voter);
        underlying.approve(address(stakingVault), amount);
        stakingVault.depositAndDelegate(amount);
        vm.stopPrank();
    }

    function test_slowProposal_standardFlow() public {
        // Setup: Send some tokens to the timelock for the proposal to transfer
        uint256 transferAmount = 1000e18;
        underlying.mint(address(timelock), transferAmount);

        // Create proposal data: transfer tokens from timelock to alice
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, transferAmount));

        string memory description = "Transfer tokens to alice";

        // Warp to ensure we have a snapshot
        vm.warp(block.timestamp + 1);

        // Step 1: Propose
        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        // Verify proposal is pending
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));

        // Step 2: Warp past voting delay
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // Verify proposal is active
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Active));

        // Step 3: Cast votes to meet quorum
        vm.prank(alice);
        governor.castVote(proposalId, 1); // Vote for

        vm.prank(bob);
        governor.castVote(proposalId, 1); // Vote for

        // Step 4: Warp past voting period
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        // Verify proposal succeeded
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));

        // Step 5: Queue the proposal
        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);

        // Verify proposal is queued
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Queued));

        // Step 6: Warp past timelock delay
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // Step 7: Execute the proposal
        uint256 aliceBalanceBefore = underlying.balanceOf(alice);
        governor.execute(targets, values, calldatas, descriptionHash);

        // Step 8: Assert proposal executed successfully
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed));
        assertEq(underlying.balanceOf(alice), aliceBalanceBefore + transferAmount);
    }

    // ==================== F1: Uncontested Success ====================
    // Active → Succeeded → Executed

    function test_fastProposal_F1_uncontestedSuccess() public {
        // Setup: Send some tokens to the timelock for the proposal to transfer
        uint256 transferAmount = 1000e18;
        underlying.mint(address(timelock), transferAmount);

        // Create proposal data: transfer tokens from timelock to alice
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, transferAmount));

        string memory description = "Transfer tokens to alice via optimistic";

        // Step 1: Propose optimistically
        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        // Verify proposal is optimistic and active
        assertEq(uint256(governor.proposalType(proposalId)), uint256(IReserveGovernor.ProposalType.Optimistic));
        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Active));

        // Step 2: Warp past veto period
        vm.warp(block.timestamp + VETO_PERIOD + 1);

        // Verify proposal succeeded
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Succeeded));

        // Step 3: Execute the optimistic proposal
        uint256 aliceBalanceBefore = underlying.balanceOf(alice);
        vm.prank(optimisticProposer);
        governor.executeOptimistic(proposalId);

        // Step 4: Assert proposal executed successfully
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Executed));
        assertEq(underlying.balanceOf(alice), aliceBalanceBefore + transferAmount);
    }

    // ==================== F2: Early Cancellation ====================
    // Active → Canceled

    function test_fastProposal_F2_earlyCancellation_byGuardian() public {
        // Create proposal
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens - will be canceled";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Active));

        // Cancel by guardian
        vm.prank(guardian);
        optProposal.cancel();

        // Verify canceled
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Canceled));
    }

    function test_fastProposal_F2_earlyCancellation_byProposer() public {
        // Create proposal
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens - proposer cancels";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

        // Cancel by optimistic proposer
        vm.prank(optimisticProposer);
        optProposal.cancel();

        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Canceled));
    }

    // ==================== F3: Dispute Passes (Slashed) ====================
    // Active → Locked → Slashed

    function test_fastProposal_F3_disputePasses_slashed() public {
        // Setup: Send tokens to timelock
        uint256 transferAmount = 1000e18;
        underlying.mint(address(timelock), transferAmount);

        // Create proposal
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, transferAmount));

        string memory description = "Transfer tokens - will be disputed";

        // Warp to ensure we have a snapshot
        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

        // Calculate veto threshold
        uint256 vetoThreshold = optProposal.vetoThreshold();

        // Alice stakes to veto (enough to trigger dispute)
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), vetoThreshold);
        optProposal.stakeToVeto(vetoThreshold);
        vm.stopPrank();

        // Verify proposal is now locked (dispute started)
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

        // Verify slow proposal was created (proposalType should now be Standard)
        assertEq(uint256(governor.proposalType(proposalId)), uint256(IReserveGovernor.ProposalType.Standard));

        // Warp past voting delay
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // Cast votes - both alice and bob vote FOR (dispute passes = vetoers were wrong)
        vm.prank(alice);
        governor.castVote(proposalId, 1); // Vote for

        vm.prank(bob);
        governor.castVote(proposalId, 1); // Vote for

        // Warp past voting period
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        // Verify succeeded
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));

        // Queue the proposal (use modified description from OptimisticProposal which includes #proposer= suffix)
        bytes32 descriptionHash = keccak256(bytes(optProposal.description()));
        governor.queue(targets, values, calldatas, descriptionHash);

        // Warp past timelock delay
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // Execute - this should slash stakers
        uint256 aliceStakingBalanceBefore = stakingVault.balanceOf(alice);
        governor.execute(targets, values, calldatas, descriptionHash);

        // Verify slashed state
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Slashed));

        // Alice withdraws - should receive less due to slashing
        uint256 aliceStaked = vetoThreshold;
        uint256 expectedSlash = (aliceStaked * SLASHING_PERCENTAGE) / 1e18;
        uint256 expectedWithdrawal = aliceStaked - expectedSlash;

        vm.prank(alice);
        optProposal.withdraw();

        // Verify alice got slashed amount back
        assertEq(stakingVault.balanceOf(alice), aliceStakingBalanceBefore + expectedWithdrawal);
    }

    // ==================== F4: Dispute Fails (Vetoed) ====================
    // Active → Locked → Vetoed

    function test_fastProposal_F4_disputeFails_vetoed() public {
        // Create proposal
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens - veto succeeds";

        // Warp to ensure we have a snapshot
        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
        uint256 vetoThreshold = optProposal.vetoThreshold();

        // Alice stakes to veto
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), vetoThreshold);
        optProposal.stakeToVeto(vetoThreshold);
        vm.stopPrank();

        // Verify locked
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

        // Warp past voting delay
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // Cast votes AGAINST (veto succeeds = vetoers were right)
        vm.prank(alice);
        governor.castVote(proposalId, 0); // Vote against

        vm.prank(bob);
        governor.castVote(proposalId, 0); // Vote against

        // Warp past voting period
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        // Verify defeated
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Defeated));

        // Verify vetoed state
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Vetoed));

        // Alice withdraws - should receive full amount (no slashing)
        uint256 aliceStakingBalanceBefore = stakingVault.balanceOf(alice);

        vm.prank(alice);
        optProposal.withdraw();

        // Verify alice got full stake back
        assertEq(stakingVault.balanceOf(alice), aliceStakingBalanceBefore + vetoThreshold);
    }

    // ==================== F5a: Dispute Canceled ====================
    // Active → Locked → Canceled

    function test_fastProposal_F5a_disputeCanceled() public {
        // Create proposal
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens - dispute canceled";

        // Warp to ensure we have a snapshot
        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
        uint256 vetoThreshold = optProposal.vetoThreshold();

        // Alice stakes to veto
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), vetoThreshold);
        optProposal.stakeToVeto(vetoThreshold);
        vm.stopPrank();

        // Verify locked
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

        // Guardian cancels the slow proposal (dispute)
        // Use modified description from OptimisticProposal which includes #proposer= suffix
        bytes32 descriptionHash = keccak256(bytes(optProposal.description()));
        vm.prank(guardian);
        governor.cancel(targets, values, calldatas, descriptionHash);

        // Verify canceled state
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Canceled));

        // Alice withdraws - should receive full amount
        uint256 aliceStakingBalanceBefore = stakingVault.balanceOf(alice);

        vm.prank(alice);
        optProposal.withdraw();

        assertEq(stakingVault.balanceOf(alice), aliceStakingBalanceBefore + vetoThreshold);
    }

    // ==================== F5b: Dispute Vote Expires (No Quorum) ====================
    // Active → Locked → Vetoed (via vote not reaching quorum)

    function test_fastProposal_F5b_disputeNoQuorum() public {
        // Create proposal
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens - dispute no quorum";

        // Warp to ensure we have a snapshot
        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
        uint256 vetoThreshold = optProposal.vetoThreshold();

        // Alice stakes to veto
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), vetoThreshold);
        optProposal.stakeToVeto(vetoThreshold);
        vm.stopPrank();

        // Verify locked
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

        // Warp past voting delay
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // Nobody votes - quorum not reached

        // Warp past voting period
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        // Verify defeated (no quorum)
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Defeated));

        // Verify vetoed state (since dispute failed due to no quorum)
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Vetoed));

        // Alice withdraws - should receive full amount (no slashing when veto succeeds)
        uint256 aliceStakingBalanceBefore = stakingVault.balanceOf(alice);

        vm.prank(alice);
        optProposal.withdraw();

        assertEq(stakingVault.balanceOf(alice), aliceStakingBalanceBefore + vetoThreshold);
    }

    // ==================== Additional Edge Cases ====================

    function test_stakeToVeto_partialStaking() public {
        // Create proposal
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens - partial staking";

        // Warp to ensure we have a snapshot with non-zero supply
        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
        uint256 vetoThreshold = optProposal.vetoThreshold();
        uint256 partialStake = vetoThreshold / 2;

        // Alice stakes partial amount
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), partialStake);
        optProposal.stakeToVeto(partialStake);
        vm.stopPrank();

        // Should still be active (not locked yet)
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Active));
        assertEq(optProposal.totalStaked(), partialStake);

        // Alice can withdraw during active state
        uint256 aliceStakingBalanceBefore = stakingVault.balanceOf(alice);

        vm.prank(alice);
        optProposal.withdraw();

        assertEq(stakingVault.balanceOf(alice), aliceStakingBalanceBefore + partialStake);
    }

    function test_multipleStakersReachThreshold() public {
        // Create proposal
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens - multiple stakers";

        // Warp to ensure we have a snapshot
        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
        uint256 vetoThreshold = optProposal.vetoThreshold();
        uint256 aliceStake = vetoThreshold / 2;
        uint256 bobStake = vetoThreshold - aliceStake + 1; // Just over threshold

        // Alice stakes partial amount
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), aliceStake);
        optProposal.stakeToVeto(aliceStake);
        vm.stopPrank();

        // Still active
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Active));

        // Bob stakes to reach threshold
        vm.startPrank(bob);
        stakingVault.approve(address(optProposal), bobStake);
        optProposal.stakeToVeto(bobStake);
        vm.stopPrank();

        // Now locked
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

        // Verify both stakes recorded
        assertEq(optProposal.staked(alice), aliceStake);
        assertEq(optProposal.staked(bob), bobStake);
        assertEq(optProposal.totalStaked(), aliceStake + bobStake);
    }

    function test_cannotStakeAfterVetoPeriod() public {
        // Create proposal
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens - late staking";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

        // Warp past veto period
        vm.warp(block.timestamp + VETO_PERIOD + 1);

        // Verify succeeded
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Succeeded));

        // Try to stake - should fail
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), 1000e18);
        vm.expectRevert("OptimisticProposal: not active");
        optProposal.stakeToVeto(1000e18);
        vm.stopPrank();
    }

    function test_cannotWithdrawWhileLocked() public {
        // Create proposal
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens - withdraw while locked";

        // Warp to ensure we have a snapshot
        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
        uint256 vetoThreshold = optProposal.vetoThreshold();

        // Alice stakes to trigger dispute
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), vetoThreshold);
        optProposal.stakeToVeto(vetoThreshold);
        vm.stopPrank();

        // Verify locked
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

        // Try to withdraw - should fail
        vm.prank(alice);
        vm.expectRevert("OptimisticProposal: under dispute");
        optProposal.withdraw();
    }
}
