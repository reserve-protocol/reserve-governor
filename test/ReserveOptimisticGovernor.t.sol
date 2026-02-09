// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.28;

// import { Test } from "forge-std/Test.sol";

// import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
// import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// import { IReserveOptimisticGovernorDeployer } from "@interfaces/IDeployer.sol";
// import { IOptimisticSelectorRegistry } from "@interfaces/IOptimisticSelectorRegistry.sol";
// import { IReserveOptimisticGovernor } from "@interfaces/IReserveOptimisticGovernor.sol";
// import { IStakingVault } from "@interfaces/IStakingVault.sol";
// import { ITimelockControllerOptimistic } from "@interfaces/ITimelockControllerOptimistic.sol";

// import { OptimisticProposal } from "@governance/OptimisticProposal.sol";
// import { OptimisticSelectorRegistry } from "@governance/OptimisticSelectorRegistry.sol";
// import { ReserveOptimisticGovernor } from "@governance/ReserveOptimisticGovernor.sol";
// import { TimelockControllerOptimistic } from "@governance/TimelockControllerOptimistic.sol";
// import { ReserveOptimisticGovernorDeployer } from "@src/Deployer.sol";
// import { StakingVault } from "@src/staking/StakingVault.sol";

// import { MockERC20 } from "./mocks/MockERC20.sol";
// import { ReserveOptimisticGovernorV2Mock } from "./mocks/ReserveOptimisticGovernorV2Mock.sol";
// import { TimelockControllerOptimisticV2Mock } from "./mocks/TimelockControllerOptimisticV2Mock.sol";

// contract ReserveOptimisticGovernorTest is Test {
//     // Contracts
//     MockERC20 public underlying;
//     StakingVault public stakingVault;
//     OptimisticSelectorRegistry public registry;
//     ReserveOptimisticGovernorDeployer public deployer;
//     ReserveOptimisticGovernor public governor;
//     TimelockControllerOptimistic public timelock;

//     // Test accounts
//     address public alice = makeAddr("alice");
//     address public bob = makeAddr("bob");
//     address public guardian = makeAddr("guardian");
//     address public optimisticProposer = makeAddr("optimisticProposer");

//     // Test parameters
//     uint32 constant VETO_PERIOD = 2 hours;
//     uint256 constant VETO_THRESHOLD = 0.05e18; // 5%
//     uint256 constant SLASHING_PERCENTAGE = 0.1e18; // 10%
//     uint256 constant NUM_PARALLEL_PROPOSALS = 3;

//     uint48 constant VOTING_DELAY = 1 days;
//     uint32 constant VOTING_PERIOD = 1 weeks;
//     uint48 constant VOTE_EXTENSION = 1 days;
//     uint256 constant PROPOSAL_THRESHOLD = 0.01e18; // 1%
//     uint256 constant QUORUM_NUMERATOR = 0.1e18; // 10%

//     uint256 constant TIMELOCK_DELAY = 2 days;

//     // StakingVault parameters
//     uint256 constant REWARD_HALF_LIFE = 1 days;
//     uint256 constant UNSTAKING_DELAY = 0;

//     // Token amounts
//     uint256 constant INITIAL_SUPPLY = 1_000_000e18;

//     function setUp() public {
//         // Deploy underlying token
//         underlying = new MockERC20("Underlying Token", "UNDL");

//         // Deploy implementations
//         StakingVault stakingVaultImpl = new StakingVault();
//         ReserveOptimisticGovernor governorImpl = new ReserveOptimisticGovernor();
//         TimelockControllerOptimistic timelockImpl = new TimelockControllerOptimistic();
//         OptimisticSelectorRegistry registryImpl = new OptimisticSelectorRegistry();

//         // Deploy Deployer
//         deployer = new ReserveOptimisticGovernorDeployer(
//             address(stakingVaultImpl), address(governorImpl), address(timelockImpl), address(registryImpl)
//         );

//         // Prepare deployment parameters
//         address[] memory optimisticProposers = new address[](1);
//         optimisticProposers[0] = optimisticProposer;

//         address[] memory guardians = new address[](1);
//         guardians[0] = guardian;

//         bytes4[] memory transferSelectors = new bytes4[](1);
//         transferSelectors[0] = IERC20.transfer.selector;

//         OptimisticSelectorRegistry.SelectorData[] memory selectorData = new
// OptimisticSelectorRegistry.SelectorData[](1); selectorData[0] =
// IOptimisticSelectorRegistry.SelectorData(address(underlying), transferSelectors);

//         IReserveOptimisticGovernorDeployer.DeploymentParams memory params =
//             IReserveOptimisticGovernorDeployer.DeploymentParams({
//                 optimisticParams: IReserveOptimisticGovernor.OptimisticGovernanceParams({
//                     vetoPeriod: VETO_PERIOD,
//                     vetoThreshold: VETO_THRESHOLD,
//                     slashingPercentage: SLASHING_PERCENTAGE,
//                     numParallelProposals: NUM_PARALLEL_PROPOSALS
//                 }),
//                 standardParams: IReserveOptimisticGovernor.StandardGovernanceParams({
//                     votingDelay: VOTING_DELAY,
//                     votingPeriod: VOTING_PERIOD,
//                     voteExtension: VOTE_EXTENSION,
//                     proposalThreshold: PROPOSAL_THRESHOLD,
//                     quorumNumerator: QUORUM_NUMERATOR
//                 }),
//                 selectorData: selectorData,
//                 optimisticProposers: optimisticProposers,
//                 guardians: guardians,
//                 timelockDelay: TIMELOCK_DELAY,
//                 underlying: underlying,
//                 rewardTokens: new address[](0),
//                 rewardHalfLife: REWARD_HALF_LIFE,
//                 unstakingDelay: UNSTAKING_DELAY
//             });

//         // Deploy governance system
//         (address stakingVaultAddr, address governorAddr, address timelockAddr, address selectorRegistryAddr) =
//             deployer.deploy(params, bytes32(0));
//         stakingVault = StakingVault(stakingVaultAddr);
//         governor = ReserveOptimisticGovernor(payable(governorAddr));
//         timelock = TimelockControllerOptimistic(payable(timelockAddr));
//         registry = OptimisticSelectorRegistry(selectorRegistryAddr);

//         // Mint tokens to test users and have them deposit into StakingVault
//         _setupVoter(alice, INITIAL_SUPPLY / 2);
//         _setupVoter(bob, INITIAL_SUPPLY / 2);
//     }

//     function _allowSelector(address target, bytes4 selector) internal {
//         bytes4[] memory selectors = new bytes4[](1);
//         selectors[0] = selector;
//         OptimisticSelectorRegistry.SelectorData[] memory selectorData = new
// OptimisticSelectorRegistry.SelectorData[](1); selectorData[0] = IOptimisticSelectorRegistry.SelectorData(target,
// selectors);
//         vm.prank(address(timelock));
//         registry.registerSelectors(selectorData);
//     }

//     function _disallowSelector(address target, bytes4 selector) internal {
//         bytes4[] memory selectors = new bytes4[](1);
//         selectors[0] = selector;
//         OptimisticSelectorRegistry.SelectorData[] memory selectorData = new
// OptimisticSelectorRegistry.SelectorData[](1); selectorData[0] = IOptimisticSelectorRegistry.SelectorData(target,
// selectors);
//         vm.prank(address(timelock));
//         registry.unregisterSelectors(selectorData);
//     }

//     function _setupVoter(address voter, uint256 amount) internal {
//         underlying.mint(voter, amount);

//         vm.startPrank(voter);
//         underlying.approve(address(stakingVault), amount);
//         stakingVault.depositAndDelegate(amount);
//         vm.stopPrank();
//     }

//     function test_slowProposal_standardFlow() public {
//         // Setup: Send some tokens to the timelock for the proposal to transfer
//         uint256 transferAmount = 1000e18;
//         underlying.mint(address(timelock), transferAmount);

//         // Create proposal data: transfer tokens from timelock to alice
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, transferAmount));

//         string memory description = "Transfer tokens to alice";

//         // Warp to ensure we have a snapshot
//         vm.warp(block.timestamp + 1);

//         // Step 1: Propose
//         vm.prank(alice);
//         uint256 proposalId = governor.propose(targets, values, calldatas, description);

//         // Verify proposal is pending
//         assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));

//         // Step 2: Warp past voting delay
//         vm.warp(block.timestamp + VOTING_DELAY + 1);

//         // Verify proposal is active
//         assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Active));

//         // Step 3: Cast votes to meet quorum
//         vm.prank(alice);
//         governor.castVote(proposalId, 1); // Vote for

//         vm.prank(bob);
//         governor.castVote(proposalId, 1); // Vote for

//         // Step 4: Warp past voting period
//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         // Verify proposal succeeded
//         assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));

//         // Step 5: Queue the proposal
//         bytes32 descriptionHash = keccak256(bytes(description));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         // Verify proposal is queued
//         assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Queued));

