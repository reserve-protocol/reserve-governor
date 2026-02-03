# Reserve Governor

A hybrid optimistic/pessimistic governance system for the Reserve protocol.

## Overview

Reserve Governor provides two proposal paths through a single timelock:

- **Fast (Optimistic)**: Quick execution after a short veto period, no voting required
- **Slow (Standard)**: Full voting process with timelock delay

This design enables efficient day-to-day governance while preserving community override capabilities.

## Architecture

The system consists of six components:

1. **StakingVault** — ERC4626 vault with vote-locking, multi-token rewards, and unstaking delay
2. **UnstakingManager** — Time-locked withdrawal manager created by StakingVault during initialization
3. **ReserveOptimisticGovernor** — Hybrid governor unifying optimistic/standard proposal flows
4. **OptimisticSelectorRegistry** — Whitelist of allowed `(target, selector)` pairs for optimistic proposals
5. **TimelockControllerOptimistic** — Single timelock for execution, with bypass for the optimistic path
6. **OptimisticProposal** — Per-proposal clone contract supporting veto staking and slashing

```
┌──────────────────────────────────┐
│          StakingVault            │
│  ERC4626 + ERC20Votes           │
│                                  │
│  deposit / withdraw / delegate   │
│  claimRewards / burn             │
│  ┌────────────────────────────┐  │
│  │     UnstakingManager      │  │
│  │  createLock / claimLock   │  │
│  │  cancelLock               │  │
│  └────────────────────────────┘  │
└───────────────┬──────────────────┘
                │ (voting token)
                ▼
┌─────────────────────────────────────────────────────────────────┐
│                  ReserveOptimisticGovernor                       │
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
               ┌───────────────┤
               │               │
               ▼               ▼
┌────────────────────────────────┐  ┌───────────────────────────────┐
│  OptimisticSelectorRegistry   │  │  TimelockControllerOptimistic │
│                               │  │                               │
│  Allowed (target,             │  │  Fast: executeBatchBypass()   │
│   selector) pairs             │  │  Slow: scheduleBatch()        │
└────────────────────────────────┘  └───────────────────────────────┘
```

The governor checks each call in an optimistic proposal against the `OptimisticSelectorRegistry` before creating it. Only whitelisted `(target, selector)` pairs are permitted.

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
            │               │             │ (veto period  │              │ (confirmation │
            │ (guardian or  │             │   expired)    │              │    started)   │
            │  proposer)    │             └───────┬───────┘              └───────┬───────┘
            └───────────────┘                     │                              │
                                                  ▼                   ┌──────────┼──────────┐
                                          ┌───────────────┐          │          │          │
                                          │   EXECUTED    │          ▼          ▼          ▼
                                          │  (via bypass) │   ┌──────────┐ ┌─────────-┐ ┌─────────-┐
                                          └───────────────┘   │ SLASHED  │ │  VETOED  │ │ CANCELED │
                                                              │(confirm  │ │(confirm  │ │(confirm  │
                                                              │ passed;  │ │ failed)  │ │ canceled)│
                                                              │ executes)│ │          │ │          │
                                                              └──────────┘ └─────────-┘ └─────────-┘
```

### Fast Proposal Paths

| Path | Name                          | Flow                          | Outcome                                                            |
| ---- | ----------------------------- | ----------------------------- | ------------------------------------------------------------------ |
| F1   | Uncontested Success           | Active → Succeeded → Executed | Proposal executes after veto period via `executeOptimistic()`      |
| F2   | Early Cancellation            | Active → Canceled             | Proposal stopped before confirmation; stakers withdraw full amount |
| F3   | Confirmation Passes           | Active → Locked → Slashed     | Vetoers were wrong; slashed, proposal executes via slow vote  |
| F4   | Confirmation Fails            | Active → Locked → Vetoed      | Veto succeeds! Proposal blocked, stakers withdraw full amount |
| F5   | Confirmation Canceled         | Active → Locked → Canceled    | Guardian cancels confirmation; stakers withdraw full amount   |

### Slow Proposal Lifecycle

Slow proposals follow the standard OpenZeppelin Governor flow with voting and timelock queuing.

**ProposalState enum** (from OZ Governor): `Pending`, `Active`, `Canceled`, `Defeated`, `Succeeded`, `Queued`, `Executed`

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   PENDING   │────▶│   ACTIVE    │────▶│  SUCCEEDED  │────▶│   QUEUED    │────▶│  EXECUTED   │
│ (voting     │     │  (voting    │     │  (quorum    │     │ (timelock   │     │             │
│  delay)     │     │   open)     │     │   met)      │     │  delay)     │     │             │
└──────┬──────┘     └──────┬──────┘     └─────────────┘     └─────────────┘     └─────────────┘
       │                   │
       ▼                   ▼
┌─────────────┐     ┌─────────────┐
│  CANCELED   │     │  DEFEATED   │
│             │     │ (quorum not │
│             │     │ met or vote │
│             │     │  against)   │
└─────────────┘     └─────────────┘
```

