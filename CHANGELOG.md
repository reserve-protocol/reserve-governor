# Changelog

## 1.1.0 (Unreleased)

### Changed

- Standard and optimistic proposals now consume the same existing per-account proposal throttle. Capacity, charge state, deployment input, and governance setter are shared. Veto-triggered confirmation proposals remain exempt from throttle and proposer eligibility checks.
- Standard proposals require votes at the previous timestamp and a 12-hour average of standard delegated vote power to meet the current proposal threshold. Both lookback and throttle refill use `PROPOSAL_THROTTLE_PERIOD` (12 hours).
- When the current cumulative vote integral is zero, standard proposal eligibility falls back to current standard votes, while retaining the previous-timestamp check. This permits unchanged delegates on upgraded vaults to qualify without a transfer or 12 hours of vote history when both vote checks meet the threshold.
- The shared `Versioned` mixin returns `1.1.0` instead of `1.0.0`.
- Governor and timelock upgrades now require the exact implementation registered for the latest non-deprecated release, using `GovernanceUpgradeLib` while preserving the existing caller authorization.
- Optimizer runs increased from 149 to 156 with Solidity 0.8.33 and IR compilation disabled. Governor runtime: 23,740 bytes; StakingVault runtime: 24,573 bytes (3 bytes below EIP-170).

### Added

- Linked `VoteIntegralLib` and `StakingVault.getPastVotesIntegral(account, timepoint)` for append-only cumulative standard delegated vote-seconds. Observations coalesce at the same timestamp and support binary-search lookup without a finite retention window.
- Coverage for shared throttle consumption, integral accounting and no-op movements, the current-vote fallback, its previous-timestamp safeguard, and eligibility after time passes without another transfer.

### Upgrade notes

- Upgrade the vault to an implementation supporting `getPastVotesIntegral` before upgrading its governor or deploying a new governor against it. Follow the existing version-registry and vault-admin authorization flow.
- Existing governors and timelocks must initialize their appended version-registry pointer using `initializeVersionRegistry(registryAddress)` as `upgradeToAndCall` data. Each migration uses `reinitializer(2)` and cannot replace a configured registry. New deployments initialize this pointer directly.
- No new governor throttle storage is required. Integral state reuses the previously unused field in the existing optimistic votes ERC-7201 namespace, leaving the vault's ordinary storage layout intact.
- The current-vote fallback requires votes at the current and previous timestamps, with no 12-hour average requirement while the integral is zero. Once a real delegated-vote movement starts accumulating a nonzero integral, only recorded vote-seconds count; existing delegates may need time to rebuild eligibility. Old history is not backfilled.
- Fresh governor EIP-712 domains use version `1.1.0`. Existing governor proxies retain their stored domain version on upgrade; signing clients should query `eip712Domain()`.

See the [README upgrade guide](README.md#upgrading-to-110) for migration details. This entry describes the proposed release; it does not record a deployment.