//         // Step 6: Warp past timelock delay
//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

//         // Step 7: Execute the proposal
//         uint256 aliceBalanceBefore = underlying.balanceOf(alice);
//         governor.execute(targets, values, calldatas, descriptionHash);

//         // Step 8: Assert proposal executed successfully
//         assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed));
//         assertEq(underlying.balanceOf(alice), aliceBalanceBefore + transferAmount);
//     }

//     // ==================== F1: Uncontested Success ====================
//     // Active → Succeeded → Executed

//     function test_fastProposal_F1_uncontestedSuccess() public {
//         // Setup: Send some tokens to the timelock for the proposal to transfer
//         uint256 transferAmount = 1000e18;
//         underlying.mint(address(timelock), transferAmount);

//         // Create proposal data: transfer tokens from timelock to alice
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, transferAmount));

//         string memory description = "Transfer tokens to alice via optimistic";

//         // Warp to ensure we have a snapshot
//         vm.warp(block.timestamp + 1);

//         // Step 1: Propose optimistically
//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         // Verify proposal is optimistic and active
//         assertEq(
//             uint256(governor.proposalType(proposalId)), uint256(IReserveOptimisticGovernor.ProposalType.Optimistic)
//         );
//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Active));

//         // Step 2: Warp past veto period
//         vm.warp(block.timestamp + VETO_PERIOD + 1);

//         // Verify proposal succeeded
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Succeeded));

//         // Step 3: Execute the optimistic proposal
//         uint256 aliceBalanceBefore = underlying.balanceOf(alice);
//         vm.prank(optimisticProposer);
//         governor.executeOptimistic(proposalId);

//         // Step 4: Assert proposal executed successfully
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Executed));
//         assertEq(underlying.balanceOf(alice), aliceBalanceBefore + transferAmount);
//     }

//     // ==================== F2: Early Cancellation ====================
//     // Active → Canceled

//     function test_fastProposal_F2_earlyCancellation_byGuardian() public {
//         // Create proposal
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens - will be canceled";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Active));

//         // Cancel by guardian
//         vm.prank(guardian);
//         optProposal.cancel();

//         // Verify canceled
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Canceled));
//     }

//     function test_fastProposal_F2_earlyCancellation_byProposer() public {
//         // Create proposal
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens - proposer cancels";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

//         // Cancel by optimistic proposer
//         vm.prank(optimisticProposer);
//         optProposal.cancel();

//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Canceled));
//     }

//     // ==================== F3: Confirmation Passes (Slashed) ====================
//     // Active → Locked → Slashed

//     function test_fastProposal_F3_confirmationPasses_slashed() public {
//         // Setup: Send tokens to timelock
//         uint256 transferAmount = 1000e18;
//         underlying.mint(address(timelock), transferAmount);

//         // Create proposal
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, transferAmount));

//         string memory description = "Transfer tokens - will be confirmed";

//         // Warp to ensure we have a snapshot
//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

//         // Calculate veto threshold
//         uint256 vetoThreshold = optProposal.vetoThreshold();

//         // Alice stakes to veto (enough to trigger confirmation)
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), vetoThreshold);
//         optProposal.stakeToVeto(vetoThreshold);
//         vm.stopPrank();

//         // Verify proposal is now locked (confirmation started)
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

//         // Verify confirmation proposal was created with initial AGAINST votes (proposalType should now be Standard)
//         assertEq(uint256(governor.proposalType(proposalId)),
// uint256(IReserveOptimisticGovernor.ProposalType.Standard));

//         // Verify initial AGAINST votes equal vetoThreshold
//         (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(proposalId);
//         assertEq(againstVotes, vetoThreshold, "Initial AGAINST votes should equal vetoThreshold");
//         assertEq(forVotes, 0, "Initial FOR votes should be 0");
//         assertEq(abstainVotes, 0, "Initial ABSTAIN votes should be 0");

//         // Warp past voting delay
//         vm.warp(block.timestamp + VOTING_DELAY + 1);

//         // Cast votes - both alice and bob vote FOR (confirmation passes = vetoers were wrong)
//         vm.prank(alice);
//         governor.castVote(proposalId, 1); // Vote for

//         vm.prank(bob);
//         governor.castVote(proposalId, 1); // Vote for

//         // Verify FOR votes now exceed initial AGAINST votes
//         (againstVotes, forVotes,) = governor.proposalVotes(proposalId);
//         assertEq(againstVotes, vetoThreshold, "AGAINST votes unchanged");
//         assertGt(forVotes, againstVotes, "FOR votes must exceed AGAINST votes to pass");

//         // Warp past voting period
//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         // Verify succeeded
//         assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));

//         // Queue the proposal (use modified description from OptimisticProposal which includes #proposer= suffix)
//         bytes32 descriptionHash = keccak256(bytes(optProposal.description()));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         // Warp past timelock delay
//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

//         // Execute - this should slash stakers
//         uint256 aliceStakingBalanceBefore = stakingVault.balanceOf(alice);
//         governor.execute(targets, values, calldatas, descriptionHash);

//         // Verify slashed state
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Slashed));

//         // Alice withdraws - should receive less due to slashing
//         uint256 aliceStaked = vetoThreshold;
//         uint256 expectedSlash = (aliceStaked * SLASHING_PERCENTAGE) / 1e18;
//         uint256 expectedWithdrawal = aliceStaked - expectedSlash;

//         vm.prank(alice);
//         optProposal.withdraw();

//         // Verify alice got slashed amount back
//         assertEq(stakingVault.balanceOf(alice), aliceStakingBalanceBefore + expectedWithdrawal);
//     }

//     // ==================== F4: Confirmation Fails (Vetoed) ====================
//     // Active → Locked → Vetoed

//     function test_fastProposal_F4_confirmationFails_vetoed() public {
//         // Create proposal
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens - veto succeeds";

//         // Warp to ensure we have a snapshot
//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();

//         // Alice stakes to veto
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), vetoThreshold);
//         optProposal.stakeToVeto(vetoThreshold);
//         vm.stopPrank();

//         // Verify locked
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

//         // Warp past voting delay
//         vm.warp(block.timestamp + VOTING_DELAY + 1);

//         // Cast votes AGAINST (veto succeeds = vetoers were right)
//         vm.prank(alice);
//         governor.castVote(proposalId, 0); // Vote against

//         vm.prank(bob);
//         governor.castVote(proposalId, 0); // Vote against

//         // Warp past voting period
//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         // Verify defeated
//         assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Defeated));

//         // Verify vetoed state
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Vetoed));

//         // Alice withdraws - should receive full amount (no slashing)
//         uint256 aliceStakingBalanceBefore = stakingVault.balanceOf(alice);

//         vm.prank(alice);
//         optProposal.withdraw();

//         // Verify alice got full stake back
//         assertEq(stakingVault.balanceOf(alice), aliceStakingBalanceBefore + vetoThreshold);
//     }

//     // ==================== F5a: Confirmation Canceled ====================
//     // Active → Locked → Canceled

//     function test_fastProposal_F5a_confirmationCanceled() public {
//         // Create proposal
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens - confirmation canceled";

//         // Warp to ensure we have a snapshot
//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();

//         // Alice stakes to veto
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), vetoThreshold);
//         optProposal.stakeToVeto(vetoThreshold);
//         vm.stopPrank();

//         // Verify locked
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

//         // Guardian cancels the slow proposal (confirmation)
//         // Use modified description from OptimisticProposal which includes #proposer= suffix
//         bytes32 descriptionHash = keccak256(bytes(optProposal.description()));
//         vm.prank(guardian);
//         governor.cancel(targets, values, calldatas, descriptionHash);

//         // Verify canceled state
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Canceled));

//         // Alice withdraws - should receive full amount
//         uint256 aliceStakingBalanceBefore = stakingVault.balanceOf(alice);

//         vm.prank(alice);
//         optProposal.withdraw();

//         assertEq(stakingVault.balanceOf(alice), aliceStakingBalanceBefore + vetoThreshold);
//     }

//     // ==================== F5b: Confirmation Vote Expires (No Quorum) ====================
//     // Active → Locked → Vetoed (via vote not reaching quorum)

//     function test_fastProposal_F5b_confirmationNoQuorum() public {
//         // Create proposal
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens - confirmation no quorum";

//         // Warp to ensure we have a snapshot
//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();

//         // Alice stakes to veto
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), vetoThreshold);
//         optProposal.stakeToVeto(vetoThreshold);
//         vm.stopPrank();

//         // Verify locked
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

//         // Warp past voting delay
//         vm.warp(block.timestamp + VOTING_DELAY + 1);

//         // No additional votes cast - confirmation has only initial AGAINST votes from vetoers

//         // Warp past voting period
//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         // Verify defeated (no quorum)
//         assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Defeated));

//         // Verify vetoed state (since confirmation failed due to no quorum)
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Vetoed));