### Slow Proposal Paths

| Path | Name               | Flow                                             | Outcome                       |
| ---- | ------------------ | ------------------------------------------------ | ----------------------------- |
| S1   | Success            | Pending → Active → Succeeded → Queued → Executed | Normal governance execution   |
| S2   | Voting Defeated    | Pending → Active → Defeated                      | Proposal rejected by voters   |
| S3   | Early Cancellation | Pending → Canceled                               | Canceled before voting starts |

## Veto Mechanism

### How Veto Works

1. Any token holder can call `stakeToVeto(maxAmount)` on an `OptimisticProposal` during the veto period
2. Staked tokens are locked in the proposal contract
3. If total staked tokens reach `vetoThreshold`, the proposal enters `Locked` state
4. The proposal automatically initiates a slow (confirmation) vote via `governor.proposeConfirmation()`, which casts the staked tokens as initial AGAINST votes
5. The confirmation vote determines whether the proposal should execute

### Veto Threshold

```
vetoThreshold = ceil((vetoThresholdRatio * tokenSupply) / 1e18)
```

## Confirmation Process

When a fast proposal reaches the vetoThreshold (becomes `Locked`):

1. **Slow Vote Initiated**: The `OptimisticProposal` calls `governor.proposeConfirmation()` to start a standard governance vote with staked tokens counted as initial AGAINST votes
2. **Three Possible Outcomes**:

| Confirmation Result        | OptimisticProposal State | Proposal Outcome  | Staker Outcome        |
| -------------------------- | ------------------------ | ----------------- | --------------------- |
| **Vote Passes** (Executed) | `Slashed`                | Proposal executes | Slashed on withdrawal |
| **Vote Fails** (Defeated)  | `Vetoed`                 | Proposal blocked  | Full refund           |
| **Vote Canceled**          | `Canceled`               | Proposal blocked  | Full refund           |

### Slashing Mechanics

Slashing only applies when the confirmation vote passes (state = `Slashed`):

```
withdrawalAmount = stakedAmount * (1e18 - slashingPercentage) / 1e18
```

Slashed tokens are burned via `token.burn()`.

## Staker Guide

### When You Can Withdraw

| Proposal State | Can Withdraw? | Slashing Applied? | Meaning                             |
| -------------- | ------------- | ----------------- | ----------------------------------- |
| Active         | Yes           | No                | Veto period ongoing, can unstake       |
| Succeeded      | Yes           | No                | Veto period ended without challenge    |
| Locked         | **No**        | N/A               | Confirmation vote in progress          |
| Vetoed         | Yes           | **No**            | Veto succeeded! Stakers were right  |
| Slashed        | Yes           | **Yes**           | Vetoers were wrong, penalty applied |
| Canceled       | Yes           | No                | Proposal canceled, full refund      |
| Executed       | Yes           | No                | Proposal executed without challenge |

### Risk Assessment

**Low Risk Scenarios:**

- Staking against clearly malicious proposals
- Proposals where community consensus opposes execution

**High Risk Scenarios:**

- Staking against legitimate proposals (risk of slashing if confirmation passes)

### Key Insight: Vetoed vs Slashed

