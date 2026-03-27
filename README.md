# Reserve Governor

A hybrid optimistic/pessimistic governance system for the Reserve protocol.

## Overview

Reserve Governor provides two proposal paths through a single timelock:

- **Fast (Optimistic)**: Quick execution after a short veto period, no affirmative voting required
- **Slow (Standard)**: Full voting process with timelock delay

During a fast proposal's veto period, token holders can vote AGAINST. If enough AGAINST votes accumulate to reach the veto threshold, the proposal automatically spawns a full confirmation vote (the slow path) under a new proposal id. This lets routine governance operate efficiently while preserving the community's ability to challenge any proposal.

Fast proposals are protected by a proposer throttle that limits how many optimistic proposals each account can create per 24-hour window.

## Architecture

The runtime system consists of five components:

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
│  │  execute            │    │  execute                        │ │
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
The allowlist is universal: selector permissions do not depend on which optimistic proposer submits the proposal.

The runtime system above is complemented by a deployment and release control plane:

- `ReserveOptimisticGovernorDeployer` deploys new systems from implementation addresses
- `ReserveOptimisticGovernanceVersionRegistry` tracks versioned deployers
- `RewardTokenRegistry` controls which ERC20s may be added as vault reward tokens
- both registries are governed through an external `RoleRegistry` interface


## Governance Flows

### Fast Proposal Lifecycle

Fast proposals use the standard OZ Governor `ProposalState` enum. During the veto period, any token holder can vote, but only `Against` votes are allowed (`For` and `Abstain` revert).

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

When AGAINST votes reach the veto threshold, the governor creates a **new** standard confirmation proposal:

1. The original optimistic proposal remains in `Defeated` state (internally marked with a sentinel veto threshold value)
2. A confirmation proposal is created with description prefix `"Confirmation For: "` and therefore a different `proposalId`
3. The confirmation proposal follows normal standard timing (`Pending` for `votingDelay`, then `Active`)
4. Voting starts fresh on the confirmation proposal (votes and `hasVoted` do **not** carry over from veto phase)

### Fast Proposal Paths

| Path | Name              | Flow                                                                                                 | Outcome                                            |
| ---- | ----------------- | ---------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| F1   | Uncontested       | Pending -> Active -> Succeeded -> Executed                                                           | Executes via timelock bypass                       |
| F2   | Vetoed, Confirmed | Pending -> Active -> Defeated -> (confirmation) Pending -> Active -> Succeeded -> Queued -> Executed | Executes via timelock                              |
| F3   | Vetoed, Rejected  | Pending -> Active -> Defeated -> (confirmation) Pending -> Active -> Defeated                        | Proposal blocked                                   |
| F4   | Canceled          | Any non-final optimistic state -> Canceled                                                           | Proposer, optimistic guardian, or EmergencyGuardian admin cancels |

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

| Path | Name            | Flow                                                 | Outcome                     |
| ---- | --------------- | ---------------------------------------------------- | --------------------------- |
| S1   | Success         | Pending -> Active -> Succeeded -> Queued -> Executed | Normal governance execution |
| S2   | Voting Defeated | Pending -> Active -> Defeated                        | Proposal rejected by voters |
| S3   | Cancellation    | Anything -> Canceled                                 | Canceled                    |

## Veto Mechanism

During a fast proposal's veto period, any token holder can vote using the standard `castVote()` interface, but only `Against` votes are allowed for optimistic proposals.

**Veto threshold calculation:**

```
vetoThreshold = ceil(vetoThresholdRatio * pastTotalSupply / 1e18)
```

Where `pastTotalSupply = token.getPastTotalSupply(snapshot)` and `vetoThresholdRatio` is a D18 fraction (e.g. `0.1e18` = 10%).

If the veto threshold is reached, the proposal is Defeated and automatically transitions to a confirmation vote via a new proposal id. If the veto period expires without reaching the threshold, the proposal Succeeds and can be executed immediately via timelock bypass. If the snapshot `pastTotalSupply` is zero (so computed threshold in tokens is zero), the optimistic proposal resolves to `Canceled`.

## Proposal Kind Detection

Use `isOptimistic(proposalId)` to determine if a proposal is optimistic or standard. The result cannot change over the lifetime of a proposal.