//         // Alice withdraws - should receive full amount (no slashing when veto succeeds)
//         uint256 aliceStakingBalanceBefore = stakingVault.balanceOf(alice);

//         vm.prank(alice);
//         optProposal.withdraw();

//         assertEq(stakingVault.balanceOf(alice), aliceStakingBalanceBefore + vetoThreshold);
//     }

//     // ==================== Additional Edge Cases ====================

//     function test_stakeToVeto_partialStaking() public {
//         // Create proposal
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens - partial staking";

//         // Warp to ensure we have a snapshot with non-zero supply
//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();
//         uint256 partialStake = vetoThreshold / 2;

//         // Alice stakes partial amount
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), partialStake);
//         optProposal.stakeToVeto(partialStake);
//         vm.stopPrank();

//         // Should still be active (not locked yet)
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Active));
//         assertEq(optProposal.totalStaked(), partialStake);

//         // Alice can withdraw during active state
//         uint256 aliceStakingBalanceBefore = stakingVault.balanceOf(alice);

//         vm.prank(alice);
//         optProposal.withdraw();

//         assertEq(stakingVault.balanceOf(alice), aliceStakingBalanceBefore + partialStake);
//     }

//     function test_withdrawDecrementsTotalStaked() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens - withdraw totalStaked regression";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();
//         uint256 partialStake = vetoThreshold / 2;

//         // Alice stakes
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), partialStake);
//         optProposal.stakeToVeto(partialStake);
//         vm.stopPrank();

//         assertEq(optProposal.totalStaked(), partialStake);

//         // Alice withdraws
//         vm.prank(alice);
//         optProposal.withdraw();

//         // Regression: old code did not decrement totalStaked
//         assertEq(optProposal.totalStaked(), 0);
//     }

//     function test_multipleStakersReachThreshold() public {
//         // Create proposal
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens - multiple stakers";

//         // Warp to ensure we have a snapshot
//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();
//         uint256 aliceStake = vetoThreshold / 2;
//         uint256 remaining = vetoThreshold - aliceStake;
//         uint256 bobAttemptedStake = remaining * 2; // Bob tries to overstake by 2x

//         // Alice stakes partial amount
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), aliceStake);
//         optProposal.stakeToVeto(aliceStake);
//         vm.stopPrank();

//         // Still active
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Active));

//         // Bob stakes to reach threshold (attempts 2x more than needed, but capped)
//         uint256 bobBalanceBefore = stakingVault.balanceOf(bob);
//         vm.startPrank(bob);
//         stakingVault.approve(address(optProposal), bobAttemptedStake);
//         optProposal.stakeToVeto(bobAttemptedStake);
//         vm.stopPrank();

//         // Now locked
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

//         // Verify stakes recorded (Bob's stake is capped to remaining threshold)
//         assertEq(optProposal.staked(alice), aliceStake);
//         assertEq(optProposal.staked(bob), remaining);
//         assertEq(optProposal.totalStaked(), vetoThreshold);

//         // Verify Bob only transferred the capped amount
//         assertEq(stakingVault.balanceOf(bob), bobBalanceBefore - remaining);
//     }

//     function test_cannotStakeAfterVetoPeriod() public {
//         // Create proposal
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens - late staking";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

//         // Warp past veto period
//         vm.warp(block.timestamp + VETO_PERIOD + 1);

//         // Verify succeeded
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Succeeded));

//         // Try to stake - should fail
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), 1000e18);
//         vm.expectRevert(abi.encodeWithSelector(OptimisticProposal.OptimisticProposal__NotActive.selector));
//         optProposal.stakeToVeto(1000e18);
//         vm.stopPrank();
//     }

//     function test_cannotWithdrawWhileLocked() public {
//         // Create proposal
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens - withdraw while locked";

//         // Warp to ensure we have a snapshot
//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();

//         // Alice stakes to trigger confirmation
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), vetoThreshold);
//         optProposal.stakeToVeto(vetoThreshold);
//         vm.stopPrank();

//         // Verify locked
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

//         // Try to withdraw - should fail
//         vm.prank(alice);
//         vm.expectRevert(abi.encodeWithSelector(OptimisticProposal.OptimisticProposal__UnderConfirmation.selector));
//         optProposal.withdraw();
//     }

//     // ==================== Negative Tests: #proposer= Suffix Manipulation ====================

//     function test_cannotCreateSlowProposalWithOptimisticDescription() public {
//         // Create an optimistic proposal first
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         // Warp to ensure we have a snapshot
//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

//         // Attacker tries to call propose() with the same description that includes #proposer= suffix
//         // This would allow them to create a slow proposal matching the optimistic one
//         string memory attackerDescription = optProposal.description();

//         // Should revert because alice is not the OptimisticProposal contract
//         vm.prank(alice);
//         vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorRestrictedProposer.selector, alice));
//         governor.propose(targets, values, calldatas, attackerDescription);
//     }

//     function test_proposerSuffixInOriginalDescription() public {
//         // OptimisticProposer includes #proposer= in original description
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         // Description already has a #proposer= suffix
//         string memory description = "Transfer tokens#proposer=0x1234567890123456789012345678901234567890";

//         vm.warp(block.timestamp + 1);

//         // This should succeed - the system will append another #proposer= suffix
//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

//         // Verify the description has double suffix
//         string memory storedDesc = optProposal.description();
//         assertTrue(
//             bytes(storedDesc).length > bytes(description).length, "Description should have additional suffix
// appended" );
//     }

//     // ==================== Negative Tests: Proposal ID Collision ====================

//     function test_canCreateMultipleIdenticalOptimisticProposals() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         vm.warp(block.timestamp + 1);

//         vm.startPrank(optimisticProposer);

//         // Create first proposal
//         uint256 proposalId1 = governor.proposeOptimistic(targets, values, calldatas, description);

//         // Create second with identical params - should succeed with different proposalId
//         uint256 proposalId2 = governor.proposeOptimistic(targets, values, calldatas, description);

//         // Create third with identical params - should also succeed
//         uint256 proposalId3 = governor.proposeOptimistic(targets, values, calldatas, description);

//         vm.stopPrank();

//         // Verify all proposal IDs are unique (due to unique clone addresses in description suffix)
//         assertTrue(proposalId1 != proposalId2, "Proposal IDs 1 and 2 should differ");
//         assertTrue(proposalId2 != proposalId3, "Proposal IDs 2 and 3 should differ");
//         assertTrue(proposalId1 != proposalId3, "Proposal IDs 1 and 3 should differ");

//         // Verify each proposal has a unique OptimisticProposal clone
//         OptimisticProposal optProposal1 = governor.optimisticProposals(proposalId1);
//         OptimisticProposal optProposal2 = governor.optimisticProposals(proposalId2);
//         OptimisticProposal optProposal3 = governor.optimisticProposals(proposalId3);

//         assertTrue(address(optProposal1) != address(optProposal2), "Clone addresses 1 and 2 should differ");
//         assertTrue(address(optProposal2) != address(optProposal3), "Clone addresses 2 and 3 should differ");
//         assertTrue(address(optProposal1) != address(optProposal3), "Clone addresses 1 and 3 should differ");
//     }

//     function test_cannotCreateSlowProposalMatchingOptimistic() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         vm.warp(block.timestamp + 1);

//         // Create optimistic proposal
//         vm.prank(optimisticProposer);
//         uint256 optProposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         // Create slow proposal with same targets/values/calldatas but original description (no suffix)
//         // This should succeed because the proposalIds will be different (different description hash)
//         vm.prank(alice);
//         uint256 slowProposalId = governor.propose(targets, values, calldatas, description);

//         // Verify they're different proposal IDs
//         assertTrue(optProposalId != slowProposalId, "Proposal IDs should be different");
//     }

//     function test_proposalTypeAfterDispute() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         // Initially it's Optimistic
//         assertEq(
//             uint256(governor.proposalType(proposalId)), uint256(IReserveOptimisticGovernor.ProposalType.Optimistic)
//         );

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();

//         // Stake to trigger confirmation
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), vetoThreshold);
//         optProposal.stakeToVeto(vetoThreshold);
//         vm.stopPrank();

//         // After confirmation triggered, it should be Standard
//         assertEq(uint256(governor.proposalType(proposalId)),
// uint256(IReserveOptimisticGovernor.ProposalType.Standard)); }

//     // ==================== Negative Tests: Parallel Proposals Limit ====================

//     function test_cannotExceedParallelProposals() public {
//         vm.warp(block.timestamp + 1);

//         // Create MAX (3) optimistic proposals
//         for (uint256 i = 0; i < NUM_PARALLEL_PROPOSALS; i++) {
//             address[] memory loopTargets = new address[](1);
//             loopTargets[0] = address(underlying);

//             uint256[] memory loopValues = new uint256[](1);
//             loopValues[0] = 0;

//             bytes[] memory loopCalldatas = new bytes[](1);
//             loopCalldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18 + i)); // Different calldata

