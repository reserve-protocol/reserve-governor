# Reserve Governor

A hybrid optimistic/pessimistic governance system for the Reserve protocol.

## Overview

Reserve Governor provides two proposal paths through a single timelock:

- **Fast (Optimistic)**: Quick execution after a short veto period, no voting required
- **Slow (Standard)**: Full voting process with timelock delay

This design enables efficient day-to-day governance while preserving community override capabilities.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      ReserveGovernor                            │
│  ┌─────────────────────┐    ┌─────────────────────────────────┐ │
│  │   Fast (Optimistic) │    │        Slow (Standard)          │ │
│  │                     │    │                                 │ │
│  │  proposeOptimistic  │    │  propose / vote / queue         │ │
│  │  executeOptimistic  │    │  execute                        │ │
│  │                     │    │  cancel                         │ │
│  └──────────┬──────────┘    └────────────────┬────────────────┘ │
│             │                                │                  │
│             └────────────────┬───────────────┘                  │
└──────────────────────────────┼──────────────────────────────────┘
                               │
                               ▼
               ┌───────────────────────────────┐
               │  TimelockControllerOptimistic │
               │                               │
               │  Fast: executeBatchBypass()   │
               │  Slow: scheduleBatch()        │
               └───────────────────────────────┘
```

## Governance Flows

### Fast Proposal Lifecycle

Fast proposals skip voting entirely and execute after a veto period unless community members stake tokens to challenge them.

**OptimisticProposalState enum**: `Active`, `Succeeded`, `Locked`, `Vetoed`, `Slashed`, `Canceled`, `Executed`

```
                                    ┌──────────────────────────────┐
                                    │          ACTIVE              │
                                    │    (veto period ongoing)     │
                                    └──────────────┬───────────────┘
                                                   │
                    ┌──────────────────────────────┼──────────────────────────────┐
                    │                              │                              │
                    ▼                              ▼                              ▼
            ┌───────────────┐             ┌───────────────┐              ┌───────────────┐
            │   CANCELED    │             │   SUCCEEDED   │              │    LOCKED     │
            │               │             │ (veto period  │              │  (dispute     │
            │ (guardian or  │             │   expired)    │              │   started)    │
            │  proposer)    │             └───────┬───────┘              └───────┬───────┘
            └───────────────┘                     │                              │
                                                  ▼                   ┌──────────┼──────────┐
                                          ┌───────────────┐          │          │          │
                                          │   EXECUTED    │          ▼          ▼          ▼
                                          │  (via bypass) │   ┌──────────┐ ┌────────┐ ┌────────┐
                                          └───────────────┘   │ SLASHED  │ │ VETOED │ │CANCELED│
                                                              │(dispute  │ │(dispute│ │(dispute│
                                                              │ passed;  │ │ failed/│ │canceled│
                                                              │ executes)│ │expired)│ │   )    │
                                                              └──────────┘ └────────┘ └────────┘