## Roles

| Role                       | Held By                                                   | Permissions                                                             |
| -------------------------- | --------------------------------------------------------- | ----------------------------------------------------------------------- |
| `OPTIMISTIC_PROPOSER_ROLE` | Designated proposer EOAs                                  | Create fast proposals (`proposeOptimistic`)                             |
| `OPTIMISTIC_GUARDIAN_ROLE` | Designated optimistic guardian addresses on `EmergencyGuardian` | Cancel non-defeated optimistic proposals through `EmergencyGuardian`             |
| `PROPOSER_ROLE`            | Governor contract                                         | Schedule operations on the timelock (granted automatically by Deployer) |
| `EXECUTOR_ROLE`            | Governor contract                                         | Execute timelock operations for both slow and fast proposal paths       |
| `CANCELLER_ROLE`           | Governor contract + shared `EmergencyGuardian`                     | Cancel proposals (fast or slow), revoke optimistic proposers            |

**IMPORTANT**: Roles held exclusively by the Governor contract (`PROPOSER_ROLE`/`EXECUTOR_ROLE`) should NEVER be granted to other addresses. This could result in executing actions through the timelock without a delay.

> **Note:** Standard (slow) proposals are created via `propose()` by any account meeting `proposalThreshold`. The `PROPOSER_ROLE` on the timelock is held by the governor contract itself -- it allows the governor to schedule operations, not individual users to create proposals.

> **EmergencyGuardian Architecture:** Each governance timelock grants its only external `CANCELLER_ROLE` to a shared `EmergencyGuardian` singleton. That `EmergencyGuardian` uses `DEFAULT_ADMIN_ROLE` for full emergency-guardian authority and `OPTIMISTIC_GUARDIAN_ROLE` for optimistic-only bot keys. Rotating optimistic guardian keys therefore only requires updating the shared `EmergencyGuardian`, not each governance instance. Separately, `RoleRegistry` may still model an `EmergencyCouncil` that serves as an admin/controller for the shared `EmergencyGuardian`.

#### OPTIMISTIC_PROPOSER_ROLE

The `OPTIMISTIC_PROPOSER_ROLE` is managed on the timelock via standard AccessControl:

- Granted via `timelock.grantRole(OPTIMISTIC_PROPOSER_ROLE, address)`
- Revoked via `timelock.revokeRole(OPTIMISTIC_PROPOSER_ROLE, address)` or `timelock.revokeOptimisticProposer(address)` (callable by `CANCELLER_ROLE`, which is held externally by `EmergencyGuardian`)
- Checked via `timelock.hasRole(OPTIMISTIC_PROPOSER_ROLE, address)`
- Revocation blocks new `proposeOptimistic()` calls by that account
- Execution of a succeeded optimistic proposal is done via `execute(...)` and is not restricted to the original optimistic proposer

#### OPTIMISTIC_GUARDIAN_ROLE

The `OPTIMISTIC_GUARDIAN_ROLE` is managed on the shared `EmergencyGuardian` via standard `AccessControlEnumerable`:

- Granted via `emergencyGuardian.grantRole(OPTIMISTIC_GUARDIAN_ROLE, address)`
- Revoked via `emergencyGuardian.revokeRole(OPTIMISTIC_GUARDIAN_ROLE, address)`
- Checked via `emergencyGuardian.hasRole(OPTIMISTIC_GUARDIAN_ROLE, address)`
- Allows calling `emergencyGuardian.cancel(...)` for optimistic proposals in any non-defeated state
- Does NOT allow canceling ordinary standard proposals or pending confirmation proposals
- Does NOT allow `revokeOptimisticProposer()`; that remains restricted to `DEFAULT_ADMIN_ROLE` on `EmergencyGuardian`

#### CANCELLER_ROLE

The `CANCELLER_ROLE` is granted on each timelock to the governor contract and the shared `EmergencyGuardian`. `EmergencyGuardian`'s `DEFAULT_ADMIN_ROLE` holders are expected to revoke an optimistic proposer if they become malicious or otherwise compromised. This includes directly proposing malicious proposals as well as indirect griefing actions such as stuffing a proposal with excess data to increase the gas cost of veto actions.