//             string memory loopDescription = string(abi.encodePacked("Transfer ", vm.toString(i)));

//             vm.prank(optimisticProposer);
//             governor.proposeOptimistic(loopTargets, loopValues, loopCalldatas, loopDescription);
//         }

//         // Try to create one more - should fail
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 2000e18));

//         string memory description = "Transfer overflow";

//         vm.prank(optimisticProposer);
//         vm.expectRevert(IReserveOptimisticGovernor.TooManyParallelOptimisticProposals.selector);
//         governor.proposeOptimistic(targets, values, calldatas, description);
//     }

//     function test_parallelLimitClearsAfterExecution() public {
//         underlying.mint(address(timelock), 10000e18);

//         vm.warp(block.timestamp + 1);

//         uint256[] memory proposalIds = new uint256[](NUM_PARALLEL_PROPOSALS);

//         // Create MAX optimistic proposals
//         for (uint256 i = 0; i < NUM_PARALLEL_PROPOSALS; i++) {
//             address[] memory loopTargets = new address[](1);
//             loopTargets[0] = address(underlying);

//             uint256[] memory loopValues = new uint256[](1);
//             loopValues[0] = 0;

//             bytes[] memory loopCalldatas = new bytes[](1);
//             loopCalldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18 + i));

//             string memory loopDescription = string(abi.encodePacked("Transfer ", vm.toString(i)));

//             vm.prank(optimisticProposer);
//             proposalIds[i] = governor.proposeOptimistic(loopTargets, loopValues, loopCalldatas, loopDescription);
//         }

//         // Execute the first one
//         vm.warp(block.timestamp + VETO_PERIOD + 1);

//         vm.prank(optimisticProposer);
//         governor.executeOptimistic(proposalIds[0]);

//         // Now we should be able to create another
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 5000e18));

//         string memory description = "Transfer after execution";

//         vm.prank(optimisticProposer);
//         uint256 newProposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         assertTrue(newProposalId != 0, "Should have created new proposal");
//     }

//     function test_parallelLimitClearsAfterVeto() public {
//         vm.warp(block.timestamp + 1);

//         uint256[] memory proposalIds = new uint256[](NUM_PARALLEL_PROPOSALS);

//         // Create MAX optimistic proposals
//         for (uint256 i = 0; i < NUM_PARALLEL_PROPOSALS; i++) {
//             address[] memory loopTargets = new address[](1);
//             loopTargets[0] = address(underlying);

//             uint256[] memory loopValues = new uint256[](1);
//             loopValues[0] = 0;

//             bytes[] memory loopCalldatas = new bytes[](1);
//             loopCalldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18 + i));

//             string memory loopDescription = string(abi.encodePacked("Transfer ", vm.toString(i)));

//             vm.prank(optimisticProposer);
//             proposalIds[i] = governor.proposeOptimistic(loopTargets, loopValues, loopCalldatas, loopDescription);
//         }

//         // Veto the first one by staking and then voting against
//         OptimisticProposal optProposal = governor.optimisticProposals(proposalIds[0]);
//         uint256 vetoThreshold = optProposal.vetoThreshold();

//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), vetoThreshold);
//         optProposal.stakeToVeto(vetoThreshold);
//         vm.stopPrank();

//         // Warp past voting delay and vote against
//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(proposalIds[0], 0); // Vote against
//         vm.prank(bob);
//         governor.castVote(proposalIds[0], 0); // Vote against

//         // Warp past voting period
//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         // Verify vetoed
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Vetoed));

//         // Now we should be able to create another
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 5000e18));

//         string memory description = "Transfer after veto";

//         vm.prank(optimisticProposer);
//         uint256 newProposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         assertTrue(newProposalId != 0, "Should have created new proposal");
//     }

//     // ==================== Negative Tests: State Transition Edge Cases ====================

//     function test_cannotExecuteOptimisticWhileLocked() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();

//         // Stake to trigger confirmation (locked state)
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), vetoThreshold);
//         optProposal.stakeToVeto(vetoThreshold);
//         vm.stopPrank();

//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

//         // Try to execute optimistic - should fail
//         vm.prank(optimisticProposer);
//         vm.expectRevert(
//             abi.encodeWithSelector(IReserveOptimisticGovernor.OptimisticProposalNotSuccessful.selector, proposalId)
//         );
//         governor.executeOptimistic(proposalId);
//     }

//     function test_cannotExecuteOptimisticAfterVetoed() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();

//         // Stake to trigger confirmation
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), vetoThreshold);
//         optProposal.stakeToVeto(vetoThreshold);
//         vm.stopPrank();

//         // Vote against (veto succeeds)
//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(proposalId, 0);
//         vm.prank(bob);
//         governor.castVote(proposalId, 0);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Vetoed));

//         // Try to execute optimistic - should fail
//         vm.prank(optimisticProposer);
//         vm.expectRevert(
//             abi.encodeWithSelector(IReserveOptimisticGovernor.OptimisticProposalNotSuccessful.selector, proposalId)
//         );
//         governor.executeOptimistic(proposalId);
//     }

//     function test_cannotExecuteOptimisticAfterSlashed() public {
//         underlying.mint(address(timelock), 10000e18);

//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();

//         // Stake to trigger confirmation
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), vetoThreshold);
//         optProposal.stakeToVeto(vetoThreshold);
//         vm.stopPrank();

//         // Vote FOR (confirmation passes = slash stakers)
//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(proposalId, 1);
//         vm.prank(bob);
//         governor.castVote(proposalId, 1);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         // Queue and execute the slow proposal
//         bytes32 descriptionHash = keccak256(bytes(optProposal.description()));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
//         governor.execute(targets, values, calldatas, descriptionHash);

//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Slashed));

//         // Try to execute optimistic - should fail
//         vm.prank(optimisticProposer);
//         vm.expectRevert(
//             abi.encodeWithSelector(IReserveOptimisticGovernor.OptimisticProposalNotSuccessful.selector, proposalId)
//         );
//         governor.executeOptimistic(proposalId);
//     }

//     function test_governorStateRevertsForUnConfirmedOptimistic() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         // Calling state() on an active (unconfirmed) optimistic proposal should revert
//         // because there's no slow proposal yet
//         vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorNonexistentProposal.selector, proposalId));
//         governor.state(proposalId);
//     }

//     // ==================== Negative Tests: Staking Edge Cases ====================

//     function test_cannotStakeZero() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

//         vm.prank(alice);
//         vm.expectRevert(abi.encodeWithSelector(OptimisticProposal.OptimisticProposal__ZeroStake.selector));
//         optProposal.stakeToVeto(0);
//     }

//     function test_cannotStakeWhenSucceeded() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

//         // Warp past veto period
//         vm.warp(block.timestamp + VETO_PERIOD + 1);

//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Succeeded));

//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), 1000e18);
//         vm.expectRevert(abi.encodeWithSelector(OptimisticProposal.OptimisticProposal__NotActive.selector));
//         optProposal.stakeToVeto(1000e18);
//         vm.stopPrank();
//     }

//     function test_cannotStakeWhenLocked() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();

//         // Alice stakes to trigger lock
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), vetoThreshold);
//         optProposal.stakeToVeto(vetoThreshold);
//         vm.stopPrank();

//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

//         // Bob tries to stake while locked
//         vm.startPrank(bob);
//         stakingVault.approve(address(optProposal), 1000e18);
//         vm.expectRevert(abi.encodeWithSelector(OptimisticProposal.OptimisticProposal__NotActive.selector));
//         optProposal.stakeToVeto(1000e18);
//         vm.stopPrank();
//     }

//     function test_withdrawRoundsDownWithSlashing() public {
//         underlying.mint(address(timelock), 10000e18);

//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();

//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), vetoThreshold);
//         optProposal.stakeToVeto(vetoThreshold);
//         vm.stopPrank();

//         // Vote FOR to slash
//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(proposalId, 1);
//         vm.prank(bob);
//         governor.castVote(proposalId, 1);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         bytes32 descriptionHash = keccak256(bytes(optProposal.description()));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
//         governor.execute(targets, values, calldatas, descriptionHash);

//         // Calculate expected withdrawal
//         uint256 staked = vetoThreshold;
//         uint256 expectedWithdrawal = (staked * (1e18 - SLASHING_PERCENTAGE)) / 1e18;

//         uint256 balanceBefore = stakingVault.balanceOf(alice);

//         vm.prank(alice);
//         optProposal.withdraw();

//         // Verify withdrawal math is correct
//         assertEq(stakingVault.balanceOf(alice), balanceBefore + expectedWithdrawal);
//     }

//     function test_multipleStakersThresholdOnce() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();

//         // Alice stakes just under threshold
//         uint256 aliceStake = vetoThreshold - 1;
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), aliceStake);
//         optProposal.stakeToVeto(aliceStake);
//         vm.stopPrank();

//         // Still active
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Active));

