# Experimental checkpoint-indexed vote integrals

This is an alternative implementation of the unreleased proposal-integral
feature in [PR #48](https://github.com/reserve-protocol/reserve-governor/pull/48).
It removes `VoteIntegralLib` and its duplicate observation arrays. Governor
eligibility and throttle behavior are inherited from that PR.

## Storage and updates

`ERC20VotesIntegralUpgradeable` extends OZ `ERC20VotesUpgradeable` without
modifying OZ. Standard checkpoints remain packed `uint48` timestamps plus
`uint208` votes, occupying one storage slot each. A separate ERC-7201 namespace,
`reserve.storage.VotesIntegral`, contains:

```solidity
mapping(address account => mapping(uint256 checkpointIndex => uint256)) cumulative;
```

Values store the integral at that checkpoint's timestamp **plus one**. Zero
means the checkpoint has no integral history. This distinguishes an untracked
checkpoint from a tracked checkpoint with zero cumulative area, without a
separate tracking-start marker or array length.

Before a nonzero movement between different standard delegates, the extension
reads each affected delegate's latest OZ checkpoint. For a later timestamp it
stores `previousCumulative + previousVotes * elapsed` at the next checkpoint
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

This experiment does **not** migrate integral arrays from an already deployed
version of the alternative, unreleased `VoteIntegralLib` implementation. If
that implementation is deployed first, a separate integral-history migration
design would be required. The four [fork cases](../test/fork/README.md) target
the two real 1.0.0 vaults backing the six identified DTFs.

## Bounds and tradeoffs

OZ enforces nondecreasing uint48 timestamps and the uint208 voting supply cap.
The maximum stored integral including its sentinel is bounded by
`(2^208 - 1) * (2^48 - 1) + 1 < 2^256`. Guarded index arithmetic and updates
use unchecked operations under those constraints. Lookup multiplication and
addition stay checked because the public query accepts a uint256 timepoint.

Each new tracked checkpoint adds one companion storage word instead of two
observation words, and there is no second array length or linked-library call.
Lookup now searches the full standard checkpoint history, including pre-upgrade
entries, through OZ's protected checkpoint accessor. Fewer writes do not imply
cheaper reads; both paths must be measured.

Inlining the accounting increases vault code size. With Solidity 0.8.33, no IR,
and one optimizer run, the vault is **24,567 bytes**, only **9 bytes** below
EIP-170. At the parent's 156 runs this approach exceeds the limit. Lowering the
optimizer setting affects the other contracts' gas/bytecode too. This remains
a material constraint when deciding whether to adopt the experiment.

Unit tests compare fuzzed histories to a direct segment-sum reference and cover
zero-vote intervals, same-timestamp movements, maximum arithmetic, no-ops,
redelegation, and rollback when OZ rejects a movement. Forks exercise actual
upgrades with legacy checkpoints from earlier and identical timestamps.

## Gas comparison

Both implementations below use Solidity 0.8.33, optimizer runs **1**, no IR,
and the same token harness and state sequence. The baseline is PR #48 at
`982f284c1aea5f34dca32c0f15880402d829d1fc`; it uses the external integral library.
Holding the optimizer setting constant isolates the accounting change.

| Operation | External library | Checkpoint mapping | Change |
| --- | ---: | ---: | ---: |
| Fresh mint, no delegation | 111,691 | 105,395 | -6,296 |
| Initial delegation | 126,296 | 98,425 | -27,871 |
| Later mint to delegated account | 146,198 | 113,223 | -32,975 |
| Transfer across distinct delegates | 201,737 | 141,443 | -60,294 |
| Same-timestamp coalesced transfer | 68,612 | 52,431 | -16,181 |
| Later burn from delegated account | 146,406 | 113,431 | -32,975 |
| Historical integral lookup, cold | 27,362 | 27,698 | +336 |
| Historical integral lookup, warm | 7,357 | 9,693 | +2,336 |
| Current integral lookup, cold | 25,240 | 24,875 | -365 |
| Current integral lookup, warm | 7,240 | 8,875 | +1,635 |

These are gross `gasleft()` differences around test-contract-to-token calls,
including CALL/calldata overhead and excluding intrinsic transaction gas and
refunds. They are not end-to-end StakingVault deposit costs. Cold measurements
use `vm.cool(token)` to cool the token address and its storage; the baseline
also cools the linked integral library. Earlier state transitions remain in
the same Foundry test execution, so storage original/dirty accounting is not
claimed to match independent transaction receipts. Warm lookups immediately
repeat the same query. The lookup fixture has 65 checkpoints; the historical
query selects checkpoint 33 and the current query is ten seconds after the
last checkpoint. The coalescing measurement follows an earlier transfer at the
same timestamp.

Run the retained [benchmark](../test/bench/IntegralGasBenchmark.t.sol) with:

```sh
forge test --match-contract IntegralGasBenchmarkTest --optimizer-runs 1 -vv
```

To reproduce the baseline, copy that harness into a separate checkout of the
baseline commit, import its `VoteIntegralLib`, and add
`vm.cool(address(VoteIntegralLib));` to `_coolIntegralCall()`. Keep the same
optimizer setting and command. No copy of the old library is needed in this
branch.

The mutation savings are substantial in this fixture, especially when two
delegates change. Warm lookups become more expensive. Also, legacy delegates'
lookups search their full OZ checkpoint history, which can be longer than a
new post-upgrade observation array. This comparison does not characterize all
history lengths or the effect of lowering optimizer runs on unrelated vault
and governor operations.
