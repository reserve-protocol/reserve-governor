# Changelog

## 1.1.0 (Unreleased)

### Changed

- Standard and optimistic proposals now consume the same existing per-account proposal throttle. Capacity, charge state, deployment input, and governance setter are shared. Veto-triggered confirmation proposals remain exempt from throttle and proposer eligibility checks.
- Standard proposals require votes at the previous timestamp and a 12-hour average of standard delegated vote power to meet the current proposal threshold. Both lookback and throttle refill use `PROPOSAL_THROTTLE_PERIOD` (12 hours).
- When integral history at the start of the lookback window is untracked, standard proposal eligibility falls back to the standard vote checkpoint at that time. This keeps unchanged legacy delegates eligible after a dust movement starts tracking, while newly delegated accounts still wait until the lookback reaches their delegation checkpoint.
- The shared `Versioned` mixin returns `1.1.0` instead of `1.0.0`.
- Optimizer runs set to 156 with Solidity 0.8.33 and IR compilation disabled. Governor runtime: 23,106 bytes; StakingVault runtime: 24,509 bytes (67 bytes below EIP-170).

### Added

- `ERC20VotesIntegralUpgradeable`, linked `VoteIntegralLib`, and `StakingVault.getPastVotesIntegral(account, timepoint)` for cumulative standard delegated vote-seconds indexed by existing OZ checkpoints. Both the companion mapping and getter use cumulative values plus one, with zero reserved for untracked history. This preserves packed checkpoint storage and same-timestamp coalescing without duplicate timestamp/value history. Accounting runs in the library to keep the vault below its bytecode limit; OZ remains responsible for writing standard vote checkpoints. Out-of-range future extrapolation reverts on arithmetic overflow instead of wrapping.
- Real BSC and Base vault upgrade forks cover preexisting checkpoint history and same-timestamp migration; unit tests cover integral arithmetic boundaries and compare fuzzed histories against a segment-sum reference.
- Coverage for shared throttle consumption, integral accounting and no-op movements, legacy eligibility across the first tracked checkpoint boundary, the fresh-account anniversary bypass, tracked zero-area windows, and new-account eligibility after a full lookback without another transfer.

### Upgrade notes

- Upgrade the vault to an implementation supporting `getPastVotesIntegral` before upgrading its governor or deploying a new governor against it. Follow the existing version-registry and vault-admin authorization flow.
- No reinitializer or new governor throttle storage is required. Integral state uses the new `reserve.storage.VotesIntegral` ERC-7201 namespace, leaving all deployed 1.0.0 vote checkpoints and ordinary storage intact. It does not migrate integral arrays from the earlier, unreleased observation-array prototype.
- Historical fallback applies only while the lookback start is untracked. At the first tracked checkpoint, the getter returns one even for zero area, so exact averaging applies. The fallback ends per account 12 hours after its first tracked movement, not necessarily 12 hours after upgrade. It checks only votes at the lookback start and the previous timestamp, so it cannot detect an intervening dip or prevent replaying pre-upgrade stake hops across legacy accounts 12 hours later. This single-point approximation is the accepted compatibility tradeoff because old history is not backfilled.
- Fresh governor EIP-712 domains use version `1.1.0`. Existing governor proxies retain their stored domain version on upgrade; signing clients should query `eip712Domain()`.

See the [README upgrade guide](README.md#upgrading-to-110) for migration details. This entry describes the proposed release; it does not record a deployment.