//         // Bob tries to stake 2 when only 1 is needed (overstake is capped)
//         uint256 bobBalanceBefore = stakingVault.balanceOf(bob);
//         vm.startPrank(bob);
//         stakingVault.approve(address(optProposal), 2);
//         optProposal.stakeToVeto(2);
//         vm.stopPrank();

//         // Now locked - confirmation should have been created exactly once
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));
//         assertEq(uint256(governor.proposalType(proposalId)),
// uint256(IReserveOptimisticGovernor.ProposalType.Standard));

//         // Verify Bob's stake was capped to 1 (only what was needed)
//         assertEq(optProposal.staked(bob), 1);
//         assertEq(optProposal.totalStaked(), vetoThreshold);
//         assertEq(stakingVault.balanceOf(bob), bobBalanceBefore - 1);
//     }

//     // ==================== Negative Tests: Cancel Flow ====================

//     function test_cannotCancelOptimisticWhenLocked() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();

//         // Stake to trigger lock
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), vetoThreshold);
//         optProposal.stakeToVeto(vetoThreshold);
//         vm.stopPrank();

//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

//         // OptimisticProposer tries to cancel the OptimisticProposal (not the slow proposal)
//         vm.prank(optimisticProposer);
//         vm.expectRevert(abi.encodeWithSelector(OptimisticProposal.OptimisticProposal__CannotCancel.selector));
//         optProposal.cancel();
//     }

//     function test_guardianCanCancelDispute() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();

//         // Stake to trigger confirmation
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), vetoThreshold);
//         optProposal.stakeToVeto(vetoThreshold);
//         vm.stopPrank();

//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

//         // Guardian cancels the confirmation proposal via governor
//         bytes32 descriptionHash = keccak256(bytes(optProposal.description()));

//         vm.prank(guardian);
//         governor.cancel(targets, values, calldatas, descriptionHash);

//         // OptimisticProposal should be Canceled
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Canceled));
//     }

//     function test_optimisticProposerCanCancelDispute() public {
//         // Verify optimisticProposer is NOT the guardian
//         assertTrue(optimisticProposer != guardian, "optimisticProposer must not be guardian for this test");

//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens - proposer cancels confirmation";

//         vm.warp(block.timestamp + 1);

//         // optimisticProposer creates the optimistic proposal
//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();

//         // Alice stakes to trigger confirmation
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), vetoThreshold);
//         optProposal.stakeToVeto(vetoThreshold);
//         vm.stopPrank();

//         // Verify proposal is now in Locked (confirmation) state
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

//         // The original optimisticProposer cancels the confirmation proposal via governor
//         // This works because proposeConfirmation() sets the proposer as the initialProposer
//         bytes32 descriptionHash = keccak256(bytes(optProposal.description()));

//         vm.prank(optimisticProposer);
//         governor.cancel(targets, values, calldatas, descriptionHash);

//         // OptimisticProposal should be Canceled
//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Canceled));

//         // Verify stakers can withdraw their full stake
//         uint256 aliceStakingBalanceBefore = stakingVault.balanceOf(alice);
//         vm.prank(alice);
//         optProposal.withdraw();
//         assertEq(stakingVault.balanceOf(alice), aliceStakingBalanceBefore + vetoThreshold);
//     }

//     function test_randomUserCannotCancelOptimistic() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

//         // Random user tries to cancel
//         address randomUser = makeAddr("randomUser");
//         vm.prank(randomUser);
//         vm.expectRevert(abi.encodeWithSelector(OptimisticProposal.OptimisticProposal__CannotCancel.selector));
//         optProposal.cancel();
//     }

//     function test_optimisticProposerCanCancelActive() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         OptimisticProposal optProposal = governor.optimisticProposals(proposalId);

//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Active));

//         // OptimisticProposer can cancel during Active state
//         vm.prank(optimisticProposer);
//         optProposal.cancel();

//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Canceled));
//     }

//     // ==================== Negative Tests: Permission Tests ====================

//     function test_cannotProposeOptimisticWithoutRole() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         // Alice (not optimistic proposer) tries to propose optimistically
//         vm.prank(alice);
//         vm.expectRevert(abi.encodeWithSelector(IReserveOptimisticGovernor.NotOptimisticProposer.selector, alice));
//         governor.proposeOptimistic(targets, values, calldatas, description);
//     }

//     function test_cannotExecuteOptimisticWithoutRole() public {
//         underlying.mint(address(timelock), 10000e18);

//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory description = "Transfer tokens";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         // Warp past veto period
//         vm.warp(block.timestamp + VETO_PERIOD + 1);

//         // Alice (not optimistic proposer) tries to execute
//         vm.prank(alice);
//         vm.expectRevert(abi.encodeWithSelector(IReserveOptimisticGovernor.NotOptimisticProposer.selector, alice));
//         governor.executeOptimistic(proposalId);
//     }

//     // ==================== Negative Tests: EOA Protection ====================

//     function test_cannotProposeCalldataToEOA_standard() public {
//         address eoaTarget = makeAddr("eoaTarget");

//         address[] memory targets = new address[](1);
//         targets[0] = eoaTarget;

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeWithSelector(bytes4(keccak256("someFunction(uint256)")), 123);

//         string memory description = "Call EOA with calldata - should fail";

//         vm.warp(block.timestamp + 1);

//         vm.prank(alice);
//         vm.expectRevert(abi.encodeWithSelector(IReserveOptimisticGovernor.InvalidFunctionCallToEOA.selector,
// eoaTarget)); governor.propose(targets, values, calldatas, description);
//     }

//     function test_cannotProposeCalldataToEOA_optimistic() public {
//         address eoaTarget = makeAddr("eoaTarget");
//         bytes4 selector = bytes4(keccak256("someFunction(uint256)"));

//         // Register selector for EOA (registry doesn't validate target is a contract)
//         _allowSelector(eoaTarget, selector);

//         address[] memory targets = new address[](1);
//         targets[0] = eoaTarget;

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeWithSelector(selector, 123);

//         string memory description = "Call EOA with calldata - should fail";

//         vm.prank(optimisticProposer);
//         vm.expectRevert(abi.encodeWithSelector(IReserveOptimisticGovernor.InvalidFunctionCallToEOA.selector,
// eoaTarget)); governor.proposeOptimistic(targets, values, calldatas, description);
//     }

//     function test_cannotProposeShortCalldataToEOA_optimistic() public {
//         address target = makeAddr("eoatarget");

//         address[] memory targets = new address[](1);
//         targets[0] = target;

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         // 3 bytes: too short for a selector but not empty
//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = hex"abcdef";

//         string memory description = "Short calldata - should fail";

//         vm.prank(optimisticProposer);
//         vm.expectRevert(abi.encodeWithSelector(IReserveOptimisticGovernor.InvalidFunctionCallToEOA.selector,
// target)); governor.proposeOptimistic(targets, values, calldatas, description);
//     }

//     function test_canSendETHToEOAWithEmptyCalldata_standard() public {
//         address eoaTarget = makeAddr("eoaTarget");
//         vm.deal(address(timelock), 1 ether);

//         address[] memory targets = new address[](1);
//         targets[0] = eoaTarget;

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0.1 ether;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = "";

//         string memory description = "Send ETH to EOA - should succeed";

//         vm.warp(block.timestamp + 1);

//         vm.prank(alice);
//         uint256 proposalId = governor.propose(targets, values, calldatas, description);

//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(proposalId, 1);
//         vm.prank(bob);
//         governor.castVote(proposalId, 1);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         bytes32 descriptionHash = keccak256(bytes(description));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

//         uint256 eoaBalanceBefore = eoaTarget.balance;
//         governor.execute(targets, values, calldatas, descriptionHash);

//         assertEq(eoaTarget.balance, eoaBalanceBefore + 0.1 ether);
//     }

//     function test_canSendETHToEOAWithEmptyCalldata_optimistic() public {
//         address eoaTarget = makeAddr("eoaTarget");
//         vm.deal(address(timelock), 1 ether);

//         // Register empty selector for EOA (empty calldata extracts as bytes4(0))
//         _allowSelector(eoaTarget, bytes4(0));

//         address[] memory targets = new address[](1);
//         targets[0] = eoaTarget;

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0.1 ether;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = "";

//         string memory description = "Send ETH to EOA via optimistic - should succeed";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 proposalId = governor.proposeOptimistic(targets, values, calldatas, description);

//         vm.warp(block.timestamp + VETO_PERIOD + 1);

//         uint256 eoaBalanceBefore = eoaTarget.balance;
//         vm.prank(optimisticProposer);
//         governor.executeOptimistic(proposalId);

//         assertEq(eoaTarget.balance, eoaBalanceBefore + 0.1 ether);
//     }

//     // ==================== Negative Tests: Parameter Validation ====================