- **Vetoed**: The community AGREED with the stakers. The confirmation vote failed/was defeated, confirming the proposal should not execute. Stakers get their full stake back as a reward for protecting the protocol.

- **Slashed**: The community DISAGREED with the stakers. The confirmation vote passed, meaning the proposal was legitimate. Stakers are penalized for blocking a valid proposal.

## Proposal Types

The `proposalType(proposalId)` function returns the type of a proposal:

```solidity
enum ProposalType {
    Optimistic,  // Fast proposal (no voting unless challenged)
    Standard     // Slow proposal (full voting process)
}
```

- **Optimistic**: Created via `proposeOptimistic()`, uses `OptimisticProposal.state()` for status
- **Standard**: Created via `propose()` or when confirmation vote is triggered, uses `governor.state()` for status

## Roles

| Role                       | Held By                                | Permissions                                                             |
| -------------------------- | -------------------------------------- | ----------------------------------------------------------------------- |
| `OPTIMISTIC_PROPOSER_ROLE` | Designated proposer EOAs               | Create and execute fast proposals                                       |
| `PROPOSER_ROLE`            | Governor contract                      | Schedule operations on the timelock (granted automatically by Deployer) |
| `EXECUTOR_ROLE`            | Governor contract                      | Execute queued slow proposals via the timelock                          |
| `CANCELLER_ROLE`           | Governor contract + Guardian addresses | Cancel proposals (fast or slow)                                         |

> **Note:** Standard (slow) proposals are created via `propose()` by any account meeting `proposalThreshold`. The `PROPOSER_ROLE` on the timelock is held by the governor contract itself — it allows the governor to schedule operations, not individual users to create proposals.

#### OPTIMISTIC_PROPOSER_ROLE

The `OPTIMISTIC_PROPOSER_ROLE` is managed on the timelock via standard AccessControl:

- Granted via `timelock.grantRole(OPTIMISTIC_PROPOSER_ROLE, address)`
- Revoked via `timelock.revokeRole(OPTIMISTIC_PROPOSER_ROLE, address)`
- Checked via `timelock.hasRole(OPTIMISTIC_PROPOSER_ROLE, address)`

## Contract Reference

### ReserveOptimisticGovernor

The main hybrid governor contract.

**Fast Proposal Functions:**

- `proposeOptimistic(targets, values, calldatas, description)` - Create a fast proposal
- `executeOptimistic(proposalId)` - Execute a succeeded fast proposal
- `proposeConfirmation(targets, values, calldatas, description, initialProposer, initialVotesAgainst)` - Create a confirmation proposal (only callable by OptimisticProposal contracts)

**State Query:**

- `proposalType(proposalId)` - Returns `Optimistic` or `Standard`
- `state(proposalId)` - Standard Governor state (for Standard proposals)
- `optimisticProposals(proposalId)` - Get the OptimisticProposal contract for a proposal
- `activeOptimisticProposalsCount()` - Number of active optimistic proposals
- `selectorRegistry()` - The OptimisticSelectorRegistry contract address

**Configuration:**

- `setOptimisticParams(params)` - Update optimistic governance parameters

### OptimisticProposal

Per-proposal contract handling veto logic. Created as a clone for each fast proposal.

**User Functions:**

- `stakeToVeto(maxAmount)` - Stake tokens against the proposal (up to maxAmount, capped at remaining needed)
- `withdraw()` - Withdraw staked tokens (with potential slashing)

**Admin Functions:**

- `cancel()` - Cancel proposal (requires CANCELLER_ROLE or be the proposer, only in Active/Succeeded state)

**State Query:**

- `state()` - Returns `OptimisticProposalState`
- `staked(address)` - Returns amount staked by address
- `totalStaked` - Total tokens staked against the proposal
- `voteEnd` - Timestamp when veto period ends (uint48)
- `vetoThreshold` - Token amount needed to trigger confirmation vote
- `canceled` - Whether proposal was canceled
- `proposalData()` - Returns `(targets, values, calldatas, description)`

### StakingVault

ERC4626 vault with vote-locking and multi-token rewards. Users deposit tokens to receive vault shares that carry voting power.

