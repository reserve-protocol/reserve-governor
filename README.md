# Reserve Governor

A hybrid optimistic/pessimistic governance system for the Reserve protocol.

## Overview

Reserve Governor provides two proposal paths through a single timelock:

- **Fast (Optimistic)**: Quick execution after a short veto period, no affirmative voting required
- **Slow (Standard)**: Full voting process with timelock delay

During a fast proposal's veto period, token holders can vote AGAINST. If enough AGAINST votes accumulate to reach the veto threshold, the proposal automatically transitions into a full confirmation vote (the slow path). This lets routine governance operate efficiently while preserving the community's ability to challenge any proposal.

## Architecture

The system consists of five components:

1. **StakingVault** -- ERC4626 vault with vote-locking, multi-token rewards, and unstaking delay
2. **UnstakingManager** -- Time-locked withdrawal manager created by StakingVault during initialization
3. **ReserveOptimisticGovernor** -- Hybrid governor unifying optimistic/standard proposal flows in shared OZ Governor storage
4. **OptimisticSelectorRegistry** -- Whitelist of allowed `(target, selector)` pairs for optimistic proposals
5. **TimelockControllerOptimistic** -- Single timelock for execution, with bypass for the optimistic path

```
┌──────────────────────────────────┐
│          StakingVault            │
│  ERC4626 + ERC20Votes           │
│                                  │
│  deposit / withdraw / delegate   │
│  claimRewards                    │
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

Fast proposals use the standard OZ Governor `ProposalState` enum. During the veto period, any token holder can vote. All vote types (For, Against, Abstain) are accepted, but only AGAINST votes are checked against the veto threshold.

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   PENDING   │────▶│   ACTIVE    │────▶│  SUCCEEDED  │────▶│  EXECUTED   │
│ (vetoDelay) │     │ (vetoPeriod │     │ (threshold  │     │ (via bypass)│
│             │     │  veto votes)│     │  not met)   │     │             │
└──────┬──────┘     └──────┬──────┘     └─────────────┘     └─────────────┘
       │                   │
       ▼                   ▼
┌─────────────┐     ┌─────────────┐
│  CANCELED   │     │  DEFEATED   │
│             │     │ (threshold  │──────▶ confirmation vote
│             │     │   reached)  │       (standard flow)
└─────────────┘     └─────────────┘
```

### Fast-to-Confirmation Transition

When AGAINST votes reach the veto threshold, the proposal transitions to a full confirmation vote:

1. `vetoThresholds[proposalId]` is cleared, converting the proposal to Standard type
2. `voteStart` and `voteDuration` are reset to the standard voting parameters (`votingDelay` and `votingPeriod`)
3. A `ConfirmationVoteScheduled` event is emitted
4. The confirmation vote follows the standard proposal flow (affirmative voting, quorum, timelock)

Votes and `hasVoted` state from the veto phase carry through to the confirmation vote. Voters who already voted during the veto phase cannot vote again.

### Fast Proposal Paths

| Path | Name             | Flow                                                                                          | Outcome                    |
| ---- | ---------------- | --------------------------------------------------------------------------------------------- | -------------------------- |
| F1   | Uncontested      | Pending -> Active -> Succeeded -> Executed                                                    | Executes via timelock bypass |
| F2   | Vetoed, Confirmed | Pending -> Active -> Defeated -> (confirmation) Pending -> Active -> Succeeded -> Queued -> Executed | Executes via timelock       |
| F3   | Vetoed, Rejected  | Pending -> Active -> Defeated -> (confirmation) Pending -> Active -> Defeated                | Proposal blocked           |
| F4   | Canceled         | Any non-final state -> Canceled                                                               | Proposer or guardian cancels |

### Slow Proposal Lifecycle

Slow proposals follow the standard OpenZeppelin Governor flow with voting, timelock queuing, and late quorum extension.

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

| Path | Name            | Flow                                                 | Outcome                       |
| ---- | --------------- | ---------------------------------------------------- | ----------------------------- |
| S1   | Success         | Pending -> Active -> Succeeded -> Queued -> Executed | Normal governance execution   |
| S2   | Voting Defeated | Pending -> Active -> Defeated                        | Proposal rejected by voters   |
| S3   | Cancellation    | Any non-final state -> Canceled                      | Proposer or guardian cancels |

## Veto Mechanism

During a fast proposal's veto period, any token holder can vote using the standard `castVote()` interface. All vote types are accepted, but only AGAINST votes matter for the veto threshold check.

**Veto threshold calculation:**

```
vetoThreshold = ceil(vetoThresholdRatio * pastTotalSupply / 1e18)
```

Where `pastTotalSupply = token.getPastTotalSupply(snapshot - 1)` and `vetoThresholdRatio` is a D18 fraction (e.g. `0.1e18` = 10%).

If the veto threshold is reached, the proposal is Defeated and automatically transitions to a confirmation vote. If the veto period expires without reaching the threshold, the proposal Succeeds and can be executed immediately via timelock bypass.