## Contract Reference

### ReserveOptimisticGovernor

The main hybrid governor contract.

**Fast Proposal Functions:**

- `proposeOptimistic(targets, values, calldatas, description)` -- Create a fast proposal (requires `OPTIMISTIC_PROPOSER_ROLE`)
- `execute(targets, values, calldatas, descriptionHash)` -- Execute a succeeded fast proposal (bypass path, no queue step)

**Standard Proposal Functions (inherited from OZ Governor):**

- `propose(targets, values, calldatas, description)` -- Create a standard proposal (requires `proposalThreshold`)
- `castVote(proposalId, support)` -- Cast a vote (works on both fast and slow proposals; optimistic proposals only allow `support = 0` / `Against`)
- `queue(targets, values, calldatas, descriptionHash)` -- Queue a succeeded standard proposal (optimistic proposals cannot be queued)
- `execute(targets, values, calldatas, descriptionHash)` -- Execute a queued standard proposal or a succeeded optimistic proposal
- `cancel(targets, values, calldatas, descriptionHash)` -- Cancel a proposal (`CANCELLER_ROLE` can cancel any proposal; the original proposer can cancel pending standard proposals; the original proposer can cancel optimistic proposals directly; `EmergencyGuardian` may forward emergency-guardian cancellations)

**Proposal Creation Rules:**

- `proposeOptimistic()` consumes proposer throttle charge
- `propose()` rejects non-empty calldata calls to EOAs (`InvalidCall`) but allows pure ETH transfers to EOAs with empty calldata
- `proposeOptimistic()` requires each target to be a deployed contract and each calldata entry to include at least a selector (>=4 bytes)
- `proposeOptimistic()` requires `OPTIMISTIC_PROPOSER_ROLE` and each `(target, selector)` to be allowlisted in `OptimisticSelectorRegistry`

**State Query:**

- `isOptimistic(proposalId)` -- Returns whether proposal is optimistic metadata
- `state(proposalId)` -- Returns `ProposalState` (unified for both types)
- `vetoThreshold(proposalId)` -- Returns the veto threshold for an optimistic proposal (0 if standard)
- `selectorRegistry()` -- The OptimisticSelectorRegistry contract address
- `proposalNeedsQueuing(proposalId)` -- Always `false` for optimistic proposals

**Configuration:**

- `setOptimisticParams(params)` -- Update optimistic governance parameters (onlyGovernance)
- `setProposalThrottle(capacity)` -- Update optimistic proposals-per-24h throttle capacity (onlyGovernance)
- `proposalThrottleCapacity()` -- Read current throttle capacity

### OptimisticSelectorRegistry

Whitelist of allowed `(target, selector)` pairs for optimistic proposals. Controlled by the timelock (governance-controlled).

**Management (onlyTimelock):**

- `registerSelectors(SelectorData[])` -- Add allowed `(target, selector)` pairs
- `unregisterSelectors(SelectorData[])` -- Remove allowed pairs; does NOT impact existing optimistic proposals

**Query:**

- `isAllowed(target, selector)` -- Check if a `(target, selector)` tuple is whitelisted
- `targets()` -- List all targets that have at least one registered selector
- `selectorsAllowed(target)` -- List all allowed selectors for a given target

**Constraints:**

- Cannot register itself as a target
- The governor, timelock, and StakingVault (token) are additionally blocked as targets

### TimelockControllerOptimistic

Extended timelock supporting both flows.

- Slow proposals use standard `scheduleBatch()` + `executeBatch()`
- Fast proposals use `executeBatchBypass()` for immediate execution (governor must hold `PROPOSER_ROLE` and `EXECUTOR_ROLE`)
- `revokeOptimisticProposer(account)` -- Revoke an optimistic proposer (requires `CANCELLER_ROLE`)
- In production wiring, the only external `CANCELLER_ROLE` holder should be the shared `EmergencyGuardian`
- UUPS upgradeable; `_authorizeUpgrade()` only allows self-calls from the timelock proxy itself

### EmergencyGuardian

Shared emergency guardian contract intended to be the sole external `CANCELLER_ROLE` holder across all timelocks.

