# Changelog

## 1.1.0 (Unreleased)

### Changed

- Standard and optimistic proposals now consume the same existing per-account proposal throttle. Capacity, charge state, deployment input, and governance setter are shared. Veto-triggered confirmation proposals remain exempt from throttle and proposer eligibility checks.
- Standard proposals require votes at the previous timestamp and a 12-hour average vote weight normalized by average total supply. Both lookback and throttle refill use `PROPOSAL_THROTTLE_PERIOD` (12 hours).
- Integral accounting starts at one activation timestamp per vault. Pre-activation account vote-seconds count as zero while the denominator uses the supply captured at activation, preserving the fail-closed 12-hour ramp for threshold-sized legacy holders.
- The shared `Versioned` mixin returns `1.1.0` instead of `1.0.0`.
- Optimistic proposal state is calculated directly in the governor, avoiding the library round trip.
- Optimizer runs set to 416 with Solidity 0.8.33 and IR compilation disabled. Governor runtime: 24,481 bytes; StakingVault runtime: 24,319 bytes. UnstakingManager creation runs through the linked upgrade library to preserve this headroom.

### Added

- `StakingVault.getPastAverageSupply(start, end)` for average total supply rounded up over a requested interval, alongside `getPastAverageVotes(account, start, end)`. Rounding up keeps proposer eligibility conservative when the average supply is fractional. Existing OZ account and supply checkpoints are paired with companion cumulative mappings, preserving packed checkpoint storage and logarithmic lookups without walking account histories.
- Real BSC and Base vault upgrade forks cover preexisting checkpoint history and same-timestamp migration; unit tests cover integral arithmetic boundaries and compare fuzzed histories against a segment-sum reference.
- Coverage for shared throttle consumption, the legacy activation ramp, pre-activation endpoint replay, the fresh-account anniversary bypass, vote-second conservation, zero-area windows, delayed initialization, and one-shot activation. The segment-sum fuzz reference clips arbitrary histories at activation.

### Upgrade notes

- Upgrade and activate the vault before upgrading its governor or deploying a new governor against it. Pass `abi.encodeCall(StakingVault.initializeAverageVotes, ())` to `upgradeToAndCall` through the existing version-registry and vault-admin authorization flow. Fresh vaults activate during initialization.
- No new governor throttle storage is required. The `reserve.storage.VotesIntegral` ERC-7201 namespace stores raw account and supply integrals plus one packed activation timestamp/supply slot (zero timestamp means inactive), preserving deployed 1.0.0 checkpoints and ordinary storage. This does not migrate integral state from earlier unreleased PR prototypes.
- Activation cannot be reset under the supported-chain assumption of positive timestamps. If omitted during upgrade, average-vote lookups return zero and history updates are skipped while ordinary vote checkpoints continue. A later admin initialization starts the ramp at that later timestamp without backfilling prior activity.
- A threshold-sized unchanged holder becomes eligible after twelve hours; larger holders can qualify earlier through the supply-seconds ratio. Pre-upgrade stake hops earn no credit, and post-activation balance dips remain part of the calculation.
- Fresh governor EIP-712 domains use version `1.1.0`. Existing governor proxies retain their stored domain version on upgrade; signing clients should query `eip712Domain()`.

See the [README upgrade guide](README.md#upgrading-to-110) for migration details. This entry describes the proposed release; it does not record a deployment.