## Proposal Types

The `proposalType(proposalId)` function returns the type of a proposal:

```solidity
enum ProposalType {
    Optimistic,  // Fast proposal (no voting unless challenged)
    Standard     // Slow proposal (full voting process)
}
```

- **Optimistic**: Created via `proposeOptimistic()`, uses custom state logic for the veto phase
- **Standard**: Created via `propose()`, or an optimistic proposal that transitioned to a confirmation vote

## Roles

| Role                       | Held By                                | Permissions                                                             |
| -------------------------- | -------------------------------------- | ----------------------------------------------------------------------- |
| `OPTIMISTIC_PROPOSER_ROLE` | Designated proposer EOAs               | Create and execute fast proposals                                       |
| `PROPOSER_ROLE`            | Governor contract                      | Schedule operations on the timelock (granted automatically by Deployer) |
| `EXECUTOR_ROLE`            | Governor contract                      | Execute queued slow proposals via the timelock                          |
| `CANCELLER_ROLE`           | Governor contract + Guardian addresses | Cancel proposals (fast or slow), revoke optimistic proposers            |

> **Note:** Standard (slow) proposals are created via `propose()` by any account meeting `proposalThreshold`. The `PROPOSER_ROLE` on the timelock is held by the governor contract itself -- it allows the governor to schedule operations, not individual users to create proposals.

#### OPTIMISTIC_PROPOSER_ROLE

The `OPTIMISTIC_PROPOSER_ROLE` is managed on the timelock via standard AccessControl:

- Granted via `timelock.grantRole(OPTIMISTIC_PROPOSER_ROLE, address)`
- Revoked via `timelock.revokeRole(OPTIMISTIC_PROPOSER_ROLE, address)` or `timelock.revokeOptimisticProposer(address)` (callable by CANCELLER_ROLE)
- Checked via `timelock.hasRole(OPTIMISTIC_PROPOSER_ROLE, address)`
- Revocation blocks execution for all proposals that originated through `proposeOptimistic()` (including those that already transitioned to confirmation votes)

## Contract Reference

### ReserveOptimisticGovernor

The main hybrid governor contract.

**Fast Proposal Functions:**

- `proposeOptimistic(targets, values, calldatas, description)` -- Create a fast proposal (requires `OPTIMISTIC_PROPOSER_ROLE`)
- `executeOptimistic(targets, values, calldatas, description)` -- Execute a succeeded fast proposal (requires original proposer with active `OPTIMISTIC_PROPOSER_ROLE`)

**Standard Proposal Functions (inherited from OZ Governor):**

- `propose(targets, values, calldatas, description)` -- Create a standard proposal (requires `proposalThreshold`)
- `castVote(proposalId, support)` -- Cast a vote (works on both fast and slow proposals)
- `queue(targets, values, calldatas, descriptionHash)` -- Queue a succeeded standard proposal
- `execute(targets, values, calldatas, descriptionHash)` -- Execute a queued standard proposal
- `cancel(targets, values, calldatas, descriptionHash)` -- Cancel a proposal

**State Query:**

- `proposalType(proposalId)` -- Returns `Optimistic` or `Standard`
- `state(proposalId)` -- Returns `ProposalState` (unified for both types)
- `vetoThresholds(proposalId)` -- Returns the veto threshold for an optimistic proposal (0 if standard)
- `selectorRegistry()` -- The OptimisticSelectorRegistry contract address

**Configuration:**

- `setOptimisticParams(params)` -- Update optimistic governance parameters (onlyGovernance)

### OptimisticSelectorRegistry

Whitelist of allowed `(target, selector)` pairs for optimistic proposals. Controlled by the timelock (governance-controlled).

**Management (onlyTimelock):**

- `registerSelectors(SelectorData[])` -- Add allowed `(target, selector)` pairs
- `unregisterSelectors(SelectorData[])` -- Remove allowed pairs

**Query:**

- `isAllowed(target, selector)` -- Check if a `(target, selector)` pair is whitelisted
- `targets()` -- List all targets that have at least one registered selector
- `selectorsAllowed(target)` -- List all allowed selectors for a given target

**Constraints:**

- Cannot register itself as a target
- The governor, timelock, and StakingVault (token) are additionally blocked as targets

### TimelockControllerOptimistic

Extended timelock supporting both flows.

- Slow proposals use standard `scheduleBatch()` + `executeBatch()`
- Fast proposals use `executeBatchBypass()` for immediate execution (requires `PROPOSER_ROLE`)
- `revokeOptimisticProposer(account)` -- Revoke an optimistic proposer (requires `CANCELLER_ROLE`)

### StakingVault

ERC4626 vault with vote-locking and multi-token rewards. Users deposit tokens to receive vault shares that carry voting power.

IMPORTANT: StakingVault should only be deployed with an underlying token that has a STRONG value relationship to the system being governed. The token should not derive value from many sources. It is important that withdrawals that occur AFTER a malicious proposal executes do not recoup much value.

**User Functions:**