//     function test_cannotSetVetoPeriodBelowMin() public {
//         // Setup a governance proposal to change params
//         address[] memory targets = new address[](1);
//         targets[0] = address(governor);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         // vetoPeriod = 1 minute (< 30 minutes minimum)
//         IReserveOptimisticGovernor.OptimisticGovernanceParams memory badParams =
//             IReserveOptimisticGovernor.OptimisticGovernanceParams({
//                 vetoPeriod: 1 minutes,
//                 vetoThreshold: VETO_THRESHOLD,
//                 slashingPercentage: SLASHING_PERCENTAGE,
//                 numParallelProposals: NUM_PARALLEL_PROPOSALS
//             });

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(governor.setOptimisticParams, (badParams));

//         string memory description = "Set bad veto period";

//         vm.warp(block.timestamp + 1);

//         // Create and pass the proposal
//         vm.prank(alice);
//         uint256 proposalId = governor.propose(targets, values, calldatas, description);

//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(proposalId, 1);
//         vm.prank(bob);
//         governor.castVote(proposalId, 1);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         bytes32 descriptionHash = keccak256(bytes(description));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

//         // Execution should revert
//         vm.expectRevert(IReserveOptimisticGovernor.InvalidVetoParameters.selector);
//         governor.execute(targets, values, calldatas, descriptionHash);
//     }

//     function test_cannotSetProposalThresholdAbove100Percent() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(governor);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         // proposalThreshold = 1e18 + 1 (> 100%)
//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(governor.setProposalThreshold, (1e18 + 1));

//         string memory description = "Set proposal threshold above 100%";

//         vm.warp(block.timestamp + 1);

//         vm.prank(alice);
//         uint256 proposalId = governor.propose(targets, values, calldatas, description);

//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(proposalId, 1);
//         vm.prank(bob);
//         governor.castVote(proposalId, 1);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         bytes32 descriptionHash = keccak256(bytes(description));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

//         vm.expectRevert(IReserveOptimisticGovernor.InvalidProposalThreshold.selector);
//         governor.execute(targets, values, calldatas, descriptionHash);
//     }

//     function test_cannotExceedParallelLockedVotesFraction() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(governor);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         // product = 34% * 2 = 68% (> ~66.67% MAX_PARALLEL_LOCKED_VOTES_FRACTION)
//         IReserveOptimisticGovernor.OptimisticGovernanceParams memory badParams =
//             IReserveOptimisticGovernor.OptimisticGovernanceParams({
//                 vetoPeriod: VETO_PERIOD,
//                 vetoThreshold: 0.34e18,
//                 slashingPercentage: SLASHING_PERCENTAGE,
//                 numParallelProposals: 2
//             });

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(governor.setOptimisticParams, (badParams));

//         string memory description = "Set params exceeding parallel locked votes fraction";

//         vm.warp(block.timestamp + 1);

//         vm.prank(alice);
//         uint256 proposalId = governor.propose(targets, values, calldatas, description);

//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(proposalId, 1);
//         vm.prank(bob);
//         governor.castVote(proposalId, 1);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         bytes32 descriptionHash = keccak256(bytes(description));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

//         vm.expectRevert(IReserveOptimisticGovernor.InvalidVetoParameters.selector);
//         governor.execute(targets, values, calldatas, descriptionHash);
//     }

//     function test_cannotSetVetoThresholdZero() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(governor);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         // vetoThreshold = 0
//         IReserveOptimisticGovernor.OptimisticGovernanceParams memory badParams =
//             IReserveOptimisticGovernor.OptimisticGovernanceParams({
//                 vetoPeriod: VETO_PERIOD,
//                 vetoThreshold: 0,
//                 slashingPercentage: SLASHING_PERCENTAGE,
//                 numParallelProposals: NUM_PARALLEL_PROPOSALS
//             });

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(governor.setOptimisticParams, (badParams));

//         string memory description = "Set zero veto threshold";

//         vm.warp(block.timestamp + 1);

//         vm.prank(alice);
//         uint256 proposalId = governor.propose(targets, values, calldatas, description);

//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(proposalId, 1);
//         vm.prank(bob);
//         governor.castVote(proposalId, 1);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         bytes32 descriptionHash = keccak256(bytes(description));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

//         vm.expectRevert(IReserveOptimisticGovernor.InvalidVetoParameters.selector);
//         governor.execute(targets, values, calldatas, descriptionHash);
//     }

//     function test_zeroSlashingPercentageAllowed() public {
//         // Step 1: Set slashing percentage to 0 via slow proposal
//         address[] memory targets = new address[](1);
//         targets[0] = address(governor);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         IReserveOptimisticGovernor.OptimisticGovernanceParams memory zeroSlashParams =
//             IReserveOptimisticGovernor.OptimisticGovernanceParams({
//                 vetoPeriod: VETO_PERIOD,
//                 vetoThreshold: VETO_THRESHOLD,
//                 slashingPercentage: 0,
//                 numParallelProposals: NUM_PARALLEL_PROPOSALS
//             });

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(governor.setOptimisticParams, (zeroSlashParams));

//         string memory description = "Set zero slashing percentage";

//         vm.warp(block.timestamp + 1);

//         vm.prank(alice);
//         uint256 paramProposalId = governor.propose(targets, values, calldatas, description);

//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(paramProposalId, 1);
//         vm.prank(bob);
//         governor.castVote(paramProposalId, 1);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         bytes32 descriptionHash = keccak256(bytes(description));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

//         // Execute should succeed with 0% slashing
//         governor.execute(targets, values, calldatas, descriptionHash);

//         // Verify slashing percentage is now 0
//         (,, uint256 slashingPct,) = governor.optimisticParams();
//         assertEq(slashingPct, 0, "Slashing percentage should be 0");

//         // Step 2: Create an optimistic proposal that will be confirmed
//         underlying.mint(address(timelock), 1000e18);

//         address[] memory optTargets = new address[](1);
//         optTargets[0] = address(underlying);

//         uint256[] memory optValues = new uint256[](1);
//         optValues[0] = 0;

//         bytes[] memory optCalldatas = new bytes[](1);
//         optCalldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));

//         string memory optDescription = "Transfer tokens - will be confirmed with zero slashing";

//         vm.warp(block.timestamp + 1);

//         vm.prank(optimisticProposer);
//         uint256 optProposalId = governor.proposeOptimistic(optTargets, optValues, optCalldatas, optDescription);

//         OptimisticProposal optProposal = governor.optimisticProposals(optProposalId);
//         uint256 vetoThreshold = optProposal.vetoThreshold();

//         // Step 3: Alice stakes to veto (triggers confirmation)
//         vm.startPrank(alice);
//         stakingVault.approve(address(optProposal), vetoThreshold);
//         optProposal.stakeToVeto(vetoThreshold);
//         vm.stopPrank();

//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Locked));

//         // Step 4: Confirmation passes (vetoers were wrong, they get "slashed")
//         vm.warp(block.timestamp + VOTING_DELAY + 1);

//         vm.prank(alice);
//         governor.castVote(optProposalId, 1);
//         vm.prank(bob);
//         governor.castVote(optProposalId, 1);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         bytes32 optDescriptionHash = keccak256(bytes(optProposal.description()));
//         governor.queue(optTargets, optValues, optCalldatas, optDescriptionHash);

//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

//         uint256 aliceStakingBalanceBefore = stakingVault.balanceOf(alice);
//         governor.execute(optTargets, optValues, optCalldatas, optDescriptionHash);

//         assertEq(uint256(optProposal.state()), uint256(OptimisticProposal.OptimisticProposalState.Slashed));

//         // Step 5: Alice withdraws - should receive full amount back (0% slashing)
//         vm.prank(alice);
//         optProposal.withdraw();

//         // Verify alice got full stake back
//         assertEq(
//             stakingVault.balanceOf(alice),
//             aliceStakingBalanceBefore + vetoThreshold,
//             "Should receive full stake with 0% slashing"
//         );
//     }

//     function test_cannotSetSlashingAbove100Percent() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(governor);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         // slashingPercentage = 150%
//         IReserveOptimisticGovernor.OptimisticGovernanceParams memory badParams =
//             IReserveOptimisticGovernor.OptimisticGovernanceParams({
//                 vetoPeriod: VETO_PERIOD,
//                 vetoThreshold: VETO_THRESHOLD,
//                 slashingPercentage: 1.5e18,
//                 numParallelProposals: NUM_PARALLEL_PROPOSALS
//             });

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(governor.setOptimisticParams, (badParams));

//         string memory description = "Set slashing above 100%";

//         vm.warp(block.timestamp + 1);

//         vm.prank(alice);
//         uint256 proposalId = governor.propose(targets, values, calldatas, description);

//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(proposalId, 1);
//         vm.prank(bob);
//         governor.castVote(proposalId, 1);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         bytes32 descriptionHash = keccak256(bytes(description));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

//         vm.expectRevert(IReserveOptimisticGovernor.InvalidVetoParameters.selector);
//         governor.execute(targets, values, calldatas, descriptionHash);
//     }

