# Average-votes upgrade forks

Run `pnpm test:fork` for the four pinned upgrade cases. `pnpm test` runs the
non-fork suite. CI runs both. Fork tests fail rather than skip if historical
state is unavailable.

| Vault | Address | Pinned block | Share holder used |
| --- | --- | --- | --- |
| BSC, shared by PHOTON, BUILDOUT, NEOCLOUD, POWER and ROBOTS | `0xE744C8157c346B2931807F42552c8CBc0BB6D34f` | 122054000 | `0xb209Eed4D80fB47E5C16577e44DaD1073c5C5015` |
| Base, MAG7 | `0x2F0D6538807a77d4AdDCd4b4DAf214Ea2E818E3D` | 51348400 | `0x49B4564cb533E092D43C628386258F0B78D86c52` |

These are the two distinct staking vaults used by the six DTFs identified in
[PR #50's fixtures](https://github.com/reserve-protocol/reserve-governor/blob/3630e02354a4f602fb257ce2442c9dd71403381c/test/fork/README.md).

Override `BSC_FORK_RPC_URL` or `BASE_FORK_RPC_URL` with an archive RPC if needed.
Defaults are `https://bsc-mainnet.public.blastapi.io` and `https://mainnet.base.org`.
Tests run serially with a 50 compute-units-per-second RPC budget.

Each vault is tested with both earlier legacy checkpoints and a legacy
checkpoint created at the exact upgrade timestamp. The fixture registers the
new vault implementation through the existing registry owner, then calls the
actual vault's `upgradeToAndCall` from its existing admin with
`abi.encodeCall(StakingVault.initializeAverageVotes, ())`. Real share holders
move their delegated votes before/after the upgrade. No proxy storage, code,
balances, roles or votes are patched.

Assertions cover ordinary storage, balances, supply, standard and optimistic
checkpoint samples, historical votes, the implementation slot, zero average voting power
at activation, automatic accrual without new checkpoints, and preservation of
that accrued area on the first later movement. The same-timestamp cases also
coalesce post-upgrade movements into checkpoints written by the legacy
implementation at activation. The token returns average votes over each requested
interval, rounded down.

The old governor/timelock implementations remain in use; this experiment changes
the vault's accounting only. These tests impersonate authorized actors directly
and do not simulate voting to approve the upgrade or broadcast transactions.