- Uses `DEFAULT_ADMIN_ROLE` for full emergency-guardian authority
- Uses `OPTIMISTIC_GUARDIAN_ROLE` for optimistic-only guardian bot keys
- `cancel(governor, targets, values, calldatas, descriptionHash)` -- Forward a cancellation to a governor:
  - `DEFAULT_ADMIN_ROLE` may cancel any proposal that the timelock emergency guardian can cancel
  - `OPTIMISTIC_GUARDIAN_ROLE` may only cancel optimistic proposals, and not once they are `Defeated`
- `revokeOptimisticProposer(governor, account)` -- Revoke an optimistic proposer through the target governor's timelock (`DEFAULT_ADMIN_ROLE` only)
- Role management is standard `AccessControlEnumerable`:
  - `DEFAULT_ADMIN_ROLE` is self-admin
  - `OPTIMISTIC_GUARDIAN_ROLE` is administered by `DEFAULT_ADMIN_ROLE`

### ReserveOptimisticGovernorDeployer

Versioned factory for full system deployments.

- Stores immutable pointers to `versionRegistry`, `rewardTokenRegistry`, `emergencyGuardian`, `stakingVaultImpl`, `governorImpl`, `timelockImpl`, and `selectorRegistryImpl`
- `deployWithNewStakingVault(baseParams, newStakingVaultParams, deploymentNonce)` -- Deploy a new `StakingVault` proxy and the timelock/governor/selector-registry stack
- `deployWithExistingStakingVault(baseParams, existingStakingVault, deploymentNonce)` -- Deploy the timelock/governor/selector-registry stack around an already deployed vault
- During deployment, grants `CANCELLER_ROLE` on each timelock to the governor contract and the shared `EmergencyGuardian`
- `BaseDeploymentParams` includes optimistic proposers but no per-instance emergency-guardian or optimistic-guardian address lists; optimistic guardian management is centralized in `EmergencyGuardian`

### RewardTokenRegistry

Governance-owned registry of tokens that may be used as `StakingVault` reward tokens. 

- `registerRewardToken(rewardToken)` -- Register a reward token (owner only)
- `unregisterRewardToken(rewardToken)` -- Unregister a reward token (owner or `EmergencyCouncil` via `RoleRegistry`)
- `getAllRewardTokens()` -- Return all reward tokens, even those not registered with the registry anymore
- `getAllRegisteredRewardTokens()` -- Return all reward tokens registered with the registry
- `isRegistered(rewardToken)` -- Check whether a token is currently in the registry

### ReserveOptimisticGovernanceVersionRegistry

Governance-owned registry of release versions.

- `registerVersion(deployer)` -- Register a new deployer version (owner only)
- `deprecateVersion(versionHash)` -- Mark a version as deprecated (owner or `EmergencyCouncil` via `RoleRegistry`)
- `getLatestVersion()` -- Return the latest registered version metadata
- `getImplementationsForVersion(versionHash)` -- Resolve the upgradeable implementation set for a version

### StakingVault

ERC4626 vault with vote-locking and multi-token rewards. Users deposit tokens to receive vault shares that carry voting power.

**User Functions:**

- `depositAndDelegate(assets)` -- Deposit tokens and self-delegate voting power
- `claimRewards(rewardTokens[])` -- Claim accumulated rewards for specified reward tokens
- `poke()` -- Trigger reward accrual without performing an action

**Admin Functions (DEFAULT_ADMIN_ROLE):**

- `addRewardToken(rewardToken)` -- Add a new reward token for distribution
- `removeRewardToken(rewardToken)` -- Remove a reward token from distribution
- `setUnstakingDelay(delay)` -- Set the delay before unstaked tokens can be claimed
- `setRewardRatio(rewardHalfLife)` -- Set the exponential decay half-life for reward distribution

**Other:**

- `getAllRewardTokens()` -- Return all active reward tokens
- `rewardTokenRegistry()` -- Reward token registry wired in during initialization
- `versionRegistry()` -- Version registry wired in during initialization

**Properties:**