**User Functions:**

- `depositAndDelegate(assets)` - Deposit tokens and self-delegate voting power
- `claimRewards(rewardTokens[])` - Claim accumulated rewards for specified reward tokens
- `poke()` - Trigger reward accrual without performing an action

**Admin Functions (onlyOwner):**

- `addRewardToken(rewardToken)` - Add a new reward token for distribution
- `removeRewardToken(rewardToken)` - Remove a reward token from distribution
- `setUnstakingDelay(delay)` - Set the delay before unstaked tokens can be claimed
- `setRewardRatio(rewardHalfLife)` - Set the exponential decay half-life for reward distribution

**Other:**

- `burn(shares)` - Burn shares, converting their underlying value to native rewards
- `getAllRewardTokens()` - Return all active reward tokens

**Properties:**

- UUPS upgradeable (owner-authorized)
- Clock: timestamp-based (ERC5805)
- Creates an `UnstakingManager` during initialization

### UnstakingManager

Time-locked withdrawal manager, created by StakingVault during initialization.

**Functions:**

- `createLock(user, amount, unlockTime)` - Create a new unstaking lock (vault only)
- `claimLock(lockId)` - Claim tokens after unlock time is reached (anyone can call)
- `cancelLock(lockId)` - Cancel a lock and re-deposit tokens into the vault (lock owner only)

**Lock Struct:**

- `user` — Receiver of unstaked tokens
- `amount` — Amount of tokens locked
- `unlockTime` — Timestamp when tokens become claimable
- `claimedAt` — Timestamp when claimed (0 if not yet claimed)

### OptimisticSelectorRegistry

Whitelist of allowed `(target, selector)` pairs for optimistic proposals. Controlled by the timelock (governance-controlled).

**Management (onlyTimelock):**

- `registerSelectors(SelectorData[])` - Add allowed `(target, selector)` pairs
- `unregisterSelectors(SelectorData[])` - Remove allowed pairs

**Query:**

- `isAllowed(target, selector)` - Check if a `(target, selector)` pair is whitelisted
- `targets()` - List all targets that have at least one registered selector
- `selectorsAllowed(target)` - List all allowed selectors for a given target

**Constraints:**

- Cannot register itself as a target (reverts with `SelfAsTarget`)
- The governor and timelock are additionally blocked as targets in `OptimisticProposalLib` (hardcoded)

### Deployer

Deploys the complete Reserve Governor system: StakingVault proxy, timelock proxy, selector registry clone, and governor proxy.

- Constructor takes 4 implementation addresses: `stakingVaultImpl`, `governorImpl`, `timelockImpl`, `selectorRegistryImpl`
- `deploy(DeploymentParams, deploymentNonce)` - Returns `(stakingVault, governor, timelock, selectorRegistry)`
- StakingVault is initialized with name `"Vote-Locked {Token}"`, symbol `"vl{Symbol}"`, default reward period 1 week, default unstaking delay 1 week
- StakingVault owner is set to the deployer contract address
- Configures all timelock roles (`PROPOSER_ROLE`, `EXECUTOR_ROLE`, `CANCELLER_ROLE` → governor; `CANCELLER_ROLE` → guardians; `OPTIMISTIC_PROPOSER_ROLE` → proposers) and renounces admin

### TimelockControllerOptimistic

Extended timelock supporting both flows.

- Slow proposals use standard `scheduleBatch()` + `executeBatch()`
- Fast proposals use `executeBatchBypass()` for immediate execution

## Parameters

### Optimistic Governance Parameters

| Parameter              | Type      | Description                                        |
| ---------------------- | --------- | -------------------------------------------------- |
| `vetoPeriod`           | `uint32`  | Duration of veto window in seconds                 |
| `vetoThreshold`        | `uint256` | Fraction of supply needed to trigger confirmation (D18) |
| `slashingPercentage`   | `uint256` | Fraction of stake slashed on failed veto (D18)     |
| `numParallelProposals` | `uint256` | Maximum number of concurrent optimistic proposals  |

### Standard Governance Parameters

