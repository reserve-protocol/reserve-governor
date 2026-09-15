# Checkpoint-indexed vote integrals

This document describes the checkpoint-indexed implementation of the proposal-integral feature in [PR #48](https://github.com/reserve-protocol/reserve-governor/pull/48). It retains a small linked `VoteIntegralLib` and removes duplicate observation arrays. Governor eligibility and shared-throttle behavior are defined in that PR.

## Storage and updates

`ERC20VotesIntegralUpgradeable` extends OZ `ERC20VotesUpgradeable` and delegates
integral lookup/update calls to `VoteIntegralLib`. The library reads the fixed
OZ 5.4 `openzeppelin.storage.Votes` namespace using OZ's `VotesStorage` type.
OZ continues to write standard checkpoints; the library never changes them.
Changes to that namespace or its checkpoint layout require compatibility review.

Standard checkpoints remain packed `uint48` timestamps plus `uint208` votes,
occupying one storage slot each. The library writes a separate ERC-7201 namespace,
`reserve.storage.VotesIntegral`, containing:

```solidity
mapping(address account => mapping(uint256 checkpointIndex => uint256)) cumulative;
```

Values store the integral at that checkpoint's timestamp **plus one**. Zero
means the checkpoint has no integral history. This distinguishes an untracked
checkpoint from a tracked checkpoint with zero cumulative area, without a
separate tracking-start marker or array length.

Before a nonzero movement between different standard delegates, the extension
calls the library to read each affected delegate's latest OZ checkpoint. For a
later timestamp it stores `previousCumulative + previousVotes * elapsed` at the next checkpoint
index. At the same timestamp it leaves the existing cumulative value intact.
OZ then appends/coalesces the corresponding voting checkpoint. A failure in
OZ's movement or timestamp checks reverts the entire transaction, including the
companion write. Total-supply and optimistic checkpoints do not acquire
companion entries.

Lookup binary-searches the existing standard checkpoints. If the selected
entry is untracked, it returns zero. Otherwise it removes the sentinel and
adds the checkpoint's votes times the elapsed time. Current-timestamp queries
work. Like the preceding implementation, future timestamps extrapolate the
latest votes; arithmetic overflow now reverts instead of wrapping.

## Upgrade behavior

Existing 1.0.0 standard and optimistic checkpoints and ordinary vault storage
retain their exact layouts. Adding `cumulative` directly to OZ's checkpoint
struct would change array-element stride and cannot preserve those histories.

Existing delegates remain untracked until their first real vote movement.
The first cumulative entry is one (zero area). This also works if the movement
coalesces into a checkpoint written by the old implementation at the same
timestamp. Earlier history is not backfilled. No-op delegation and zero-value
movements do not start tracking. No reinitializer is needed.

This release does **not** migrate integral arrays from the earlier, unreleased
observation-array prototype that was previously developed in #48. If that
prototype is deployed first, a separate integral-history migration design is
required. The four [fork cases](../test/fork/README.md) target the two real
1.0.0 vaults backing the six identified DTFs.

## Bounds and tradeoffs

OZ enforces nondecreasing uint48 timestamps and the uint208 voting supply cap.
The maximum stored integral including its sentinel is bounded by
`(2^208 - 1) * (2^48 - 1) + 1 < 2^256`. Guarded index arithmetic and updates
use unchecked operations under those constraints. Lookup multiplication and
addition stay checked because the public query accepts a uint256 timepoint.

Each new tracked checkpoint adds one companion storage word instead of two
observation words, with no second array length. The linked library performs
lookup and accounting in the vault's storage context. Lookup searches the full
standard checkpoint history, including pre-upgrade entries, through typed
storage references. Fewer writes do not imply cheaper reads; both paths must
be measured.

Keeping the accounting in a library lets this implementation use Solidity
0.8.33, no IR, and **156 optimizer runs**. The vault is **24,509 bytes**,
**67 bytes** below EIP-170, and the integral library is **1,104 bytes**. The
earlier observation-array prototype used 24,573 vault bytes plus a 1,300-byte
integral library. Size headroom remains limited and must be checked after future
edits.

Unit tests compare fuzzed histories to a direct segment-sum reference and cover
zero-vote intervals, same-timestamp movements, maximum arithmetic, no-ops,
redelegation, and rollback when OZ rejects a movement. Forks exercise actual
upgrades with legacy checkpoints from earlier and identical timestamps.

## Gas comparison

Both implementations below use Solidity 0.8.33, optimizer runs **156**, no IR,
and the same token harness and state sequence. The baseline is the earlier
observation-array implementation at
`982f284c1aea5f34dca32c0f15880402d829d1fc`; its external integral library
maintains a separate observation array. Holding the optimizer setting constant
isolates the accounting change.

| Operation | Separate observations | Shared checkpoints | Change |
| --- | ---: | ---: | ---: |
| Fresh mint, no delegation | 111,583 | 108,838 | -2,745 |
| Initial delegation | 126,058 | 98,940 | -27,118 |
| Later mint to delegated account | 146,049 | 113,423 | -32,626 |
| Transfer across distinct delegates | 201,194 | 140,693 | -60,501 |
| Same-timestamp coalesced transfer | 68,069 | 51,454 | -16,615 |
| Later burn from delegated account | 145,904 | 113,278 | -32,626 |
| Historical integral lookup, cold | 26,749 | 23,676 | -3,073 |
| Historical integral lookup, warm | 6,744 | 5,671 | -1,073 |
| Current integral lookup, cold | 24,690 | 21,421 | -3,269 |
| Current integral lookup, warm | 6,690 | 5,421 | -1,269 |

These are gross `gasleft()` differences around test-contract-to-token calls,
including CALL/calldata overhead and excluding intrinsic transaction gas and
refunds. They are not end-to-end StakingVault deposit costs. Cold measurements
use `vm.cool(token)` to cool the token address and its storage, and cool the
linked integral library in both implementations. Earlier state transitions
remain in the same Foundry test execution, so storage original/dirty accounting is not
claimed to match independent transaction receipts. Warm lookups immediately
repeat the same query. The lookup fixture has 65 checkpoints; the historical
query selects checkpoint 33 and the current query is ten seconds after the
last checkpoint. The coalescing measurement follows an earlier transfer at the
same timestamp.

Run the retained [benchmark](../test/bench/IntegralGasBenchmark.t.sol) with:

```sh
forge test --match-contract IntegralGasBenchmarkTest --optimizer-runs 156 -vv
```

To reproduce the baseline, copy the unchanged harness into a separate checkout
of the baseline commit and run the same command.

Both mutations and lookups cost less in this fixture, with the largest saving
on transfers between different delegates. Legacy delegates' lookups search
their full OZ checkpoint history, which can be longer than a new post-upgrade
observation array. These measurements do not characterize all history lengths
or transaction sequences.