```

### Fast Proposal Paths

| Path | Name | Flow | Outcome |
|------|------|------|---------|
| F1 | Uncontested Success | Active → Succeeded → Executed | Proposal executes after veto period via `executeOptimistic()` |
| F2 | Early Cancellation | Active → Canceled | Proposal stopped before dispute; stakers withdraw full amount |
| F3 | Dispute Passes | Active → Locked → Slashed | Vetoers were wrong; slashed, proposal executes via slow vote |
| F4 | Dispute Fails (Veto Succeeds) | Active → Locked → Vetoed | Veto succeeds! Proposal blocked, stakers withdraw full amount |
| F5a | Dispute Canceled | Active → Locked → Canceled | Guardian cancels dispute; stakers withdraw full amount |
| F5b | Dispute Expired | Active → Locked → Vetoed | Vote expires without execution; stakers withdraw full amount |

### Slow Proposal Lifecycle

Slow proposals follow the standard OpenZeppelin Governor flow with voting and timelock queuing.

**ProposalState enum** (from OZ Governor): `Pending`, `Active`, `Canceled`, `Defeated`, `Succeeded`, `Queued`, `Expired`, `Executed`

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   PENDING   │────▶│   ACTIVE    │────▶│  SUCCEEDED  │────▶│   QUEUED    │────▶│  EXECUTED   │
│ (voting     │     │  (voting    │     │  (quorum    │     │ (timelock   │     │             │
│  delay)     │     │   open)     │     │   met)      │     │  delay)     │     │             │
└──────┬──────┘     └──────┬──────┘     └─────────────┘     └──────┬──────┘     └─────────────┘
       │                   │                                       │
       ▼                   ▼                                       ▼
┌─────────────┐     ┌─────────────┐                         ┌─────────────┐
│  CANCELED   │     │  DEFEATED   │                         │   EXPIRED   │
│             │     │ (quorum not │                         │ (not exec'd │
│             │     │ met or vote │                         │  in time)   │
│             │     │  against)   │                         │             │
└─────────────┘     └─────────────┘                         └─────────────┘
```

### Slow Proposal Paths

| Path | Name | Flow | Outcome |
|------|------|------|---------|
| S1 | Standard Success | Pending → Active → Succeeded → Queued → Executed | Normal governance execution |
| S2 | Voting Defeated | Pending → Active → Defeated | Proposal rejected by voters |
| S3 | Early Cancellation | Pending → Canceled | Canceled before voting starts |
| S4 | Timeout/Expiry | Pending → Active → Succeeded → Queued → Expired | Queued but never executed in time |

## Veto Mechanism

### How Veto Works

1. Any token holder can call `stakeToVeto(amount)` on an `OptimisticProposal` during the veto period
2. Staked tokens are locked in the proposal contract
3. If total staked tokens reach `vetoThreshold`, the proposal enters `Locked` state
4. The proposal automatically initiates a slow (dispute) vote via `governor.proposeDispute()`, which casts the staked tokens as initial AGAINST votes
5. The dispute vote determines whether the proposal should execute

### Veto Threshold

```
vetoThreshold = ceil((vetoThresholdRatio * tokenSupply) / 1e18)
```

## Dispute Process

When a fast proposal reaches the vetoThreshold (becomes `Locked`):

1. **Slow Vote Initiated**: The `OptimisticProposal` calls `governor.proposeDispute()` to start a standard governance vote with staked tokens counted as initial AGAINST votes
2. **Four Possible Outcomes**:

| Dispute Result | OptimisticProposal State | Proposal Outcome | Staker Outcome |
|---------------------|--------------------------|------------------|----------------|
| **Vote Passes** (Executed) | `Slashed` | Proposal executes | Slashed on withdrawal |
| **Vote Fails** (Defeated) | `Vetoed` | Proposal blocked | Full refund |
| **Vote Expired** | `Vetoed` | Proposal blocked | Full refund |
| **Vote Canceled** | `Canceled` | Proposal blocked | Full refund |

### Slashing Mechanics

Slashing only applies when the dispute vote passes (state = `Slashed`):

```
withdrawalAmount = stakedAmount * (1e18 - slashingPercentage) / 1e18
```

Slashed tokens are burned via `token.burn()`.

## Staker Guide

### When You Can Withdraw

| Proposal State | Can Withdraw? | Slashing Applied? | Meaning |
|----------------|---------------|-------------------|---------|
| Active | Yes | No | Veto period ongoing, can unstake |
| Succeeded | Yes | No | Veto period ended without challenge |
| Locked | **No** | N/A | Dispute in progress |
| Vetoed | Yes | **No** | Veto succeeded! Stakers were right |
| Slashed | Yes | **Yes** | Vetoers were wrong, penalty applied |
| Canceled | Yes | No | Proposal canceled, full refund |
| Executed | Yes | No | Proposal executed without dispute |

