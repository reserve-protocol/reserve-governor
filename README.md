

A hybrid optimistic/pessimistic governance system for the Reserve protocol.

## Overview

Reserve Governor provides two proposal paths through a single timelock:

- **Fast (Optimistic)**: Quick execution after a short veto period, no affirmative voting required
- **Slow (Standard)**: Full voting process with timelock delay

During a fast proposal's veto period, token holders can vote AGAINST. If enough AGAINST votes accumulate to reach the veto threshold, the proposal automatically spawns a full confirmation vote (the slow path) under a new proposal id. This lets routine governance operate efficiently while preserving the community's ability to challenge any proposal.

Proposals are protected by a shared per-account throttle. Both proposal paths consume the same refillable proposal-count bucket. Standard proposals also require sufficient delegated standard voting power now and a 12-hour average voting weight normalized by average total supply (see [Proposal Throttle Behavior](#proposal-throttle-behavior)).

The shared `Versioned` mixin reports `1.1.0`. See [CHANGELOG.md](CHANGELOG.md) for release changes and upgrade notes.

## Architecture

The runtime system consists of five components:

1. **StakingVault** -- ERC4626 vault with vote-locking, dual delegation (standard + optimistic), multi-token rewards, and unstaking delay
2. **UnstakingManager** -- Time-locked withdrawal manager created by StakingVault during initialization
3. **ReserveOptimisticGovernor** -- Hybrid governor unifying optimistic/standard proposal flows in shared OZ Governor storage
4. **OptimisticSelectorRegistry** -- Whitelist of allowed `(target, selector)` pairs for optimistic proposals
5. **TimelockControllerOptimistic** -- Single timelock for execution, with bypass for the optimistic path

```
┌──────────────────────────────────┐
│          StakingVault            │
│  ERC4626 + ERC20Votes            │
│                                  │
│  deposit / withdraw              │
│  delegate / delegateOptimistic   │
│  claimRewards                    │
│  ┌────────────────────────────┐  │
│  │     UnstakingManager       │  │
│  │  createLock / claimLock    │  │
│  │  cancelLock                │  │
│  └────────────────────────────┘  │
└───────────────┬──────────────────┘
                │ (voting token)
                ▼
┌─────────────────────────────────────────────────────────────────┐
│                  ReserveOptimisticGovernor                      │
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
│  OptimisticSelectorRegistry    │  │  TimelockControllerOptimistic │
│                                │  │                               │
│  Allowed (target,              │  │  Fast: executeBatchBypass()   │
│   selector) pairs              │  │  Slow: scheduleBatch()        │
└────────────────────────────────┘  └───────────────────────────────┘
```

The governor checks each call in an optimistic proposal against the `OptimisticSelectorRegistry` before creating it. Only whitelisted `(target, selector)` pairs are permitted.
The allowlist is universal: selector permissions do not depend on which optimistic proposer submits the proposal.

## Dual Delegation Model

`StakingVault` tracks two independent delegation ledgers against the same vault share balance:

- **Standard delegation** uses the inherited OZ `ERC20Votes` checkpoints and powers slow proposals, quorum, and ordinary `getVotes()` lookups
- **Optimistic delegation** uses dedicated optimistic checkpoints and powers fast proposal veto voting through `getOptimisticVotes()`

This means a holder can route standard governance and optimistic veto authority to different delegatees:

- `deposit()` mints shares without assigning either delegation stream
- `depositAndDelegate()` mints shares and delegates both streams
- `delegate()` and `delegateOptimistic()` can point at different addresses
- Share transfers move both standard and optimistic voting weight according to each account's current delegatees
- `delegateOptimisticBySig()` provides signature-based optimistic delegation

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

Creating the confirmation proposal consumes no additional throttle charge and bypasses proposer threshold and average-vote checks. Vetoes therefore still create confirmation proposals when the optimistic proposer's bucket is empty or they have no standard votes.

### Fast Proposal Paths

| Path | Name              | Flow                                                                                                 | Outcome                                            |
| ---- | ----------------- | ---------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| F1   | Uncontested       | Pending -> Active -> Succeeded -> Executed                                                           | Executes via timelock bypass                       |
| F2   | Vetoed, Confirmed | Pending -> Active -> Defeated -> (confirmation) Pending -> Active -> Succeeded -> Queued -> Executed | Executes via timelock                              |
| F3   | Vetoed, Rejected  | Pending -> Active -> Defeated -> (confirmation) Pending -> Active -> Defeated                        | Proposal blocked                                   |
| F4   | Canceled          | Any non-final optimistic state -> Canceled                                                           | Proposer, optimistic guardian, or Guardian admin cancels |

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

During a fast proposal's veto period, any token holder can vote using the standard `castVote()` interface, but only `Against` votes are allowed for optimistic proposals. Fast proposals count weight from the vault's optimistic delegation checkpoints (`getPastOptimisticVotes()`), while slow proposals continue to use the standard `ERC20Votes` checkpoints.

**Veto threshold calculation:**

```
vetoThreshold = max(floor(vetoThresholdRatio * pastTotalSupply / 1e18), 1)
```

Where `pastTotalSupply = token.getPastTotalSupply(snapshot)` and `vetoThresholdRatio` is a D18 fraction (e.g. `0.1e18` = 10%). The minimum of one token quantum applies only when `pastTotalSupply` is nonzero.

If the veto threshold is reached, the proposal is Defeated and automatically transitions to a confirmation vote via a new proposal id. If the veto period expires without reaching the threshold, the proposal Succeeds and can be executed immediately via timelock bypass. If the snapshot `pastTotalSupply` is zero, the optimistic proposal resolves to `Canceled` before calculating the token threshold.

## Proposal Kind Detection

Use `isOptimistic(proposalId)` to determine if a proposal is optimistic or standard. The result cannot change over the lifetime of a proposal.

## Roles

| Role                       | Held By                                                   | Permissions                                                             |
| -------------------------- | --------------------------------------------------------- | ----------------------------------------------------------------------- |
| `OPTIMISTIC_PROPOSER_ROLE` | Designated proposer EOAs                                  | Create fast proposals (`proposeOptimistic`)                             |
| `OPTIMISTIC_GUARDIAN_MANAGER_ROLE` | Designated guardian manager addresses on `Guardian` | Grant new optimistic guardian addresses through `Guardian`              |
| `OPTIMISTIC_GUARDIAN_ROLE` | Designated optimistic guardian addresses on `Guardian` | Cancel non-defeated optimistic proposals through `Guardian`             |
| `PROPOSER_ROLE`            | Governor contract                                         | Schedule operations on the timelock (granted automatically by Deployer) |
| `EXECUTOR_ROLE`            | Governor contract                                         | Execute timelock operations for both slow and fast proposal paths       |
| `CANCELLER_ROLE`           | Governor contract + shared `Guardian` + optional deployment-specific cancellers | Cancel proposals (fast or slow), revoke optimistic proposers |

**IMPORTANT**: Roles held exclusively by the Governor contract (`PROPOSER_ROLE`/`EXECUTOR_ROLE`) should NEVER be granted to other addresses. This could result in executing actions through the timelock without a delay.

> **Note:** Standard (slow) proposals are created via `propose()` by any account meeting the vote-power eligibility checks with a shared throttle charge available. The `PROPOSER_ROLE` on the timelock is held by the governor contract itself -- it allows the governor to schedule operations, not individual users to create proposals.

> **Guardian Architecture:** Each governance timelock grants `CANCELLER_ROLE` to a shared `Guardian` singleton. A deployment may also grant the role directly to additional per-instance cancellers. The shared `Guardian` uses `DEFAULT_ADMIN_ROLE` for break-glass authority, `OPTIMISTIC_GUARDIAN_MANAGER_ROLE` for routine optimistic guardian additions, and `OPTIMISTIC_GUARDIAN_ROLE` for optimistic-only bot keys. Rotating optimistic guardian keys therefore only requires updating the shared `Guardian`, not each governance instance. Separately, `RoleRegistry` may still model an emergency council that serves as an admin/controller for the shared `Guardian`.

#### OPTIMISTIC_PROPOSER_ROLE

The `OPTIMISTIC_PROPOSER_ROLE` is managed on the timelock via standard AccessControl:

- Granted via `timelock.grantRole(OPTIMISTIC_PROPOSER_ROLE, address)`
- Revoked via the standard `timelock.revokeRole(OPTIMISTIC_PROPOSER_ROLE, address)` governance path
- Revoked by any `CANCELLER_ROLE` holder via `timelock.revokeOptimisticProposer(address)`, including the shared `Guardian` and optional deployment-specific cancellers
- Checked via `timelock.hasRole(OPTIMISTIC_PROPOSER_ROLE, address)`
- Revocation blocks new `proposeOptimistic()` calls by that account
- Execution of a succeeded optimistic proposal is done via `execute(...)` and is not restricted to the original optimistic proposer

#### OPTIMISTIC_GUARDIAN_MANAGER_ROLE

The `OPTIMISTIC_GUARDIAN_MANAGER_ROLE` is managed on the shared `Guardian` via standard `AccessControlEnumerable`:

- Granted via standard role management on `Guardian`
- Checked via `guardian.hasRole(OPTIMISTIC_GUARDIAN_MANAGER_ROLE, address)`
- Allows calling `guardian.grantOptimisticGuardian(address)` to add a new `OPTIMISTIC_GUARDIAN_ROLE`
- Does NOT allow `revokeRole(OPTIMISTIC_GUARDIAN_ROLE, address)`; that remains restricted to `DEFAULT_ADMIN_ROLE` on `Guardian`
- Does NOT allow `cancel(...)` or `revokeOptimisticProposer(...)`

#### OPTIMISTIC_GUARDIAN_ROLE

The `OPTIMISTIC_GUARDIAN_ROLE` is managed on the shared `Guardian` via `AccessControlEnumerable` plus a dedicated manager-only grant helper:

- Granted via `guardian.grantOptimisticGuardian(address)` (callable by `OPTIMISTIC_GUARDIAN_MANAGER_ROLE`)
- Revoked via `guardian.revokeRole(OPTIMISTIC_GUARDIAN_ROLE, address)` (callable by `DEFAULT_ADMIN_ROLE`)
- Checked via `guardian.hasRole(OPTIMISTIC_GUARDIAN_ROLE, address)`
- Allows calling `guardian.cancel(...)` for optimistic proposals in any non-defeated state
- Does NOT allow canceling ordinary standard proposals or pending confirmation proposals
- Does NOT allow `revokeOptimisticProposer()`; that remains restricted to `DEFAULT_ADMIN_ROLE` on `Guardian`

#### CANCELLER_ROLE

The `CANCELLER_ROLE` is granted on each timelock to the governor contract and the shared `Guardian`. Deployments may also grant it directly to addresses in `BaseDeploymentParams.additionalGuardians`. Direct additional cancellers have the full timelock role: they can cancel fast or slow proposals and revoke optimistic proposers; they are not restricted like `OPTIMISTIC_GUARDIAN_ROLE` holders on the shared `Guardian`. `Guardian`'s `DEFAULT_ADMIN_ROLE` holders are expected to revoke an optimistic proposer if they become malicious or otherwise compromised. This includes directly proposing malicious proposals as well as indirect griefing actions such as stuffing a proposal with excess data to increase the gas cost of veto actions.

## Contract Reference

### ReserveOptimisticGovernor

The main hybrid governor contract.

**Fast Proposal Functions:**

- `proposeOptimistic(targets, values, calldatas, description)` -- Create a fast proposal (requires `OPTIMISTIC_PROPOSER_ROLE` and a shared throttle charge)
- `execute(targets, values, calldatas, descriptionHash)` -- Execute a succeeded fast proposal (bypass path, no queue step)

**Standard Proposal Functions (inherited from OZ Governor):**

- `propose(targets, values, calldatas, description)` -- Create a standard proposal (requires current and historical vote-power eligibility plus a shared throttle charge)
- `castVote(proposalId, support)` -- Cast a vote (works on both fast and slow proposals; optimistic proposals only allow `support = 0` / `Against`)
- `queue(targets, values, calldatas, descriptionHash)` -- Queue a succeeded standard proposal (optimistic proposals cannot be queued)
- `execute(targets, values, calldatas, descriptionHash)` -- Execute a queued standard proposal or a succeeded optimistic proposal
- `cancel(targets, values, calldatas, descriptionHash)` -- Cancel a proposal (`CANCELLER_ROLE` can cancel any proposal; the original proposer can cancel pending standard proposals; the original proposer can cancel optimistic proposals directly; `Guardian` may forward guardian cancellations)

**Proposal Creation Rules:**

- `proposeOptimistic()` and `propose()` consume charges from the same per-account bucket
- `propose()` checks standard votes at `block.timestamp - 1` and the preceding 12-hour vote average against the current `proposalThreshold()`
- `propose()` rejects non-empty calldata calls to EOAs (`InvalidCall`) but allows pure ETH transfers to EOAs with empty calldata
- `proposeOptimistic()` requires each target to be a deployed contract and each calldata entry to include at least a selector (>=4 bytes)
- `proposeOptimistic()` requires `OPTIMISTIC_PROPOSER_ROLE` and each `(target, selector)` to be allowlisted in `OptimisticSelectorRegistry`

**State Query:**

- `isOptimistic(proposalId)` -- Returns whether proposal is optimistic metadata
- `state(proposalId)` -- Returns `ProposalState` (unified for both types)
- `vetoThreshold(proposalId)` -- Returns the veto threshold for an optimistic proposal (0 if standard)
- `getOptimisticVotes(account, timepoint)` -- Read the optimistic voting weight used for fast-proposal veto voting
- `selectorRegistry()` -- The OptimisticSelectorRegistry contract address
- `proposalNeedsQueuing(proposalId)` -- Always `false` for optimistic proposals

**Configuration:**

- `setOptimisticParams(params)` -- Update optimistic governance parameters (onlyGovernance)
- `setProposalThrottle(capacity)` -- Update the shared proposal-count throttle capacity (onlyGovernance; accepts 1 through 12)
- `proposalThrottleCapacity()` -- Read the current throttle capacity
- `proposalThrottleCharges(account)` -- Read the charges currently available to an account across both proposal paths

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
- In the default production wiring, the shared `Guardian` is the external `CANCELLER_ROLE` holder; deployments may explicitly add per-instance cancellers
- UUPS upgradeable; `_authorizeUpgrade()` only allows self-calls from the timelock proxy itself

### Guardian

Shared guardian contract intended to provide the default external `CANCELLER_ROLE` holder across timelocks. Deployments can additionally configure direct per-instance cancellers.

- Uses `DEFAULT_ADMIN_ROLE` for full guardian authority
- Uses `OPTIMISTIC_GUARDIAN_MANAGER_ROLE` to grant new optimistic guardian keys
- Uses `OPTIMISTIC_GUARDIAN_ROLE` for optimistic-only guardian bot keys
- `grantOptimisticGuardian(account)` -- Grant `OPTIMISTIC_GUARDIAN_ROLE` to `account` (`OPTIMISTIC_GUARDIAN_MANAGER_ROLE` only)
- `cancel(governor, targets, values, calldatas, descriptionHash)` -- Forward a cancellation to a governor:
  - `DEFAULT_ADMIN_ROLE` may cancel any proposal that the timelock guardian can cancel
  - `OPTIMISTIC_GUARDIAN_ROLE` may only cancel optimistic proposals, and not once they are `Defeated`
- `revokeOptimisticProposer(governor, account)` -- Revoke an optimistic proposer through the target governor's timelock (`DEFAULT_ADMIN_ROLE` only)
- Role storage uses `AccessControlEnumerable`, with a dedicated grant helper for optimistic guardians:
  - `DEFAULT_ADMIN_ROLE` is self-admin
  - `OPTIMISTIC_GUARDIAN_MANAGER_ROLE` is administered by `DEFAULT_ADMIN_ROLE`
  - `OPTIMISTIC_GUARDIAN_ROLE` is administered by `DEFAULT_ADMIN_ROLE`

### ReserveOptimisticGovernorDeployer

Versioned factory for full system deployments.

- Stores immutable pointers to `versionRegistry`, `rewardTokenRegistry`, `guardian`, `stakingVaultImpl`, `governorImpl`, `timelockImpl`, and `selectorRegistryImpl`
- `deployWithNewStakingVault(baseParams, newStakingVaultParams, deploymentNonce)` -- Deploy a new `StakingVault` proxy and the timelock/governor/selector-registry stack
- `deployWithExistingStakingVault(baseParams, existingStakingVault, deploymentNonce)` -- Deploy the timelock/governor/selector-registry stack around an already deployed vault; its implementation must already support `getPastAverageVotes` for standard proposals to work
- During deployment, grants `CANCELLER_ROLE` on each timelock to the governor contract, the shared `Guardian`, and every address in `baseParams.additionalGuardians`
- `BaseDeploymentParams` includes optimistic proposers and optional direct per-instance cancellers; optimistic-only guardian management remains centralized in `Guardian`

### RewardTokenRegistry

Governance-owned registry of tokens that may be used as `StakingVault` reward tokens. 

- `registerRewardToken(rewardToken)` -- Register a reward token (owner only)
- `unregisterRewardToken(rewardToken)` -- Unregister a reward token (owner or emergency council via `RoleRegistry`)
- `getAllRewardTokens()` -- Return all reward tokens, even those not registered with the registry anymore
- `isRegistered(rewardToken)` -- Check whether a token is currently in the registry

### ReserveOptimisticGovernanceVersionRegistry

Governance-owned registry of release versions.

- `registerVersion(deployer)` -- Register a new deployer version (owner only)
- `deprecateVersion(versionHash)` -- Mark a version as deprecated (owner or emergency council via `RoleRegistry`)
- `getLatestVersion()` -- Return the latest registered version metadata
- `getImplementationsForVersion(versionHash)` -- Resolve the upgradeable implementation set for a version

### StakingVault

ERC4626 vault with vote-locking, dual delegation, and multi-token rewards. Users deposit tokens to receive vault shares that can carry separate standard and optimistic voting power.

**User Functions:**

- `depositAndDelegate(assets)` -- Deposit tokens and self-delegate both standard and optimistic voting power
- `delegate(delegatee)` -- Delegate standard voting power for slow proposals and quorum (inherited from `ERC20Votes`)
- `delegateOptimistic(delegatee)` -- Delegate optimistic voting power for fast-proposal veto voting
- `delegateOptimisticBySig(delegatee, nonce, expiry, v, r, s)` -- Signature-based optimistic delegation
- `claimRewards(rewardTokens[])` -- Claim accumulated rewards for specified reward tokens
- `poke()` -- Trigger reward accrual without performing an action

**Admin Functions (DEFAULT_ADMIN_ROLE):**

- `addRewardToken(rewardToken)` -- Add a new reward token for distribution
- `removeRewardToken(rewardToken)` -- Remove a reward token from distribution
- `setUnstakingDelay(delay)` -- Set the delay before unstaked tokens can be claimed
- `setRewardRatio(rewardHalfLife)` -- Set the exponential decay half-life for reward distribution
- `initializeAverageVotes()` -- Activate average-vote accounting once when upgrading a legacy vault

**Other:**

- `getAllRewardTokens()` -- Return all active reward tokens
- `optimisticDelegates(account)` -- Return the current optimistic delegate for an account
- `getOptimisticVotes(account)` -- Return the latest optimistic delegated voting weight
- `getPastOptimisticVotes(account, timepoint)` -- Return optimistic voting weight at a past timestamp snapshot
- `getPastAverageVotes(account, start, end)` -- Return average standard delegated votes over `[start, end)`, rounded down
- `getPastAverageSupply(start, end)` -- Return average total supply over `[start, end)`, rounded down; equal bounds return zero and reversed bounds revert
- `rewardTokenRegistry()` -- Reward token registry wired in during initialization
- `versionRegistry()` -- Version registry wired in during initialization

**Properties:**

- UUPS upgradeable by `DEFAULT_ADMIN_ROLE`, but only to the exact latest non-deprecated staking-vault implementation registered in `ReserveOptimisticGovernanceVersionRegistry`
- Clock: timestamp-based (ERC5805)
- Creates an `UnstakingManager` during initialization
- Standard and optimistic delegatees are tracked independently on the same share balance
- `addRewardToken()` only accepts tokens that are currently registered in `RewardTokenRegistry`

Standard delegated vote movements update cumulative vote-seconds through `ERC20AverageVotesUpgradeable` and the linked `VoteIntegralLib`. Mint and burn operations also update cumulative total-supply-seconds alongside the existing OZ total-supply checkpoints. `getPastAverageVotes()` and `getPastAverageSupply()` query these histories separately, dividing each integral by the requested duration. Both histories are binary-searched without walking account checkpoints. Updates at the same timestamp coalesce; history is retained indefinitely. Zero-value movements and movements between accounts with the same standard delegate do not add account checkpoints.

OZ retains its existing one-slot checkpoints (`uint48` timestamp and `uint208` votes). Companion mappings add one cumulative slot per account vote checkpoint and one per total-supply checkpoint. One namespace slot records the global activation timestamp; zero means inactive. This preserves existing vote history without duplicating timestamps or vote values. The supply cap and timestamp range bound each integral below `uint256.max`. The extension requires the block-timestamp clock used by StakingVault. See [the supply-seconds design and tradeoffs](docs/average-votes.md).

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
| `proposalThrottleCapacity` | `uint256` | Shared bucket capacity per proposer; refills fully over 12h |

### Parameter Constraints

| Parameter                  | Constraint                               | Constant                                            |
| -------------------------- | ---------------------------------------- | --------------------------------------------------- |
| `vetoDelay`                | >= 1 second and < `MAX_OPTIMISTIC_DELAY` | `MIN_OPTIMISTIC_VETO_DELAY`, `MAX_OPTIMISTIC_DELAY` |
| `vetoPeriod`               | >= 5 minutes                             | `MIN_OPTIMISTIC_VETO_PERIOD`                        |
| `vetoThreshold`            | > 0 and <= 100%                          |                                                     |
| `proposalThrottleCapacity` | >= 1 and <= 12 proposals/12h | `MAX_PROPOSAL_THROTTLE_CAPACITY`                    |
| `votingDelay`              | < `MAX_OPTIMISTIC_DELAY`                 | `MAX_OPTIMISTIC_DELAY`                              |
| `proposalThreshold`        | > 0 and <= 100%                          |                                                     |

The contract allows a `vetoPeriod` as low as 5 minutes, but this is not recommended. The lowest recommended production value is 15 minutes.

Similarly, `proposalThrottleCapacity` as high as 12 proposals/12h is allowed but not recommended.

### Proposal Throttle Behavior

- One throttle bucket is tracked per proposer account and shared across both proposal paths.
- A full bucket permits a burst of `capacity` proposals. It recharges linearly at `capacity` proposals per 12 hours; this is not a strict cap on every rolling 12-hour window.
- Each successful call to `propose()` or `proposeOptimistic()` consumes one charge. A reverted proposal attempt consumes none, and canceling a proposal does not refund its charge.
- For example, with capacity 2, one optimistic proposal and one standard proposal from the same account exhaust the bucket; one charge returns after 6 hours.
- The bucket refill period and standard vote-power lookback are fixed at `PROPOSAL_THROTTLE_PERIOD` (12 hours).
- Governance can set capacity from 1 through 12; zero is rejected. There is one capacity input at deployment and no separate pessimistic configuration.
- Automatic confirmation proposals are exempt from both the throttle and proposer vote-power checks.

For a standard proposal at time `t`, the governor evaluates `proposalThreshold()` once, using the current configured supply fraction and total supply at `t - 1`. Standard votes at `t - 1` must meet that threshold. It then checks the average:

```text
start = t - PROPOSAL_THROTTLE_PERIOD
averageVotes = token.getPastAverageVotes(account, start, t)
averageSupply = token.getPastAverageSupply(start, t)
normalizedAverageVotes = floor(averageVotes * totalSupplyAt(t - 1) / averageSupply)
```

The governor compares `normalizedAverageVotes` with `proposalThreshold()`, which remains the absolute token amount calculated from the current configured fraction and supply at `t - 1`. A zero average supply fails closed. Periods with larger total supply receive proportionally larger denominator weight. The governor requests twelve hours directly; supported chain timestamps exceed that period. There is no historical-vote fallback.

Transfers and delegation changes preserve the vote-seconds each delegate actually earned; they cannot duplicate accrued credit or reset activation. Periods with larger supply contribute more denominator weight, which is the defining difference from an equal-time voting-percentage average.

This is a time-weighted share requirement, not continuous ownership of particular shares. Both fresh and upgraded vaults use the same accounting. See [Upgrading to 1.1.0](#upgrading-to-110) for activation behavior.

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
| `ReserveOptimisticGovernor`    | `onlyGovernance`                                              | Upgrade must be executed through the timelock via standard governance path and match the latest non-deprecated registry entry |
| `TimelockControllerOptimistic` | `DEFAULT_ADMIN_ROLE`                                | Upgrade must be executed through the timelock via standard governance path and match the latest non-deprecated registry entry |

`OptimisticSelectorRegistry` is clone-initialized and is not upgradeable.

### Version Registry

`ReserveOptimisticGovernanceVersionRegistry` stores versions by deployer, not by a raw implementation tuple. Upgrades for all three UUPS components are tied to the registry. Governor and timelock store the registry address in their proxy storage.

The version-registry checks performed by `ReserveOptimisticGovernor` and `TimelockControllerOptimistic` are consistency checks only. They require each proxy to use the matching governor or timelock implementation from the latest non-deprecated release, but they do not protect the governed Folio (or any other target) from an unsafe upgrade. Security for governed targets still depends on that target's own upgrade authorization and governance path.

- `registerVersion(deployer)` can only be called by a `RoleRegistry` owner
- `getLatestVersion()` returns the latest registered version metadata
- `getImplementationsForVersion(versionHash)` resolves the staking vault, governor, and timelock implementations from the registered deployer
- `deprecateVersion(versionHash)` can be called by a `RoleRegistry` owner or emergency council

### Upgrade Flows

> New `StakingVault` implementations MUST remain backwards compatible with older `ReserveOptimisticGovernor` and `TimelockControllerOptimistic` implementations. Functionality should NOT be removed.


Upgrades are intended to be executed by the existing vault admin. They cannot be routed through the optimistic path. 

1. Deploy new implementations and a new versioned `ReserveOptimisticGovernorDeployer` pointing at those implementation addresses plus the shared version and reward-token registries.
2. Register that deployer in `ReserveOptimisticGovernanceVersionRegistry` from a `RoleRegistry` owner account.
3. Apply upgrades per component:
   1. `StakingVault`: call `upgradeToAndCall(newStakingVaultImpl, data)` from `DEFAULT_ADMIN_ROLE` (usually timelock). The `newStakingVaultImpl.version()` must be the latest registered (non-deprecated) version.
   2. `ReserveOptimisticGovernor`: call `governor.upgradeToAndCall(newGovernorImpl, data)` from timelock. The implementation must be the registered governor implementation for the latest non-deprecated version.
   3. `TimelockControllerOptimistic`: call `timelock.upgradeToAndCall(newTimelockImpl, data)` from timelock. The implementation must be the registered timelock implementation for the latest non-deprecated version.

When upgrading all three components together, batch the calls in a single governance proposal and execute the `StakingVault` upgrade first; separate proposals can leave the system partially upgraded if one is cancelled or fails.

Each component must use the implementation registered for the latest non-deprecated version. This keeps the staking vault, governor, and timelock implementation set aligned across deployments.

Existing governor and timelock proxies must call their one-time `initializeVersionRegistry(versionRegistry)` reinitializer as part of the first upgrade to an implementation with these checks. Deployments created with `deployWithExistingStakingVault()` do not automatically make the new timelock the existing vault's admin; any later `StakingVault` upgrade remains controlled by its current `DEFAULT_ADMIN_ROLE` holder.

### Upgrading to 1.1.0

Upgrade the `StakingVault` before its governor, following the registration and authorization steps above. The new governor calls `getPastAverageVotes` and `getPastAverageSupply` for eligible standard proposers; a vault without those APIs makes those proposals revert. The existing-vault deployer path also requires a compatible vault implementation, but does not validate those APIs during deployment.

Activate the upgraded vault atomically by passing the new admin-only initializer to `upgradeToAndCall`:

```solidity
vault.upgradeToAndCall(newVaultImpl, abi.encodeCall(StakingVault.initializeAverageVotes, ()));
```

Fresh vaults activate during ordinary initialization. Activation is one-shot under the supported-chain assumption of positive timestamps. Zero denotes inactive accounting. If an upgrade omits this call, average-vote lookups return zero and history updates remain disabled while ordinary vote checkpoints continue. An admin can initialize later, but accrual begins at that actual activation time; earlier account activity earns no credit. The activation timestamp and activation supply are packed together so pre-activation time can contribute supply-seconds while contributing zero account vote-seconds, preserving a fail-closed warm-up.

The governor reuses the existing capacity and per-account charge state, with no additional throttle configuration or governor storage. The `reserve.storage.VotesIntegral` ERC-7201 namespace holds raw account and supply cumulative mappings plus one slot for the activation timestamp. Existing standard and optimistic checkpoints, delegation mappings, and ordinary storage retain their layouts. This supports deployed 1.0.0 vaults; earlier unreleased PR prototypes require a separate migration of their integral state.

Vote-seconds before activation count as zero, while pre-activation denominator time uses the supply captured at activation. A legacy holder with exactly the proposal threshold therefore waits twelve hours before proposing; larger holders can qualify sooner. The first movement records all time held since activation before applying the new balance. Pre-upgrade transfers and delegations cannot be replayed for proposal credit, and intervening post-activation balance dips are included in the share.

The shared `Versioned` mixin now returns `1.1.0` for the governor, vault, timelock, and deployer. Fresh governors initialize their EIP-712 domain with version `1.1.0`; upgrading an existing governor does not rewrite its stored domain version. Signature clients should read `eip712Domain()` rather than infer the signing domain from `version()`.

The build uses Solidity 0.8.33, optimizer runs 416, and `via_ir = false`. The governor runtime is 24,481 bytes and the vault runtime is 24,319 bytes, leaving 95 and 257 bytes respectively below the 24,576-byte EIP-170 limit. UnstakingManager creation runs through the linked upgrade library to preserve this headroom. Run `pnpm size` after any contract or compiler change.


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