//     function test_highVetoThresholdAllowedWithLowParallelProposals() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(governor);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         // product = 60% * 1 = 60% (<= ~66.67% MAX_PARALLEL_LOCKED_VOTES_FRACTION)
//         IReserveOptimisticGovernor.OptimisticGovernanceParams memory params =
//             IReserveOptimisticGovernor.OptimisticGovernanceParams({
//                 vetoPeriod: VETO_PERIOD,
//                 vetoThreshold: 0.6e18,
//                 slashingPercentage: SLASHING_PERCENTAGE,
//                 numParallelProposals: 1
//             });

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(governor.setOptimisticParams, (params));

//         string memory description = "Set high veto threshold with single parallel proposal";

//         vm.warp(block.timestamp + 1);

//         vm.prank(alice);
//         uint256 proposalId = governor.propose(targets, values, calldatas, description);

//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(proposalId, 1);
//         vm.prank(bob);
//         governor.castVote(proposalId, 1);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         bytes32 descriptionHash = keccak256(bytes(description));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

//         governor.execute(targets, values, calldatas, descriptionHash);

//         (, uint256 vt,, uint256 npp) = governor.optimisticParams();
//         assertEq(vt, 0.6e18);
//         assertEq(npp, 1);
//     }

//     function test_highParallelProposalsAllowedWithLowVetoThreshold() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(governor);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         // product = 6.5% * 10 = 65% (<= ~66.67% MAX_PARALLEL_LOCKED_VOTES_FRACTION)
//         IReserveOptimisticGovernor.OptimisticGovernanceParams memory params =
//             IReserveOptimisticGovernor.OptimisticGovernanceParams({
//                 vetoPeriod: VETO_PERIOD,
//                 vetoThreshold: 0.065e18,
//                 slashingPercentage: SLASHING_PERCENTAGE,
//                 numParallelProposals: 10
//             });

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(governor.setOptimisticParams, (params));

//         string memory description = "Set many parallel proposals with low veto threshold";

//         vm.warp(block.timestamp + 1);

//         vm.prank(alice);
//         uint256 proposalId = governor.propose(targets, values, calldatas, description);

//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(proposalId, 1);
//         vm.prank(bob);
//         governor.castVote(proposalId, 1);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         bytes32 descriptionHash = keccak256(bytes(description));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

//         governor.execute(targets, values, calldatas, descriptionHash);

//         (, uint256 vt,, uint256 npp) = governor.optimisticParams();
//         assertEq(vt, 0.065e18);
//         assertEq(npp, 10);
//     }

//     function test_parallelLockedVotesFractionBoundary() public {
//         // === Pass case: product exactly at the boundary ===
//         address[] memory targets = new address[](1);
//         targets[0] = address(governor);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         // product = 33.33..% * 2 = 66.66..% (== MAX_PARALLEL_LOCKED_VOTES_FRACTION)
//         IReserveOptimisticGovernor.OptimisticGovernanceParams memory params =
//             IReserveOptimisticGovernor.OptimisticGovernanceParams({
//                 vetoPeriod: VETO_PERIOD,
//                 vetoThreshold: 0.333333333333333333e18,
//                 slashingPercentage: SLASHING_PERCENTAGE,
//                 numParallelProposals: 2
//             });

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(governor.setOptimisticParams, (params));

//         string memory description = "Set params at exact product boundary";

//         vm.warp(block.timestamp + 1);

//         vm.prank(alice);
//         uint256 proposalId = governor.propose(targets, values, calldatas, description);

//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(proposalId, 1);
//         vm.prank(bob);
//         governor.castVote(proposalId, 1);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         bytes32 descriptionHash = keccak256(bytes(description));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

//         governor.execute(targets, values, calldatas, descriptionHash);

//         (, uint256 vt,, uint256 npp) = governor.optimisticParams();
//         assertEq(vt, 0.333333333333333333e18);
//         assertEq(npp, 2);

//         // === Fail case: product one wei above the boundary ===

//         // product = 33.33..34% * 2 = 66.66..68% (> MAX_PARALLEL_LOCKED_VOTES_FRACTION)
//         IReserveOptimisticGovernor.OptimisticGovernanceParams memory badParams =
//             IReserveOptimisticGovernor.OptimisticGovernanceParams({
//                 vetoPeriod: VETO_PERIOD,
//                 vetoThreshold: 0.333333333333333334e18,
//                 slashingPercentage: SLASHING_PERCENTAGE,
//                 numParallelProposals: 2
//             });

//         calldatas[0] = abi.encodeCall(governor.setOptimisticParams, (badParams));

//         string memory description2 = "Set params one wei above product boundary";

//         vm.warp(block.timestamp + 1);

//         vm.prank(alice);
//         proposalId = governor.propose(targets, values, calldatas, description2);

//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(proposalId, 1);
//         vm.prank(bob);
//         governor.castVote(proposalId, 1);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         descriptionHash = keccak256(bytes(description2));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

//         vm.expectRevert(IReserveOptimisticGovernor.InvalidVetoParameters.selector);
//         governor.execute(targets, values, calldatas, descriptionHash);
//     }

//     function test_cannotExceedMaxParallelOptimisticProposals() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(governor);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         // numParallelProposals = 11 (> 10 MAX_PARALLEL_OPTIMISTIC_PROPOSALS)
//         // product = 1% * 11 = 11% (<= 66%), so only the hard cap is violated
//         IReserveOptimisticGovernor.OptimisticGovernanceParams memory badParams =
//             IReserveOptimisticGovernor.OptimisticGovernanceParams({
//                 vetoPeriod: VETO_PERIOD,
//                 vetoThreshold: 0.01e18,
//                 slashingPercentage: SLASHING_PERCENTAGE,
//                 numParallelProposals: 11
//             });

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(governor.setOptimisticParams, (badParams));

//         string memory description = "Set parallel proposals above hard cap";

//         vm.warp(block.timestamp + 1);

//         vm.prank(alice);
//         uint256 proposalId = governor.propose(targets, values, calldatas, description);

//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(proposalId, 1);
//         vm.prank(bob);
//         governor.castVote(proposalId, 1);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         bytes32 descriptionHash = keccak256(bytes(description));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

//         vm.expectRevert(IReserveOptimisticGovernor.InvalidVetoParameters.selector);
//         governor.execute(targets, values, calldatas, descriptionHash);
//     }

//     // ==================== Negative Tests: Empty/Invalid Proposal Tests ====================

//     function test_cannotCreateEmptyOptimisticProposal() public {
//         address[] memory targets = new address[](0);
//         uint256[] memory values = new uint256[](0);
//         bytes[] memory calldatas = new bytes[](0);

//         string memory description = "Empty proposal";

//         vm.prank(optimisticProposer);
//         vm.expectRevert(IReserveOptimisticGovernor.InvalidProposalLengths.selector);
//         governor.proposeOptimistic(targets, values, calldatas, description);
//     }

//     function test_cannotCreateMismatchedArraysOptimistic() public {
//         address[] memory targets = new address[](2);
//         targets[0] = address(underlying);
//         targets[1] = address(underlying);

//         uint256[] memory values = new uint256[](1); // Mismatched!
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](2);
//         calldatas[0] = abi.encodeCall(IERC20.transfer, (alice, 1000e18));
//         calldatas[1] = abi.encodeCall(IERC20.transfer, (bob, 1000e18));

//         string memory description = "Mismatched arrays";

//         vm.prank(optimisticProposer);
//         vm.expectRevert(IReserveOptimisticGovernor.InvalidProposalLengths.selector);
//         governor.proposeOptimistic(targets, values, calldatas, description);
//     }

//     // ==================== Negative Tests: Registry Tests ====================

//     function test_registry_cannotAddSelfAsTarget() public {
//         bytes4[] memory selectors = new bytes4[](1);
//         selectors[0] = IERC20.transfer.selector;

//         OptimisticSelectorRegistry.SelectorData[] memory selectorData = new
// OptimisticSelectorRegistry.SelectorData[](1);

//         // 1. Cannot target the registry itself
//         selectorData[0] = IOptimisticSelectorRegistry.SelectorData(address(registry), selectors);
//         vm.prank(address(timelock));
//         vm.expectRevert(
//             abi.encodeWithSelector(IOptimisticSelectorRegistry.InvalidCall.selector, address(registry), selectors[0])
//         );
//         registry.registerSelectors(selectorData);

//         // 2. Cannot target the governor
//         selectorData[0] = IOptimisticSelectorRegistry.SelectorData(address(governor), selectors);
//         vm.prank(address(timelock));
//         vm.expectRevert(
//             abi.encodeWithSelector(IOptimisticSelectorRegistry.InvalidCall.selector, address(governor), selectors[0])
//         );
//         registry.registerSelectors(selectorData);

//         // 3. Cannot target the timelock
//         selectorData[0] = IOptimisticSelectorRegistry.SelectorData(address(timelock), selectors);
//         vm.prank(address(timelock));
//         vm.expectRevert(
//             abi.encodeWithSelector(IOptimisticSelectorRegistry.InvalidCall.selector, address(timelock), selectors[0])
//         );
//         registry.registerSelectors(selectorData);