- UUPS upgradeable by `DEFAULT_ADMIN_ROLE`, but only to the exact latest non-deprecated staking-vault implementation registered in `ReserveOptimisticGovernanceVersionRegistry`
- Clock: timestamp-based (ERC5805)
- Creates an `UnstakingManager` during initialization
- `addRewardToken()` only accepts tokens that are currently registered in `RewardTokenRegistry`

#### Token Support

| Feature                        | Supported |
| ------------------------------ | --------- |
| Multiple Entrypoints           | ❌        |
| Pausable / Blocklist           | ❌        |
| Fee-on-transfer                | ❌        |
| ERC777 / Callback              | ❌        |
| Upward-rebasing                | ❌        |
| Downward-rebasing              | ❌        |
| Revert on zero-value transfers | ✅        |
| Flash mint                     | ✅        |
| Missing return values          | ✅        |
| No revert on failure           | ✅        |

#### Valid Ranges

StakingVault asset tokens and reward tokens are assumed to be maximum 1e36 supply and up to 21 decimals.

#### Governance Guidelines

If governance removes a reward token via `removeRewardToken()`, that token is disallowed from being re-added. Users can still claim already accrued rewards for removed/disallowed reward tokens via `claimRewards()`.

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

| Parameter       | Type      | Description                                             |
| --------------- | --------- | ------------------------------------------------------- |
| `vetoDelay`     | `uint48`  | Delay before veto voting starts (seconds)               |
| `vetoPeriod`    | `uint32`  | Duration of veto window (seconds)                       |
| `vetoThreshold` | `uint256` | Fraction of supply needed to trigger confirmation (D18) |

### Standard Governance Parameters

| Parameter           | Type      | Description                                |
| ------------------- | --------- | ------------------------------------------ |
| `votingDelay`       | `uint48`  | Delay before voting snapshot               |
| `votingPeriod`      | `uint32`  | Duration of voting window                  |
| `voteExtension`     | `uint48`  | Late quorum time extension                 |
| `proposalThreshold` | `uint256` | Fraction of supply needed to propose (D18) |
| `quorumNumerator`   | `uint256` | Fraction of supply needed for quorum (D18) |

### Proposal Throttle Parameter

| Parameter                  | Type      | Description                                   |
| -------------------------- | --------- | --------------------------------------------- |
| `proposalThrottleCapacity` | `uint256` | Max optimistic proposals per proposer per 24h |

### Parameter Constraints

| Parameter                  | Constraint                               | Constant                                            |
| -------------------------- | ---------------------------------------- | --------------------------------------------------- |
| `vetoDelay`                | >= 1 second and < `MAX_OPTIMISTIC_DELAY` | `MIN_OPTIMISTIC_VETO_DELAY`, `MAX_OPTIMISTIC_DELAY` |
| `vetoPeriod`               | >= 15 minutes                            | `MIN_OPTIMISTIC_VETO_PERIOD`                        |
| `vetoThreshold`            | > 0 and <= 100%                          |                                                     |
| `proposalThrottleCapacity` | >= 1 and <= 10 proposals/day             | `MAX_PROPOSAL_THROTTLE_CAPACITY`                    |
| `votingDelay`              | < `MAX_OPTIMISTIC_DELAY`                 | `MAX_OPTIMISTIC_DELAY`                              |
| `proposalThreshold`        | > 0 and <= 100%                          |                                                     |

### Proposal Throttle Behavior

- Throttle is tracked per proposer account for `proposeOptimistic()`
- Capacity is measured as proposals per 24 hours
- Each optimistic proposal consumes one unit of capacity
- Capacity recharges linearly over time (full recharge over 24 hours)

### StakingVault Parameters

| Parameter        | Constraint       | Constant                                       |
| ---------------- | ---------------- | ---------------------------------------------- |
| `unstakingDelay` | <= 4 weeks       | `MAX_UNSTAKING_DELAY`                          |
| `rewardHalfLife` | 1 day to 2 weeks | `MIN_REWARD_HALF_LIFE`, `MAX_REWARD_HALF_LIFE` |

## Optimistic Call Restrictions

Fast (optimistic) proposals can **only** call `(target, selector)` pairs registered in the `OptimisticSelectorRegistry`. In addition, the following targets are **always** blocked at registration time (hardcoded in `OptimisticSelectorRegistry`):