### Risk Assessment

**Low Risk Scenarios:**
- Staking against clearly malicious proposals
- Proposals where community consensus opposes execution

**High Risk Scenarios:**
- Staking against legitimate proposals (risk of slashing if dispute passes)

### Key Insight: Vetoed vs Slashed

- **Vetoed**: The community AGREED with the stakers. The dispute vote failed/was defeated, confirming the proposal should not execute. Stakers get their full stake back as a reward for protecting the protocol.

- **Slashed**: The community DISAGREED with the stakers. The dispute vote passed, meaning the proposal was legitimate. Stakers are penalized for blocking a valid proposal.

## Proposal Types

The `proposalType(proposalId)` function returns the type of a proposal:

```solidity
enum ProposalType {
    Optimistic,  // Fast proposal (no voting unless disputed)
    Standard     // Slow proposal (full voting process)
}
```

- **Optimistic**: Created via `proposeOptimistic()`, uses `OptimisticProposal.state()` for status
- **Standard**: Created via `propose()` or when dispute is triggered, uses `governor.state()` for status

## Roles

| Role | Permissions |
|------|-------------|
| `OPTIMISTIC_PROPOSER_ROLE` | Create and execute fast proposals |
| `PROPOSER_ROLE` | Create slow proposals (via standard Governor) |
| `EXECUTOR_ROLE` | Execute queued slow proposals |
| `CANCELLER_ROLE` | Cancel proposals (fast or slow) |

#### OPTIMISTIC_PROPOSER_ROLE

The `OPTIMISTIC_PROPOSER_ROLE` is managed on the timelock via standard AccessControl:

- Granted via `timelock.grantRole(OPTIMISTIC_PROPOSER_ROLE, address)`
- Revoked via `timelock.revokeRole(OPTIMISTIC_PROPOSER_ROLE, address)`
- Checked via `timelock.hasRole(OPTIMISTIC_PROPOSER_ROLE, address)`

## Contract Reference

### ReserveGovernor

The main hybrid governor contract.

**Fast Proposal Functions:**
- `proposeOptimistic(targets, values, calldatas, description)` - Create a fast proposal
- `executeOptimistic(proposalId)` - Execute a succeeded fast proposal
- `proposeDispute(targets, values, calldatas, description, initialVotesAgainst)` - Create a dispute proposal (only callable by OptimisticProposal contracts)

**State Query:**
- `proposalType(proposalId)` - Returns `Optimistic` or `Standard`
- `state(proposalId)` - Standard Governor state (for Standard proposals)
- `optimisticProposals(proposalId)` - Get the OptimisticProposal contract for a proposal
- `activeOptimisticProposalsCount()` - Number of active optimistic proposals

**Configuration:**
- `setOptimisticParams(params)` - Update veto period, threshold, and slashing percentage

### OptimisticProposal

Per-proposal contract handling veto logic. Created as a clone for each fast proposal.

**User Functions:**
- `stakeToVeto(amount)` - Stake tokens against the proposal
- `withdraw()` - Withdraw staked tokens (with potential slashing)

**Admin Functions:**
- `cancel()` - Cancel proposal (requires CANCELLER_ROLE or OPTIMISTIC_PROPOSER_ROLE, only in Active/Succeeded state)

**State Query:**
- `state()` - Returns `OptimisticProposalState`
- `staked(address)` - Returns amount staked by address
- `totalStaked` - Total tokens staked against the proposal
- `voteEnd` - Timestamp when veto period ends (uint48)
- `vetoThreshold` - Token amount needed to trigger dispute
- `canceled` - Whether proposal was canceled
- `proposalData()` - Returns `(targets, values, calldatas, description)`

### TimelockControllerOptimistic

Extended timelock supporting both flows.

- Slow proposals use standard `scheduleBatch()` + `executeBatch()`
- Fast proposals use `executeBatchBypass()` for immediate execution

## Parameters

