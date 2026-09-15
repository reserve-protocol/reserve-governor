# Changelog

## 1.1.0 (Unreleased)

### Changed

- Standard and optimistic proposals now consume the same existing per-account proposal throttle. Capacity, charge state, deployment input, and governance setter are shared. Veto-triggered confirmation proposals remain exempt from throttle and proposer eligibility checks.
- Standard proposals require votes at the previous timestamp and a 12-hour average of standard delegated vote power to meet the current proposal threshold. Both lookback and throttle refill use `PROPOSAL_THROTTLE_PERIOD` (12 hours).
- When the current cumulative vote integral is zero, standard proposal eligibility falls back to the existing standard vote checkpoint at the start of the lookback window. This permits unchanged delegates on upgraded vaults to qualify without a transfer when their historical votes meet the threshold.
- The shared `Versioned` mixin returns `1.1.0` instead of `1.0.0`.
- Optimizer runs set to 156 with Solidity 0.8.33 and IR compilation disabled. Governor runtime: 23,106 bytes; StakingVault runtime: 24,509 bytes (67 bytes below EIP-170).

### Added

- `ERC20VotesIntegralUpgradeable`, linked `VoteIntegralLib`, and `StakingVault.getPastVotesIntegral(account, timepoint)` for cumulative standard delegated vote-seconds indexed by existing OZ checkpoints. A companion mapping stores cumulative values plus one, preserving packed checkpoint storage and same-timestamp coalescing without duplicate timestamp/value history. Accounting runs in the library to keep the vault below its bytecode limit; OZ remains responsible for writing standard vote checkpoints. Out-of-range future extrapolation reverts on arithmetic overflow instead of wrapping.
- Real BSC and Base vault upgrade forks cover preexisting checkpoint history and same-timestamp migration; unit tests cover integral arithmetic boundaries and compare fuzzed histories against a segment-sum reference.
- Coverage for shared throttle consumption, integral accounting and no-op movements, the historical-vote fallback, and eligibility after time passes without another transfer.

### Upgrade notes

- Upgrade the vault to an implementation supporting `getPastVotesIntegral` before upgrading its governor or deploying a new governor against it. Follow the existing version-registry and vault-admin authorization flow.
- No reinitializer or new governor throttle storage is required. Integral state uses the new `reserve.storage.VotesIntegral` ERC-7201 namespace, leaving all deployed 1.0.0 vote checkpoints and ordinary storage intact. This experimental layout does not migrate the alternative, unreleased integral arrays.
- Historical fallback is a single-point approximation. Once a real delegated-vote movement starts accumulating a nonzero integral, only recorded vote-seconds count; existing delegates may need time to rebuild eligibility. Old history is not backfilled.
- Fresh governor EIP-712 domains use version `1.1.0`. Existing governor proxies retain their stored domain version on upgrade; signing clients should query `eip712Domain()`.

See the [README upgrade guide](README.md#upgrading-to-110) for migration details. This entry describes the proposed release; it does not record a deployment.