//         // 4. Cannot target the staking vault
//         selectorData[0] = IOptimisticSelectorRegistry.SelectorData(address(stakingVault), selectors);
//         vm.prank(address(timelock));
//         vm.expectRevert(
//             abi.encodeWithSelector(
//                 IOptimisticSelectorRegistry.InvalidCall.selector, address(stakingVault), selectors[0]
//             )
//         );
//         registry.registerSelectors(selectorData);

//         // 4. Cannot target the staking vault even if using addRewardToken()
//         selectors[0] = StakingVault.addRewardToken.selector;
//         selectorData[0] = IOptimisticSelectorRegistry.SelectorData(address(stakingVault), selectors);
//         vm.prank(address(timelock));
//         vm.expectRevert(
//             abi.encodeWithSelector(
//                 IOptimisticSelectorRegistry.InvalidCall.selector, address(stakingVault), selectors[0]
//             )
//         );
//         registry.registerSelectors(selectorData);
//     }

//     function test_registry_onlyTimelockCanRegister() public {
//         bytes4[] memory selectors = new bytes4[](1);
//         selectors[0] = IERC20.approve.selector;
//         OptimisticSelectorRegistry.SelectorData[] memory selectorData = new
// OptimisticSelectorRegistry.SelectorData[](1); selectorData[0] =
// IOptimisticSelectorRegistry.SelectorData(address(underlying), selectors);

//         vm.prank(alice);
//         vm.expectRevert(abi.encodeWithSelector(IOptimisticSelectorRegistry.OnlyOwner.selector, alice));
//         registry.registerSelectors(selectorData);
//     }

//     function test_registry_onlyTimelockCanUnregister() public {
//         bytes4[] memory selectors = new bytes4[](1);
//         selectors[0] = IERC20.transfer.selector;
//         OptimisticSelectorRegistry.SelectorData[] memory selectorData = new
// OptimisticSelectorRegistry.SelectorData[](1); selectorData[0] =
// IOptimisticSelectorRegistry.SelectorData(address(underlying), selectors);

//         vm.prank(alice);
//         vm.expectRevert(abi.encodeWithSelector(IOptimisticSelectorRegistry.OnlyOwner.selector, alice));
//         registry.unregisterSelectors(selectorData);
//     }

//     function test_registry_isAllowed() public view {
//         assertTrue(registry.isAllowed(address(underlying), IERC20.transfer.selector));
//         assertFalse(registry.isAllowed(address(underlying), IERC20.approve.selector));
//     }

//     function test_registry_selectorsAllowed() public view {
//         bytes4[] memory selectors = registry.selectorsAllowed(address(underlying));
//         assertEq(selectors.length, 1);
//         assertEq(selectors[0], IERC20.transfer.selector);
//     }

//     function test_registry_targets() public view {
//         address[] memory t = registry.targets();
//         assertEq(t.length, 1);
//         assertEq(t[0], address(underlying));
//     }

//     function test_registry_registerAndUnregister() public {
//         _allowSelector(address(underlying), IERC20.approve.selector);
//         assertTrue(registry.isAllowed(address(underlying), IERC20.approve.selector));

//         _disallowSelector(address(underlying), IERC20.approve.selector);
//         assertFalse(registry.isAllowed(address(underlying), IERC20.approve.selector));
//     }

//     function test_registry_unregisterRemovesTarget() public {
//         _disallowSelector(address(underlying), IERC20.transfer.selector);
//         assertEq(registry.targets().length, 0);
//     }

//     function test_registry_optimisticProposalRevertsWithDisallowedSelector() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(underlying);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(IERC20.approve, (alice, 1000e18));

//         string memory description = "Approve tokens - not allowed";

//         vm.prank(optimisticProposer);
//         vm.expectRevert(
//             abi.encodeWithSelector(
//                 IReserveOptimisticGovernor.InvalidFunctionCall.selector, address(underlying), IERC20.approve.selector
//             )
//         );
//         governor.proposeOptimistic(targets, values, calldatas, description);
//     }

//     function test_registry_cannotTargetGovernorOptimistically() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(governor);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(
//             governor.setOptimisticParams,
//             (IReserveOptimisticGovernor.OptimisticGovernanceParams(1 hours, 0.1e18, 0.1e18, 2))
//         );

//         string memory description = "Try governor via optimistic";

//         vm.prank(optimisticProposer);
//         vm.expectRevert(
//             abi.encodeWithSelector(
//                 IReserveOptimisticGovernor.InvalidFunctionCall.selector,
//                 address(governor),
//                 governor.setOptimisticParams.selector
//             )
//         );
//         governor.proposeOptimistic(targets, values, calldatas, description);
//     }

//     function test_registry_cannotTargetTimelockOptimistically() public {
//         address[] memory targets = new address[](1);
//         targets[0] = address(timelock);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(timelock.updateDelay, (1 days));

//         string memory description = "Try timelock via optimistic";

//         vm.prank(optimisticProposer);
//         vm.expectRevert(
//             abi.encodeWithSelector(
//                 IReserveOptimisticGovernor.InvalidFunctionCall.selector,
//                 address(timelock),
//                 timelock.updateDelay.selector
//             )
//         );
//         governor.proposeOptimistic(targets, values, calldatas, description);
//     }

//     // ==================== Upgrade Tests ====================

//     function test_upgradeGovernor_viaGovernance() public {
//         // Deploy new governor implementation
//         ReserveOptimisticGovernorV2Mock newImpl = new ReserveOptimisticGovernorV2Mock();

//         // Create proposal to upgrade governor
//         address[] memory targets = new address[](1);
//         targets[0] = address(governor);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(governor.upgradeToAndCall, (address(newImpl), ""));

//         string memory description = "Upgrade governor to V2";

//         vm.warp(block.timestamp + 1);

//         // Create slow proposal
//         vm.prank(alice);
//         uint256 proposalId = governor.propose(targets, values, calldatas, description);

//         // Pass voting
//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(proposalId, 1);
//         vm.prank(bob);
//         governor.castVote(proposalId, 1);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         // Queue
//         bytes32 descriptionHash = keccak256(bytes(description));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         // Execute after timelock delay
//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
//         governor.execute(targets, values, calldatas, descriptionHash);

//         // Verify upgrade succeeded by calling new function
//         assertEq(ReserveOptimisticGovernorV2Mock(payable(address(governor))).version(), "2.0.0");
//     }

//     function test_cannotUpgradeGovernor_unauthorized() public {
//         // Deploy new governor implementation
//         ReserveOptimisticGovernorV2Mock newImpl = new ReserveOptimisticGovernorV2Mock();

//         // Try to upgrade directly (not via governance) - should fail
//         vm.prank(alice);
//         vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, alice));
//         governor.upgradeToAndCall(address(newImpl), "");
//     }

//     function test_upgradeTimelock_viaSelfCall() public {
//         // Deploy new timelock implementation
//         TimelockControllerOptimisticV2Mock newImpl = new TimelockControllerOptimisticV2Mock();

//         // Create proposal to upgrade timelock (timelock calls itself)
//         address[] memory targets = new address[](1);
//         targets[0] = address(timelock);

//         uint256[] memory values = new uint256[](1);
//         values[0] = 0;

//         bytes[] memory calldatas = new bytes[](1);
//         calldatas[0] = abi.encodeCall(timelock.upgradeToAndCall, (address(newImpl), ""));

//         string memory description = "Upgrade timelock to V2";

//         vm.warp(block.timestamp + 1);

//         // Create slow proposal
//         vm.prank(alice);
//         uint256 proposalId = governor.propose(targets, values, calldatas, description);

//         // Pass voting
//         vm.warp(block.timestamp + VOTING_DELAY + 1);
//         vm.prank(alice);
//         governor.castVote(proposalId, 1);
//         vm.prank(bob);
//         governor.castVote(proposalId, 1);

//         vm.warp(block.timestamp + VOTING_PERIOD + 1);

//         // Queue
//         bytes32 descriptionHash = keccak256(bytes(description));
//         governor.queue(targets, values, calldatas, descriptionHash);

//         // Execute after timelock delay
//         vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
//         governor.execute(targets, values, calldatas, descriptionHash);

//         // Verify upgrade succeeded by calling new function
//         assertEq(TimelockControllerOptimisticV2Mock(payable(address(timelock))).version(), "2.0.0");
//     }

//     function test_cannotUpgradeTimelock_unauthorized() public {
//         // Deploy new timelock implementation
//         TimelockControllerOptimisticV2Mock newImpl = new TimelockControllerOptimisticV2Mock();

//         // Try to upgrade directly (not via self-call) - should fail
//         vm.prank(alice);
//         vm.expectRevert(ITimelockControllerOptimistic.TimelockControllerOptimistic__UnauthorizedUpgrade.selector);
//         timelock.upgradeToAndCall(address(newImpl), "");
//     }
// }
