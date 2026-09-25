# Checkpoint-based supply-seconds eligibility

The average-vote eligibility feature in [PR #48](https://github.com/reserve-protocol/reserve-governor/pull/48)
uses existing OZ standard vote checkpoints and a linked `VoteIntegralLib`.
Standard proposals require current voting power and a 12-hour average vote
weight normalized by average total supply. Both proposal paths share the
existing proposal throttle.

## Storage and activation

`ERC20AverageVotesUpgradeable` extends OZ `ERC20VotesUpgradeable` and delegates
integral lookup/update calls to `VoteIntegralLib`. Both require a block-timestamp
clock. The library reads the fixed OZ 5.4 `openzeppelin.storage.Votes` namespace
using OZ's `VotesStorage` type. OZ continues to write standard checkpoints;
the library never changes their layout. Changes to that namespace or checkpoint
layout require compatibility review.

Standard checkpoints remain packed `uint48` timestamps plus `uint208` votes,
occupying one storage slot each. The separate ERC-7201 namespace
`reserve.storage.VotesIntegral` contains:

```solidity
mapping(address account => mapping(uint256 checkpointIndex => uint256)) cumulative;
uint48 activation; // zero means inactive
uint208 activationSupply; // packed with activation
mapping(uint256 totalSupplyCheckpointIndex => uint256) supplyCumulative;
```

The mappings store plain cumulative vote-seconds and total-supply-seconds.
Activation and the supply at activation share one additional slot for the
entire vault, with a zero activation denoting inactive accounting.
The supported chains use positive timestamps, so activation becomes nonzero
and cannot be reset. No integral offset or missing-history sentinel is
needed: every integral is zero before activation.

Fresh vaults activate during initialization. Legacy vault admins activate via
`upgradeToAndCall(newImpl, abi.encodeCall(StakingVault.initializeAverageVotes, ()))`.
The token passes its `clock()` to the library; vault callers cannot select an earlier
time or reset activation. If activation is omitted, lookups return zero and integral
updates are skipped while ordinary OZ voting checkpoints continue. Later
initialization starts accrual at that actual call's timestamp.

## Accounting and lookup

Let `a` be activation and `V(t)` an account's standard delegated votes. Its
integral is zero for `t <= a`, and otherwise the area under `V` from `a` to `t`.

Before a nonzero movement between different standard delegates, the extension
passes `clock()` to the library, which reads each affected delegate's latest OZ
checkpoint. At a later timestamp it writes the next checkpoint's integral as:

```text
previousCumulative + previousVotes * (now - max(previousTimestamp, activation))
```

The previous cumulative is naturally zero for legacy checkpoints. At the same
timestamp the existing cumulative stays unchanged, including when coalescing
with a legacy checkpoint written at activation. OZ then appends/coalesces its
voting checkpoint. An OZ failure rolls back the companion write as well.
No-op movements and optimistic checkpoints do not add account integral entries.
Mint and burn operations also settle the prior total supply into the companion
supply integral before OZ writes its total-supply checkpoint.

The token API is `getPastAverageVotes(account, start, end)`. It returns
average delegated votes over `[start, end)`, rounded down:

```text
averageVotes = floor((cumulative(end) - cumulative(start)) / (end - start))
```

`getPastAverageVotes()` validates the range, calls `VoteIntegralLib.lookup()` for
each endpoint, and subtracts and divides in the token. The cumulative endpoints
are not exposed on the token's public interface. The denominator is the full
requested duration, including time before activation.
All activation handling stays inside the token: inactive accounting and
pre-activation time contribute zero. Equal bounds return zero; reversed bounds
revert, even while inactive.

Each library cumulative lookup returns zero at/before activation or before the
first vote checkpoint. Otherwise it binary-searches the standard checkpoints
and computes:

```text
checkpointCumulative + checkpointVotes * (query - max(checkpointTimestamp, activation))
```

This lets an untouched legacy account accrue without a transfer or any storage
write: its old checkpoint supplies the balance, and elapsed time begins at
activation. Current-timestamp queries work. Future timestamps extrapolate the
latest checkpoint's votes; arithmetic overflow reverts rather than wrapping.

`getPastAverageSupply(start, end)` reads the total-supply integral and returns
average total supply rounded up over the full requested interval. Rounding up
keeps proposal eligibility conservative when the average is fractional. It
includes the supply captured at activation for pre-activation time, matching
the denominator used for eligibility. Equal bounds return zero; reversed
bounds revert.

## Proposal eligibility and upgrade behavior

The governor always calculates:

```text
start = now - 12 hours
averageVotes = token.getPastAverageVotes(account, start, now)
averageSupply = token.getPastAverageSupply(start, now)
normalizedAverageVotes = floor(averageVotes * totalSupplyAt(now - 1) / averageSupply)
```

Both `normalizedAverageVotes` and votes at `now - 1` must meet the absolute
`proposalThreshold()`. A zero average supply fails closed. The governor assumes
the chain timestamp exceeds the twelve-hour lookback.
There is no historical account-vote fallback. During the activation ramp,
pre-activation account vote-seconds are zero while the denominator uses the
supply captured at activation. This preserves the fail-closed warm-up behavior
for upgraded vaults. Periods with larger total supply receive proportionally
larger denominator weight. Larger balances may satisfy the threshold sooner.

Transfers and delegation changes preserve only the time each account actually
held its votes. For example, 100 votes moved from Alice to Bob six hours after
activation give each the corresponding average vote weight after activation.
Alice also fails the separate current-votes check. Pre-activation stake hops earn
no integral credit, and post-activation dips are included in the average. A dust
movement cannot reset activation or erase already accrued area.

Existing 1.0.0 standard and optimistic checkpoints and ordinary vault storage
retain their exact layouts. Upgrade and activate the vault before upgrading
its governor or deploying a new governor against it. The governor retains its
existing throttle capacity and charge state. Veto-triggered confirmation
proposals remain exempt from throttle and proposer eligibility checks.

This release does not migrate integral state from earlier unreleased PR
prototypes. Those require a separate migration. The four
[fork cases](../test/fork/README.md) exercise actual 1.0.0 BSC and Base vaults,
including legacy checkpoints at the exact activation timestamp.

## Bounds, size, and verification

OZ enforces nondecreasing uint48 timestamps and a uint208 voting supply cap.
The maximum integral within that clock domain is bounded by
`(2^208 - 1) * (2^48 - 1) < 2^256`. One-shot current-time activation means every
subsequent update occurs at or after activation. The private integral-update
helper uses unchecked operations under these constraints. All arithmetic in
the token's average calculation and the library's cumulative lookups remains
checked, including index arithmetic, elapsed time, extrapolation, endpoint
subtraction, and division.

Each new checkpoint uses at most one companion storage word, with no second
array length or duplicate timestamp/value history. Activation adds one slot per
vault. The linked library keeps accounting code outside the vault runtime.
Solidity 0.8.33 is used with IR disabled and 416 optimizer runs. Runtime sizes
are 24,319 bytes for the vault, 24,481 for the governor, 9,821 for ProposalLib,
and 2,602 for VoteIntegralLib. The governor has 95 bytes of EIP-170 headroom at
these settings. UnstakingManager creation runs through the linked upgrade library
to preserve this headroom. Run `pnpm size` after any contract or compiler change.

Unit tests compare arbitrary histories to a segment-sum reference clipped at
activation and the requested range. They cover reversed/empty ranges, ranges
straddling activation, zero-area intervals, same-timestamp movements, maximum
arithmetic, no-ops, redelegation, conservation, delayed initialization, reset
protection, token-clock consistency, pre-activation endpoint replay, and rollback
on an OZ failure.
Governor tests verify supply-weighted eligibility and proportionally
earlier eligibility for larger balances.

## Gas measurements

The retained [benchmark](../test/bench/AverageVotesGasBenchmark.t.sol) measures token
mutations and historical/current lookups with the configured optimizer setting:

```sh
forge test --match-contract AverageVotesGasBenchmarkTest -vv
```

It reports gross `gasleft()` differences around test-contract-to-token calls,
including CALL/calldata overhead and excluding intrinsic transaction gas and
refunds. These are not end-to-end StakingVault deposit costs. Cold measurements
cool the token address, its storage, and the linked integral library. Earlier
state transitions remain in the same Foundry execution, so storage original/dirty
accounting does not necessarily match independent transaction receipts. The
query results are average voting weights, with division included in the measured
call. Warm lookups repeat the same query immediately. The lookup fixture has 65 checkpoints;
both queries start at checkpoint 23. The historical range ends at checkpoint
33, and the current range ends ten seconds after the last checkpoint.

Legacy lookups search the full OZ checkpoint history. Results from a fixed
fixture do not characterize every history length or transaction sequence, and
measurements from earlier sentinel-based prototypes do not describe this implementation.