### Optimistic Governance Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `vetoPeriod` | `uint32` | Duration of veto window in seconds |
| `vetoThreshold` | `uint256` | Fraction of supply needed to trigger dispute (D18) |
| `slashingPercentage` | `uint256` | Fraction of stake slashed on failed veto (D18) |
| `numParallelProposals` | `uint256` | Maximum number of concurrent optimistic proposals |

### Standard Governance Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `votingDelay` | `uint48` | Delay before voting snapshot |
| `votingPeriod` | `uint32` | Duration of voting window |
| `voteExtension` | `uint48` | Late quorum time extension |
| `proposalThreshold` | `uint256` | Fraction of supply needed to propose (D18) |
| `quorumNumerator` | `uint256` | Percentage of supply needed for quorum (0-100) |

### Parameter Constraints

The following enforcement limits apply to optimistic governance parameters:

| Parameter | Constraint | Constant |
|-----------|------------|----------|
| `vetoPeriod` | >= 30 minutes | `MIN_OPTIMISTIC_VETO_PERIOD` |
| `vetoThreshold` | > 0 and <= 20% | `MAX_VETO_THRESHOLD` |
| `slashingPercentage` | >= 0 and <= 100% | Validated in `_setOptimisticParams()` |
| `numParallelProposals` | <= 5 | `MAX_PARALLEL_OPTIMISTIC_PROPOSALS` |

## Token Requirements

### IVetoToken Interface

The governance token must implement the `IVetoToken` interface, which extends `IERC20` and `IVotes`:

- **`burn(uint256 amount)`**: Required for slashing mechanics. Must not revert for zero amount.
- **`getPastTotalSupply(uint256 timepoint)`**: Required for snapshot-based veto threshold calculation.

The burn function is verified at initialization by calling `token.burn(0)`.

### Token Compatibility Warnings

- **Rebasing tokens**: Not compatible with rebasing tokens
- **Direct transfers**: Do NOT send tokens to OptimisticProposal directly; use `stakeToVeto()` instead
- **Supply limit**: Token supply should be less than 1e59

## Meta-Governance Restriction

Fast (optimistic) proposals **cannot target**:
- The `ReserveGovernor` contract
- The `TimelockControllerOptimistic` contract

This prevents governance takeover via the optimistic path. Attempting to target these contracts reverts with `NoMetaGovernanceThroughOptimistic()`.

Any governance changes to the system itself must go through the slow proposal path with full community voting.

## Upgradeability

Both contracts are UUPS upgradeable:

| Contract | Upgrade Authorization |
|----------|----------------------|
| `ReserveGovernor` | Via governance (timelock must call `upgradeToAndCall`) |
| `TimelockControllerOptimistic` | Self-administered (only the timelock itself can upgrade) |

## Flow Summary

```
Fast Proposal:
  proposeOptimistic() → [veto period: ACTIVE] → executeOptimistic()
                                │                       ↓
                                │                   SUCCEEDED
                                │                       ↓
                                │                   EXECUTED
                                │
                                └─► [staking reaches threshold]
                                            │
                                            ▼
                                      LOCKED (dispute)
                                            │
                        ┌───────────────────┼───────────────────┐
                        ▼                   ▼                   ▼
                  vote passes        vote fails/expired    vote canceled
                        │                   │                   │
                        ▼                   ▼                   ▼
                    SLASHED              VETOED             CANCELED
                        │                   │                   │
                        ▼                   ▼                   ▼
                   executed +          blocked +           blocked +
                   stakers slashed     full refund         full refund

Slow Proposal:
  propose() → [voting delay] → [voting period] → queue() → [timelock] → execute()
                   │                  │                         │
                   ▼                  ▼                         ▼
               PENDING → ACTIVE → SUCCEEDED → QUEUED → EXECUTED
                   │                  │                         │
                   ▼                  ▼                         ▼
               CANCELED           DEFEATED                  EXPIRED
```