| Parameter           | Type      | Description                                |
| ------------------- | --------- | ------------------------------------------ |
| `votingDelay`       | `uint48`  | Delay before voting snapshot               |
| `votingPeriod`      | `uint32`  | Duration of voting window                  |
| `voteExtension`     | `uint48`  | Late quorum time extension                 |
| `proposalThreshold` | `uint256` | Fraction of supply needed to propose (D18) |
| `quorumNumerator`   | `uint256` | Fraction of supply needed for quorum (D18) |

### Parameter Constraints

The following enforcement limits apply to optimistic governance parameters:

| Parameter              | Constraint       | Constant                              |
| ---------------------- | ---------------- | ------------------------------------- |
| `vetoPeriod`           | >= 30 minutes    | `MIN_OPTIMISTIC_VETO_PERIOD`          |
| `vetoThreshold`        | > 0 and <= 20%   | `MAX_VETO_THRESHOLD`                  |
| `slashingPercentage`   | >= 0 and <= 100% | Validated in `_setOptimisticParams()` |
| `numParallelProposals` | <= 5             | `MAX_PARALLEL_OPTIMISTIC_PROPOSALS`   |

### StakingVault Parameters

| Parameter        | Constraint          | Constant                                  |
| ---------------- | ------------------- | ----------------------------------------- |
| `unstakingDelay` | <= 4 weeks          | `MAX_UNSTAKING_DELAY`                     |
| `rewardHalfLife` | 1 day to 2 weeks    | `MIN_REWARD_HALF_LIFE`, `MAX_REWARD_HALF_LIFE` |

Defaults (from Constants.sol):

- `DEFAULT_REWARD_PERIOD` = 1 week
- `DEFAULT_UNSTAKING_DELAY` = 1 week

## Token Requirements

- **Rebasing tokens**: Not compatible with rebasing tokens
- **Direct transfers**: Do NOT send tokens to OptimisticProposal directly; use `stakeToVeto()` instead
- **Supply limit**: Token supply should be less than 1e59
- **Voting power**: Voting power is denominated in StakingVault shares, not the underlying token directly. Users must deposit into StakingVault and delegate to participate in governance.

## Optimistic Call Restrictions

Fast (optimistic) proposals can **only** call `(target, selector)` pairs registered in the `OptimisticSelectorRegistry`. In addition, two targets are **always** blocked regardless of the registry:

- The `ReserveOptimisticGovernor` contract (hardcoded in `OptimisticProposalLib`)
- The `TimelockControllerOptimistic` contract (hardcoded in `OptimisticProposalLib`)

The `OptimisticSelectorRegistry` also cannot be registered as a target within itself (reverts with `SelfAsTarget`).

Attempting a disallowed call reverts with `InvalidFunctionCall(target, selector)`.

Any governance changes to the system itself must go through the slow proposal path with full community voting.

## Upgradeability

Three contracts are UUPS upgradeable:

| Contract                       | Upgrade Authorization                                    |
| ------------------------------ | -------------------------------------------------------- |
| `StakingVault`                 | Owner-authorized (`onlyOwner`)                          |
| `ReserveOptimisticGovernor`    | Via governance (timelock must call `upgradeToAndCall`)   |
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
                                    LOCKED (confirmation)
                                            │
                        ┌───────────────────┼───────────────────┐
                        ▼                   ▼                   ▼
                  vote passes        vote fails    vote canceled
                        │                   │                   │
                        ▼                   ▼                   ▼
                    SLASHED              VETOED             CANCELED
                        │                   │                   │
                        ▼                   ▼                   ▼
                   executed +          blocked +           blocked +
                   stakers slashed     full refund         full refund

Slow Proposal:
  propose() → [voting delay] → [voting period] → queue() → [timelock] → execute()
                   │                  │
                   ▼                  ▼
               PENDING → ACTIVE → SUCCEEDED → QUEUED → EXECUTED
                   │       |         │          |
                   ▼       ▼         ▼          ▼
               CANCELED  CANCELED  DEFEATED  CANCELED
```

Note: Cancellations that occur during the QUEUED state will still incur a slashing. 