- The `StakingVault` contract (token)
- The `ReserveOptimisticGovernor` contract
- The `TimelockControllerOptimistic` contract
- The `OptimisticSelectorRegistry` itself

Any governance changes to the system itself must go through the slow proposal path with full community voting.

Additional optimistic validations:

- Every optimistic target must be a contract (no EOAs)
- Every optimistic calldata entry must be non-empty (>= 4 bytes selector)

## Upgradeability

Three contracts are UUPS upgradeable, but they do not share a central onchain upgrade manager.

| Contract                       | Upgrade Authorization                                         | Additional Guardrail |
| ------------------------------ | ------------------------------------------------------------- | -------------------- |
| `StakingVault`                 | `DEFAULT_ADMIN_ROLE`                                | Upgrade must be executed through the timelock via standard governance path AND update StakingVault to latest release |
| `ReserveOptimisticGovernor`    | `onlyGovernance`                                              | Upgrade must be executed through the timelock via standard governance path |
| `TimelockControllerOptimistic` | `DEFAULT_ADMIN_ROLE`                                | Upgrade must be executed through the timelock via standard governance path            |

`OptimisticSelectorRegistry` is clone-initialized and is not upgradeable.

### Version Registry (StakingVault)

`ReserveOptimisticGovernanceVersionRegistry` stores versions by deployer, not by a raw implementation tuple. Only `StakingVault` upgrades are currently tied to the version registry. 

- `registerVersion(deployer)` can only be called by a `RoleRegistry` owner
- `getLatestVersion()` returns the latest registered version metadata
- `getImplementationsForVersion(versionHash)` resolves the staking vault, governor, and timelock implementations from the registered deployer
- `deprecateVersion(versionHash)` can be called by a `RoleRegistry` owner or `EmergencyCouncil`

### Upgrade Flows

> New `StakingVault` implementations MUST remain backwards compatible with older `ReserveOptimisticGovernor` and `TimelockControllerOptimistic` implementations. Functionality should NOT be removed.


Upgrades are intended to be executed by the existing vault admin. They cannot be routed through the optimistic path. 

1. Deploy new implementations and a new versioned `ReserveOptimisticGovernorDeployer` pointing at those implementation addresses plus the shared `EmergencyGuardian`, version registry, and reward-token registry.
2. Register that deployer in `ReserveOptimisticGovernanceVersionRegistry` from a `RoleRegistry` owner account.
3. Apply upgrades per component:
   1. `StakingVault`: call `upgradeToAndCall(newStakingVaultImpl, data)` from `DEFAULT_ADMIN_ROLE` (usually timelock). The `newStakingVaultImpl.version()` must be the latest registered (non-deprecated) version.
   2. `ReserveOptimisticGovernor`: call `governor.upgradeToAndCall(newGovernorImpl, data)` from timelock.
   3. `TimelockControllerOptimistic`: call `timelock.upgradeToAndCall(newTimelockImpl, data)` from timelock.

Only the `StakingVault` upgrade path is constrained by the version registry. This guarantees that `StakingVault` governance cannot brick the other governors that also depend on the same `StakingVault`. However, each `ReserveOptimisticGovernor` and `TimelockControllerOptimistic` depending on a StakingVault (or governing it) can be broken either via role changes or by upgrading to a malicious implementation. 

For deployments created with `deployWithExistingStakingVault()`, the new timelock does not automatically become the existing vault's admin. Any later `StakingVault` upgrade is still controlled by whichever address currently holds that vault's `DEFAULT_ADMIN_ROLE`.


## Flow Summary

```
Fast Proposal:
  proposeOptimistic() -> [vetoDelay: PENDING] -> [vetoPeriod: ACTIVE]
                                                    |
                                                    +-- threshold not met --> SUCCEEDED -> execute() -> EXECUTED (bypass)
                                                    |
                                                    +-- threshold reached --> DEFEATED (original)
                                                                                -> Confirmation Proposal (new id)
                                                                                -> [voting delay: PENDING]
                                                                                -> [voting period: ACTIVE]
                                                                                -> queue() -> [timelock] -> execute()

Slow Proposal:
  propose() -> [voting delay] -> [voting period] -> queue() -> [timelock] -> execute()
```
