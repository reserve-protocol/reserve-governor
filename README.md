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
│  │  cancelOptimistic   │    │  cancel                         │ │
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

**OptimisticProposalState enum**: `Active`, `Succeeded`, `Locked`, `Vetoed`, `Slashed`, `Canceled`

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
            │               │             │ (veto period  │              │ (adjudication │
            │ (guardian or  │             │   expired)    │              │   started)    │
            │  proposer)    │             └───────┬───────┘              └───────┬───────┘
            └───────────────┘                     │                              │
                                                  ▼                   ┌──────────┼──────────┐
                                          ┌───────────────┐          │          │          │
                                          │   EXECUTED    │          ▼          ▼          ▼
                                          │  (via bypass) │   ┌──────────┐ ┌────────┐ ┌────────┐
                                          └───────────────┘   │ SLASHED  │ │ VETOED │ │CANCELED│
                                                              │(adjudic. │ │(adjud. │ │(adjud. │
                                                              │ passed)  │ │ failed/│ │canceled│
                                                              │          │ │expired)│ │        │
                                                              └────┬─────┘ └────────┘ └────────┘
                                                                   │
                                                                   ▼
                                                              ┌──────────┐
                                                              │ EXECUTED │
                                                              │(via slow │
                                                              │  vote)   │
                                                              └──────────┘
```

### Fast Proposal Paths

| Path | Name | Flow | Outcome |
|------|------|------|---------|
| F1 | Uncontested Success | Active → Succeeded → Executed | Proposal executes after veto period via `executeOptimistic()` |
| F2 | Early Cancellation | Active → Canceled | Proposal stopped before adjudication; stakers withdraw full amount |
| F3 | Adjudication Passes | Active → Locked → Slashed → Executed | Vetoers were wrong; slashed, proposal executes via slow vote |
| F4 | Adjudication Fails (Veto Succeeds) | Active → Locked → Vetoed | Veto succeeds! Proposal blocked, stakers withdraw full amount |
| F5a | Adjudication Canceled | Active → Locked → Canceled | Guardian cancels adjudication; stakers withdraw full amount |
| F5b | Adjudication Expired | Active → Locked → Vetoed | Vote expires without execution; stakers withdraw full amount |

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

1. Any token holder can call `stake(amount)` on an `OptimisticProposal` during the veto period
2. Staked tokens are locked in the proposal contract
3. If total staked tokens reach `vetoThreshold`, the proposal enters `Locked` state
4. The proposal automatically initiates a slow (adjudication) vote via `governor.propose()`
5. The adjudication vote determines whether the proposal should execute

### Veto Threshold

```
vetoThreshold = ceil((vetoThresholdRatio * tokenSupply) / 1e18)
```

## Adjudication Process

When a fast proposal reaches the vetoThreshold (becomes `Locked`):

1. **Slow Vote Initiated**: The `OptimisticProposal` calls `governor.propose()` to start a standard governance vote
2. **Four Possible Outcomes**:

| Adjudication Result | OptimisticProposal State | Proposal Outcome | Staker Outcome |
|---------------------|--------------------------|------------------|----------------|
| **Vote Passes** (Executed) | `Slashed` | Proposal executes | Slashed on withdrawal |
| **Vote Fails** (Defeated) | `Vetoed` | Proposal blocked | Full refund |
| **Vote Expired** | `Vetoed` | Proposal blocked | Full refund |
| **Vote Canceled** | `Canceled` | Proposal blocked | Full refund |

### Slashing Mechanics

Slashing only applies when the adjudication vote passes (state = `Slashed`):

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
| Locked | **No** | N/A | Adjudication in progress |
| Vetoed | Yes | **No** | Veto succeeded! Stakers were right |
| Slashed | Yes | **Yes** | Vetoers were wrong, penalty applied |
| Canceled | Yes | No | Proposal canceled, full refund |

### Risk Assessment

**Low Risk Scenarios:**
- Staking against clearly malicious proposals
- Proposals where community consensus opposes execution

**High Risk Scenarios:**
- Staking against legitimate proposals (risk of slashing if adjudication passes)

### Key Insight: Vetoed vs Slashed

- **Vetoed**: The community AGREED with the stakers. The adjudication vote failed/was defeated, confirming the proposal should not execute. Stakers get their full stake back as a reward for protecting the protocol.

- **Slashed**: The community DISAGREED with the stakers. The adjudication vote passed, meaning the proposal was legitimate. Stakers are penalized for blocking a valid proposal.

## MetaProposalState

The `metaState(proposalId)` function provides a unified view across both proposal flows:

```solidity
enum MetaProposalState {
    Optimistic,  // Fast proposal in Active state (veto period)
    Pending,     // Slow proposal waiting for voting
    Active,      // Slow proposal voting in progress
    Canceled,
    Defeated,
    Succeeded,   // Fast proposal passed veto period OR slow vote succeeded
    Queued,
    Expired,
    Executed
}
```

## Roles

| Role | Permissions |
|------|-------------|
| `OptimisticProposer` | Create and execute fast proposals |
| `PROPOSER_ROLE` | Create slow proposals (via standard Governor) |
| `EXECUTOR_ROLE` | Execute queued slow proposals |
| `CANCELLER_ROLE` | Cancel proposals (fast or slow) |

### OptimisticProposer

The `OPTIMISTIC_PROPOSER_ROLE` is managed on the timelock via standard AccessControl:

- Granted via `timelock.grantRole(OPTIMISTIC_PROPOSER_ROLE, address)`
- Revoked via `timelock.revokeRole(OPTIMISTIC_PROPOSER_ROLE, address)`
- Checked via `timelock.hasRole(OPTIMISTIC_PROPOSER_ROLE, address)`

## Contract Reference

### ReserveGovernor

The main hybrid governor contract.

**Fast Proposal Functions:**
- `proposeOptimistic(targets, values, calldatas, description)` - Create a fast proposal
- `executeOptimistic(targets, values, calldatas, descriptionHash)` - Execute a succeeded fast proposal
- `cancelOptimistic(proposalId)` - Cancel a fast proposal (callable by anyone when Vetoed, or by CANCELLER/OPTIMISTIC_PROPOSER when Active/Succeeded)

**State Query:**
- `metaState(proposalId)` - Unified state across both flows
- `state(proposalId)` - Standard Governor state (use `metaState()` for external consumers)
- `optimisticProposals(proposalId)` - Get the OptimisticProposal contract for a proposal

**Configuration:**
- `setOptimisticParams(params)` - Update veto period, threshold, and slashing percentage

### OptimisticProposal

Per-proposal contract handling veto logic. Created as a clone for each fast proposal.

**User Functions:**
- `stake(amount)` - Stake tokens against the proposal
- `withdraw()` - Withdraw staked tokens (with potential slashing)

**State Query:**
- `state()` - Returns `OptimisticProposalState`
- `staked(address)` - Returns amount staked by address
- `totalStaked` - Total tokens staked against the proposal
- `vetoEnd` - Timestamp when veto period ends
- `vetoThreshold` - Token amount needed to trigger adjudication
- `canceled` - Whether proposal was canceled

### TimelockControllerOptimistic

Extended timelock supporting both flows.

- Slow proposals use standard `scheduleBatch()` + `executeBatch()`
- Fast proposals use `executeBatchBypass()` for immediate execution

## Parameters

### Optimistic Governance Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `vetoPeriod` | `uint256` | Duration of veto window in seconds |
| `vetoThreshold` | `uint256` | Fraction of supply needed to trigger adjudication (D18) |
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
                                      LOCKED (adjudication)
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
