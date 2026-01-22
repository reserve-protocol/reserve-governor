// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import { Test } from "forge-std/Test.sol";

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IReserveGovernor } from "@interfaces/IReserveGovernor.sol";
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
        uint256 remaining = vetoThreshold - aliceStake;
        uint256 bobAttemptedStake = remaining * 2; // Bob tries to overstake by 2x

        // Alice stakes partial amount
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), aliceStake);
        optProposal.stakeToVeto(aliceStake);
        vm.stopPrank();

        // Still active
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Active));

        // Bob stakes to reach threshold (attempts 2x more than needed, but capped)
        uint256 bobBalanceBefore = stakingVault.balanceOf(bob);
        vm.startPrank(bob);
        stakingVault.approve(address(optProposal), bobAttemptedStake);
        optProposal.stakeToVeto(bobAttemptedStake);
        vm.stopPrank();

        // Now locked
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

        // Verify stakes recorded (Bob's stake is capped to remaining threshold)
        assertEq(optProposal.staked(alice), aliceStake);
        assertEq(optProposal.staked(bob), remaining);
        assertEq(optProposal.totalStaked(), vetoThreshold);

        // Verify Bob only transferred the capped amount
        assertEq(stakingVault.balanceOf(bob), bobBalanceBefore - remaining);
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

    // ==================== Negative Tests: #proposer= Suffix Manipulation ====================

    function test_cannotCreateSlowProposalWithOptimisticDescription() public {
        // Create an optimistic proposal first
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        // Warp to ensure we have a snapshot
        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

        // Attacker tries to call propose() with the same description that includes #proposer= suffix
        // This would allow them to create a slow proposal matching the optimistic one
        string memory attackerDescription = optProposal.description();

        // Should revert because alice is not the OptimisticProposal contract
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorRestrictedProposer.selector, alice));
        governor.propose(targets, values, calldatas, attackerDescription);
    }

    function test_proposerSuffixInOriginalDescription() public {
        // OptimisticProposer includes #proposer= in original description
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        // Description already has a #proposer= suffix
        string memory description = "Transfer tokens#proposer=0x1234567890123456789012345678901234567890";

        vm.warp(block.timestamp + 1);

        // This should succeed - the system will append another #proposer= suffix
        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

        // Verify the description has double suffix
        string memory storedDesc = optProposal.description();
        assertTrue(
            bytes(storedDesc).length > bytes(description).length, "Description should have additional suffix appended"
        );
    }

    // ==================== Negative Tests: Proposal ID Collision ====================

    function test_canCreateMultipleIdenticalOptimisticProposals() public {
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        vm.startPrank(optimisticProposer);

        // Create first proposal
        uint256 proposalId1 = governor.proposeOptimistic(targets, values, calldatas, description);

        // Create second with identical params - should succeed with different proposalId
        uint256 proposalId2 = governor.proposeOptimistic(targets, values, calldatas, description);

        // Create third with identical params - should also succeed
        uint256 proposalId3 = governor.proposeOptimistic(targets, values, calldatas, description);

        vm.stopPrank();

        // Verify all proposal IDs are unique (due to unique clone addresses in description suffix)
        assertTrue(proposalId1 != proposalId2, "Proposal IDs 1 and 2 should differ");
        assertTrue(proposalId2 != proposalId3, "Proposal IDs 2 and 3 should differ");
        assertTrue(proposalId1 != proposalId3, "Proposal IDs 1 and 3 should differ");

        // Verify each proposal has a unique OptimisticProposal clone
        OptimisticProposal optProposal1 = governor.optimisticProposals(proposalId1);
        OptimisticProposal optProposal2 = governor.optimisticProposals(proposalId2);
        OptimisticProposal optProposal3 = governor.optimisticProposals(proposalId3);

        assertTrue(address(optProposal1) != address(optProposal2), "Clone addresses 1 and 2 should differ");
        assertTrue(address(optProposal2) != address(optProposal3), "Clone addresses 2 and 3 should differ");
        assertTrue(address(optProposal1) != address(optProposal3), "Clone addresses 1 and 3 should differ");
    }

    function test_cannotCreateSlowProposalMatchingOptimistic() public {
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        vm.warp(block.timestamp + 1);

        // Create optimistic proposal
        vm.prank(optimisticProposer);
        uint256 optProposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        // Create slow proposal with same targets/values/calldatas but original description (no suffix)
        // This should succeed because the proposalIds will be different (different description hash)
        vm.prank(alice);
        uint256 slowProposalId = governor.propose(targets, values, calldatas, description);

        // Verify they're different proposal IDs
        assertTrue(optProposalId != slowProposalId, "Proposal IDs should be different");
    }

    function test_proposalTypeAfterDispute() public {
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        // Initially it's Optimistic
        assertEq(uint256(governor.proposalType(proposalId)), uint256(IReserveGovernor.ProposalType.Optimistic));

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
        uint256 vetoThreshold = optProposal.vetoThreshold();

        // Stake to trigger dispute
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), vetoThreshold);
        optProposal.stakeToVeto(vetoThreshold);
        vm.stopPrank();

        // After dispute triggered, it should be Standard
        assertEq(uint256(governor.proposalType(proposalId)), uint256(IReserveGovernor.ProposalType.Standard));
    }

    // ==================== Negative Tests: Meta-Governance Restrictions ====================

    function test_cannotTargetGovernorViaOptimistic() public {
        // Optimistic proposal targeting ReserveGovernor
        address[] memory targets = new address[](1);
        targets[0] = address(governor);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(
            governor.setOptimisticParams, (IReserveGovernor.OptimisticGovernanceParams(1 hours, 0.1e18, 0.1e18, 2))
        );

        string memory description = "Malicious governor update";

        vm.prank(optimisticProposer);
        vm.expectRevert(IReserveGovernor.NoMetaGovernanceThroughOptimistic.selector);
        governor.proposeOptimistic(targets, values, calldatas, description);
    }

    function test_cannotTargetTimelockViaOptimistic() public {
        // Optimistic proposal targeting TimelockControllerOptimistic
        address[] memory targets = new address[](1);
        targets[0] = address(timelock);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(timelock.updateDelay, (0));

        string memory description = "Malicious timelock update";

        vm.prank(optimisticProposer);
        vm.expectRevert(IReserveGovernor.NoMetaGovernanceThroughOptimistic.selector);
        governor.proposeOptimistic(targets, values, calldatas, description);
    }

    function test_canTargetGovernorViaSlow() public {
        // Standard proposal can target governor (meta-governance allowed)
        address[] memory targets = new address[](1);
        targets[0] = address(governor);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(
            governor.setOptimisticParams, (IReserveGovernor.OptimisticGovernanceParams(1 hours, 0.1e18, 0.1e18, 2))
        );

        string memory description = "Legitimate governor update";

        vm.warp(block.timestamp + 1);

        // Should succeed
        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_canTargetTimelockViaSlow() public {
        // Standard proposal can target timelock (meta-governance allowed)
        address[] memory targets = new address[](1);
        targets[0] = address(timelock);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(timelock.updateDelay, (1 days));

        string memory description = "Legitimate timelock update";

        vm.warp(block.timestamp + 1);

        // Should succeed
        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));
    }

    // ==================== Negative Tests: Parallel Proposals Limit ====================

    function test_cannotExceedParallelProposals() public {
        vm.warp(block.timestamp + 1);

        // Create MAX (3) optimistic proposals
        for (uint256 i = 0; i < NUM_PARALLEL_PROPOSALS; i++) {
            address[] memory targets = new address[](1);
            targets[0] = address(underlying);

            uint256[] memory values = new uint256[](1);
            values[0] = 0;

            bytes[] memory calldatas = new bytes[](1);
            calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18 + i)); // Different calldata

            string memory description = string(abi.encodePacked("Transfer ", vm.toString(i)));

            vm.prank(optimisticProposer);
            governor.proposeOptimistic(targets, values, calldatas, description);
        }

        // Try to create one more - should fail
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 2000e18));

        string memory description = "Transfer overflow";

        vm.prank(optimisticProposer);
        vm.expectRevert(IReserveGovernor.TooManyParallelOptimisticProposals.selector);
        governor.proposeOptimistic(targets, values, calldatas, description);
    }

    function test_parallelLimitClearsAfterExecution() public {
        underlying.mint(address(timelock), 10000e18);

        vm.warp(block.timestamp + 1);

        uint256[] memory proposalIds = new uint256[](NUM_PARALLEL_PROPOSALS);

        // Create MAX optimistic proposals
        for (uint256 i = 0; i < NUM_PARALLEL_PROPOSALS; i++) {
            address[] memory targets = new address[](1);
            targets[0] = address(underlying);

            uint256[] memory values = new uint256[](1);
            values[0] = 0;

            bytes[] memory calldatas = new bytes[](1);
            calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18 + i));

            string memory description = string(abi.encodePacked("Transfer ", vm.toString(i)));

            vm.prank(optimisticProposer);
            proposalIds[i] = governor.proposeOptimistic(targets, values, calldatas, description);
        }

        // Execute the first one
        vm.warp(block.timestamp + VETO_PERIOD + 1);

        vm.prank(optimisticProposer);
        governor.executeOptimistic(proposalIds[0]);

        // Now we should be able to create another
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 5000e18));

        string memory description = "Transfer after execution";

        vm.prank(optimisticProposer);
        uint256 newProposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        assertTrue(newProposalId != 0, "Should have created new proposal");
    }

    function test_parallelLimitClearsAfterVeto() public {
        vm.warp(block.timestamp + 1);

        uint256[] memory proposalIds = new uint256[](NUM_PARALLEL_PROPOSALS);

        // Create MAX optimistic proposals
        for (uint256 i = 0; i < NUM_PARALLEL_PROPOSALS; i++) {
            address[] memory targets = new address[](1);
            targets[0] = address(underlying);

            uint256[] memory values = new uint256[](1);
            values[0] = 0;

            bytes[] memory calldatas = new bytes[](1);
            calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18 + i));

            string memory description = string(abi.encodePacked("Transfer ", vm.toString(i)));

            vm.prank(optimisticProposer);
            proposalIds[i] = governor.proposeOptimistic(targets, values, calldatas, description);
        }

        // Veto the first one by staking and then voting against
        OptimisticProposal optProposal = governor.optimisticProposals(proposalIds[0]);
        uint256 vetoThreshold = optProposal.vetoThreshold();

        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), vetoThreshold);
        optProposal.stakeToVeto(vetoThreshold);
        vm.stopPrank();

        // Warp past voting delay and vote against
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        governor.castVote(proposalIds[0], 0); // Vote against
        vm.prank(bob);
        governor.castVote(proposalIds[0], 0); // Vote against

        // Warp past voting period
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        // Verify vetoed
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Vetoed));

        // Now we should be able to create another
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 5000e18));

        string memory description = "Transfer after veto";

        vm.prank(optimisticProposer);
        uint256 newProposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        assertTrue(newProposalId != 0, "Should have created new proposal");
    }

    // ==================== Negative Tests: State Transition Edge Cases ====================

    function test_cannotExecuteOptimisticWhileLocked() public {
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
        uint256 vetoThreshold = optProposal.vetoThreshold();

        // Stake to trigger dispute (locked state)
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), vetoThreshold);
        optProposal.stakeToVeto(vetoThreshold);
        vm.stopPrank();

        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

        // Try to execute optimistic - should fail
        vm.prank(optimisticProposer);
        vm.expectRevert(abi.encodeWithSelector(IReserveGovernor.OptimisticProposalNotSuccessful.selector, proposalId));
        governor.executeOptimistic(proposalId);
    }

    function test_cannotExecuteOptimisticAfterVetoed() public {
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
        uint256 vetoThreshold = optProposal.vetoThreshold();

        // Stake to trigger dispute
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), vetoThreshold);
        optProposal.stakeToVeto(vetoThreshold);
        vm.stopPrank();

        // Vote against (veto succeeds)
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 0);
        vm.prank(bob);
        governor.castVote(proposalId, 0);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Vetoed));

        // Try to execute optimistic - should fail
        vm.prank(optimisticProposer);
        vm.expectRevert(abi.encodeWithSelector(IReserveGovernor.OptimisticProposalNotSuccessful.selector, proposalId));
        governor.executeOptimistic(proposalId);
    }

    function test_cannotExecuteOptimisticAfterSlashed() public {
        underlying.mint(address(timelock), 10000e18);

        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
        uint256 vetoThreshold = optProposal.vetoThreshold();

        // Stake to trigger dispute
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), vetoThreshold);
        optProposal.stakeToVeto(vetoThreshold);
        vm.stopPrank();

        // Vote FOR (dispute passes = slash stakers)
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(bob);
        governor.castVote(proposalId, 1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        // Queue and execute the slow proposal
        bytes32 descriptionHash = keccak256(bytes(optProposal.description()));
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Slashed));

        // Try to execute optimistic - should fail
        vm.prank(optimisticProposer);
        vm.expectRevert(abi.encodeWithSelector(IReserveGovernor.OptimisticProposalNotSuccessful.selector, proposalId));
        governor.executeOptimistic(proposalId);
    }

    function test_governorStateRevertsForUndisputedOptimistic() public {
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        // Calling state() on an active (undisputed) optimistic proposal should revert
        // because there's no slow proposal yet
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorNonexistentProposal.selector, proposalId));
        governor.state(proposalId);
    }

    // ==================== Negative Tests: Staking Edge Cases ====================

    function test_cannotStakeZero() public {
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

        vm.prank(alice);
        vm.expectRevert("OptimisticProposal: zero stake");
        optProposal.stakeToVeto(0);
    }

    function test_cannotStakeWhenSucceeded() public {
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

        // Warp past veto period
        vm.warp(block.timestamp + VETO_PERIOD + 1);

        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Succeeded));

        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), 1000e18);
        vm.expectRevert("OptimisticProposal: not active");
        optProposal.stakeToVeto(1000e18);
        vm.stopPrank();
    }

    function test_cannotStakeWhenLocked() public {
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
        uint256 vetoThreshold = optProposal.vetoThreshold();

        // Alice stakes to trigger lock
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), vetoThreshold);
        optProposal.stakeToVeto(vetoThreshold);
        vm.stopPrank();

        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

        // Bob tries to stake while locked
        vm.startPrank(bob);
        stakingVault.approve(address(optProposal), 1000e18);
        vm.expectRevert("OptimisticProposal: not active");
        optProposal.stakeToVeto(1000e18);
        vm.stopPrank();
    }

    function test_withdrawRoundsDownWithSlashing() public {
        underlying.mint(address(timelock), 10000e18);

        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
        uint256 vetoThreshold = optProposal.vetoThreshold();

        // Stake a tiny amount (1 wei) plus enough to reach threshold
        uint256 tinyStake = 1;
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), vetoThreshold + tinyStake);
        optProposal.stakeToVeto(vetoThreshold + tinyStake);
        vm.stopPrank();

        // Vote FOR to slash
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(bob);
        governor.castVote(proposalId, 1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        bytes32 descriptionHash = keccak256(bytes(optProposal.description()));
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        // Calculate expected withdrawal
        uint256 staked = vetoThreshold + tinyStake;
        uint256 expectedWithdrawal = (staked * (1e18 - SLASHING_PERCENTAGE)) / 1e18;

        uint256 balanceBefore = stakingVault.balanceOf(alice);

        vm.prank(alice);
        optProposal.withdraw();

        // Verify withdrawal math is correct
        assertEq(stakingVault.balanceOf(alice), balanceBefore + expectedWithdrawal);
    }

    function test_multipleStakersThresholdOnce() public {
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
        uint256 vetoThreshold = optProposal.vetoThreshold();

        // Alice stakes just under threshold
        uint256 aliceStake = vetoThreshold - 1;
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), aliceStake);
        optProposal.stakeToVeto(aliceStake);
        vm.stopPrank();

        // Still active
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Active));

        // Bob tries to stake 2 when only 1 is needed (overstake is capped)
        uint256 bobBalanceBefore = stakingVault.balanceOf(bob);
        vm.startPrank(bob);
        stakingVault.approve(address(optProposal), 2);
        optProposal.stakeToVeto(2);
        vm.stopPrank();

        // Now locked - dispute should have been created exactly once
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));
        assertEq(uint256(governor.proposalType(proposalId)), uint256(IReserveGovernor.ProposalType.Standard));

        // Verify Bob's stake was capped to 1 (only what was needed)
        assertEq(optProposal.staked(bob), 1);
        assertEq(optProposal.totalStaked(), vetoThreshold);
        assertEq(stakingVault.balanceOf(bob), bobBalanceBefore - 1);
    }

    // ==================== Negative Tests: Cancel Flow ====================

    function test_cannotCancelOptimisticWhenLocked() public {
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
        uint256 vetoThreshold = optProposal.vetoThreshold();

        // Stake to trigger lock
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), vetoThreshold);
        optProposal.stakeToVeto(vetoThreshold);
        vm.stopPrank();

        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

        // OptimisticProposer tries to cancel the OptimisticProposal (not the slow proposal)
        vm.prank(optimisticProposer);
        vm.expectRevert("OptimisticProposal: cannot cancel");
        optProposal.cancel();
    }

    function test_guardianCanCancelDispute() public {
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
        uint256 vetoThreshold = optProposal.vetoThreshold();

        // Stake to trigger dispute
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), vetoThreshold);
        optProposal.stakeToVeto(vetoThreshold);
        vm.stopPrank();

        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

        // Guardian cancels the slow (dispute) proposal via governor
        bytes32 descriptionHash = keccak256(bytes(optProposal.description()));

        vm.prank(guardian);
        governor.cancel(targets, values, calldatas, descriptionHash);

        // OptimisticProposal should be Canceled
        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Canceled));
    }

    function test_randomUserCannotCancelOptimistic() public {
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

        // Random user tries to cancel
        address randomUser = makeAddr("randomUser");
        vm.prank(randomUser);
        vm.expectRevert("OptimisticProposal: cannot cancel");
        optProposal.cancel();
    }

    function test_optimisticProposerCanCancelActive() public {
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Active));

        // OptimisticProposer can cancel during Active state
        vm.prank(optimisticProposer);
        optProposal.cancel();

        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Canceled));
    }

    // ==================== Negative Tests: Permission Tests ====================

    function test_cannotProposeOptimisticWithoutRole() public {
        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        // Alice (not optimistic proposer) tries to propose optimistically
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IReserveGovernor.NotOptimisticProposer.selector, alice));
        governor.proposeOptimistic(targets, values, calldatas, description);
    }

    function test_cannotExecuteOptimisticWithoutRole() public {
        underlying.mint(address(timelock), 10000e18);

        address[] memory targets = new address[](1);
        targets[0] = address(underlying);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory description = "Transfer tokens";

        vm.prank(optimisticProposer);
        uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

        // Warp past veto period
        vm.warp(block.timestamp + VETO_PERIOD + 1);

        // Alice (not optimistic proposer) tries to execute
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IReserveGovernor.NotOptimisticProposer.selector, alice));
        governor.executeOptimistic(proposalId);
    }

    // ==================== Negative Tests: Parameter Validation ====================

    function test_cannotSetVetoPeriodBelowMin() public {
        // Setup a governance proposal to change params
        address[] memory targets = new address[](1);
        targets[0] = address(governor);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        // vetoPeriod = 1 minute (< 30 minutes minimum)
        IReserveGovernor.OptimisticGovernanceParams memory badParams = IReserveGovernor.OptimisticGovernanceParams({
            vetoPeriod: 1 minutes,
            vetoThreshold: VETO_THRESHOLD,
            slashingPercentage: SLASHING_PERCENTAGE,
            numParallelProposals: NUM_PARALLEL_PROPOSALS
        });

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(governor.setOptimisticParams, (badParams));

        string memory description = "Set bad veto period";

        vm.warp(block.timestamp + 1);

        // Create and pass the proposal
        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(bob);
        governor.castVote(proposalId, 1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // Execution should revert
        vm.expectRevert(IReserveGovernor.InvalidVetoParameters.selector);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function test_cannotSetVetoThresholdAboveMax() public {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        // vetoThreshold = 25% (> 20% maximum)
        IReserveGovernor.OptimisticGovernanceParams memory badParams = IReserveGovernor.OptimisticGovernanceParams({
            vetoPeriod: VETO_PERIOD,
            vetoThreshold: 0.25e18,
            slashingPercentage: SLASHING_PERCENTAGE,
            numParallelProposals: NUM_PARALLEL_PROPOSALS
        });

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(governor.setOptimisticParams, (badParams));

        string memory description = "Set bad veto threshold";

        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(bob);
        governor.castVote(proposalId, 1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.expectRevert(IReserveGovernor.InvalidVetoParameters.selector);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function test_cannotSetVetoThresholdZero() public {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        // vetoThreshold = 0
        IReserveGovernor.OptimisticGovernanceParams memory badParams = IReserveGovernor.OptimisticGovernanceParams({
            vetoPeriod: VETO_PERIOD,
            vetoThreshold: 0,
            slashingPercentage: SLASHING_PERCENTAGE,
            numParallelProposals: NUM_PARALLEL_PROPOSALS
        });

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(governor.setOptimisticParams, (badParams));

        string memory description = "Set zero veto threshold";

        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(bob);
        governor.castVote(proposalId, 1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.expectRevert(IReserveGovernor.InvalidVetoParameters.selector);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function test_zeroSlashingPercentageAllowed() public {
        // Step 1: Set slashing percentage to 0 via slow proposal
        address[] memory targets = new address[](1);
        targets[0] = address(governor);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        IReserveGovernor.OptimisticGovernanceParams memory zeroSlashParams = IReserveGovernor.OptimisticGovernanceParams({
            vetoPeriod: VETO_PERIOD,
            vetoThreshold: VETO_THRESHOLD,
            slashingPercentage: 0,
            numParallelProposals: NUM_PARALLEL_PROPOSALS
        });

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(governor.setOptimisticParams, (zeroSlashParams));

        string memory description = "Set zero slashing percentage";

        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        uint256 paramProposalId = governor.propose(targets, values, calldatas, description);

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        governor.castVote(paramProposalId, 1);
        vm.prank(bob);
        governor.castVote(paramProposalId, 1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // Execute should succeed with 0% slashing
        governor.execute(targets, values, calldatas, descriptionHash);

        // Verify slashing percentage is now 0
        (,, uint256 slashingPct,) = governor.optimisticParams();
        assertEq(slashingPct, 0, "Slashing percentage should be 0");

        // Step 2: Create an optimistic proposal that will be disputed
        underlying.mint(address(timelock), 1000e18);

        address[] memory optTargets = new address[](1);
        optTargets[0] = address(underlying);

        uint256[] memory optValues = new uint256[](1);
        optValues[0] = 0;

        bytes[] memory optCalldatas = new bytes[](1);
        optCalldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

        string memory optDescription = "Transfer tokens - will be disputed with zero slashing";

        vm.warp(block.timestamp + 1);

        vm.prank(optimisticProposer);
        uint256 optProposalId = governor.proposeOptimistic(optTargets, optValues, optCalldatas, optDescription);

        OptimisticProposal optProposal = governor.optimisticProposals(optProposalId);
        uint256 vetoThreshold = optProposal.vetoThreshold();

        // Step 3: Alice stakes to veto (triggers dispute)
        vm.startPrank(alice);
        stakingVault.approve(address(optProposal), vetoThreshold);
        optProposal.stakeToVeto(vetoThreshold);
        vm.stopPrank();

        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

        // Step 4: Dispute passes (vetoers were wrong, they get "slashed")
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        governor.castVote(optProposalId, 1);
        vm.prank(bob);
        governor.castVote(optProposalId, 1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        bytes32 optDescriptionHash = keccak256(bytes(optProposal.description()));
        governor.queue(optTargets, optValues, optCalldatas, optDescriptionHash);

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        uint256 aliceStakingBalanceBefore = stakingVault.balanceOf(alice);
        governor.execute(optTargets, optValues, optCalldatas, optDescriptionHash);

        assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Slashed));

        // Step 5: Alice withdraws - should receive full amount back (0% slashing)
        vm.prank(alice);
        optProposal.withdraw();

        // Verify alice got full stake back
        assertEq(stakingVault.balanceOf(alice), aliceStakingBalanceBefore + vetoThreshold, "Should receive full stake with 0% slashing");
    }

    function test_cannotSetSlashingAbove100Percent() public {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        // slashingPercentage = 150%
        IReserveGovernor.OptimisticGovernanceParams memory badParams = IReserveGovernor.OptimisticGovernanceParams({
            vetoPeriod: VETO_PERIOD,
            vetoThreshold: VETO_THRESHOLD,
            slashingPercentage: 1.5e18,
            numParallelProposals: NUM_PARALLEL_PROPOSALS
        });

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(governor.setOptimisticParams, (badParams));

        string memory description = "Set slashing above 100%";

        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(bob);
        governor.castVote(proposalId, 1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.expectRevert(IReserveGovernor.InvalidVetoParameters.selector);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function test_cannotSetParallelProposalsAboveMax() public {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        // numParallelProposals = 10 (> 5 maximum)
        IReserveGovernor.OptimisticGovernanceParams memory badParams = IReserveGovernor.OptimisticGovernanceParams({
            vetoPeriod: VETO_PERIOD,
            vetoThreshold: VETO_THRESHOLD,
            slashingPercentage: SLASHING_PERCENTAGE,
            numParallelProposals: 10
        });

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(governor.setOptimisticParams, (badParams));

        string memory description = "Set parallel proposals above max";

        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(bob);
        governor.castVote(proposalId, 1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.expectRevert(IReserveGovernor.InvalidVetoParameters.selector);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    // ==================== Negative Tests: Empty/Invalid Proposal Tests ====================

    function test_cannotCreateEmptyOptimisticProposal() public {
        address[] memory targets = new address[](0);
        uint256[] memory values = new uint256[](0);
        bytes[] memory calldatas = new bytes[](0);

        string memory description = "Empty proposal";

        vm.prank(optimisticProposer);
        vm.expectRevert("OptimisticProposal: invalid proposal");
        governor.proposeOptimistic(targets, values, calldatas, description);
    }

    function test_cannotCreateMismatchedArraysOptimistic() public {
        address[] memory targets = new address[](2);
        targets[0] = address(underlying);
        targets[1] = address(underlying);

        uint256[] memory values = new uint256[](1); // Mismatched!
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));
        calldatas[1] = abi.encodeCall(IERC20.transfer, (bob, 1000e18));

        string memory description = "Mismatched arrays";

        vm.prank(optimisticProposer);
        vm.expectRevert("OptimisticProposal: invalid proposal");
        governor.proposeOptimistic(targets, values, calldatas, description);
    }
}