- `depositAndDelegate(assets)` -- Deposit tokens and self-delegate voting power
- `claimRewards(rewardTokens[])` -- Claim accumulated rewards for specified reward tokens
- `poke()` -- Trigger reward accrual without performing an action

**Admin Functions (onlyOwner):**

- `addRewardToken(rewardToken)` -- Add a new reward token for distribution
- `removeRewardToken(rewardToken)` -- Remove a reward token from distribution
- `setUnstakingDelay(delay)` -- Set the delay before unstaked tokens can be claimed
- `setRewardRatio(rewardHalfLife)` -- Set the exponential decay half-life for reward distribution

**Other:**

- `getAllRewardTokens()` -- Return all active reward tokens

**Properties:**

- UUPS upgradeable (owner-authorized)
- Clock: timestamp-based (ERC5805)
- Creates an `UnstakingManager` during initialization

### UnstakingManager

Time-locked withdrawal manager, created by StakingVault during initialization.

**Functions:**

- `createLock(user, amount, unlockTime)` -- Create a new unstaking lock (vault only)
- `claimLock(lockId)` -- Claim tokens after unlock time is reached (anyone can call; tokens go to lock owner)
- `cancelLock(lockId)` -- Cancel a lock and re-deposit tokens into the vault (lock owner only)

**Lock Struct:**

- `user` -- Receiver of unstaked tokens
- `amount` -- Amount of tokens locked
- `unlockTime` -- Timestamp when tokens become claimable
- `claimedAt` -- Timestamp when claimed (0 if not yet claimed)

## Parameters

### Optimistic Governance Parameters

| Parameter        | Type      | Description                                             |
| ---------------- | --------- | ------------------------------------------------------- |
| `vetoDelay`      | `uint48`  | Delay before veto voting starts (seconds)               |
| `vetoPeriod`     | `uint32`  | Duration of veto window (seconds)                       |
| `vetoThreshold`  | `uint256` | Fraction of supply needed to trigger confirmation (D18) |

### Standard Governance Parameters

| Parameter           | Type      | Description                                |
| ------------------- | --------- | ------------------------------------------ |
| `votingDelay`       | `uint48`  | Delay before voting snapshot               |
| `votingPeriod`      | `uint32`  | Duration of voting window                  |
| `voteExtension`     | `uint48`  | Late quorum time extension                 |
| `proposalThreshold` | `uint256` | Fraction of supply needed to propose (D18) |
| `quorumNumerator`   | `uint256` | Fraction of supply needed for quorum (D18) |

### Parameter Constraints

| Parameter           | Constraint    | Constant                     |
| ------------------- | ------------- | ---------------------------- |
| `vetoDelay`         | >= 1 second   | `MIN_OPTIMISTIC_VETO_DELAY`  |
| `vetoPeriod`        | >= 30 minutes | `MIN_OPTIMISTIC_VETO_PERIOD` |
| `vetoThreshold`     | > 0 and <= 100% |                            |
| `proposalThreshold` | <= 100%       |                              |

### StakingVault Parameters

| Parameter        | Constraint       | Constant                                      |
| ---------------- | ---------------- | --------------------------------------------- |
| `unstakingDelay` | <= 4 weeks       | `MAX_UNSTAKING_DELAY`                         |
| `rewardHalfLife` | 1 day to 2 weeks | `MIN_REWARD_HALF_LIFE`, `MAX_REWARD_HALF_LIFE` |

## Token Support

| Feature                         | Supported    |
| --------------------------------| ------------ |
| Multiple Entrypoints            | ❌           |
| Pausable / Blocklist            | ❌           |
| Fee-on-transfer                 | ❌           |
| ERC777 / Callback               | ❌           |
| Upward-rebasing                 | ❌           |
| Downward-rebasing               | ❌           |
| Revert on zero-value transfers  | ✅           |
| Flash mint                      | ✅           |
| Missing return values           | ✅           |
| No revert on failure            | ✅           |


## Optimistic Call Restrictions

Fast (optimistic) proposals can **only** call `(target, selector)` pairs registered in the `OptimisticSelectorRegistry`. In addition, the following targets are **always** blocked at registration time (hardcoded in `OptimisticSelectorRegistry`):

- The `StakingVault` contract (token)
- The `ReserveOptimisticGovernor` contract
- The `TimelockControllerOptimistic` contract
- The `OptimisticSelectorRegistry` itself

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
  proposeOptimistic() → [vetoDelay: PENDING] → [vetoPeriod: ACTIVE] → executeOptimistic()
                                                       │                       ↓
                                                       │                   SUCCEEDED
                                                       │                       ↓
                                                       │                   EXECUTED (bypass)
                                                       │
                                                       └─► [AGAINST votes reach threshold]
                                                                   │
                                                                   ▼
                                                               DEFEATED
                                                                   │
                                                                   ▼
                                                           Confirmation Vote
                                                          (standard flow below)

Slow Proposal:
  propose() → [voting delay] → [voting period] → queue() → [timelock] → execute()
```
