# Live governance upgrade tests

Run all ten fork cases with `pnpm test:fork` (equivalent to `forge test --match-path 'test/fork/*' --threads 1 --compute-units-per-second 50`).
`pnpm test` runs the non-fork suite, including all six upgrade permutations from
current implementations to V2 implementations in both deployment modes. CI runs
both commands.

The fork fixtures are pinned to BSC block **122054000** and Base block **51348400**.
Override `BSC_FORK_RPC_URL` or `BASE_FORK_RPC_URL` with an archive RPC if needed.
Defaults are `https://bsc-mainnet.public.blastapi.io` and `https://mainnet.base.org`.
The tests run serially with a reduced RPC request budget. They intentionally fail on
unavailable historical state rather than skip.

| Settings source | Chain | DTF address |
| --- | --- | --- |
| [PHOTON](https://app.reserve.org/bsc/index-dtf/photon/settings) | BSC | `0xa0fe4e0aeca5479705ce996615b2eacb6b6a10fb` |
| [BUILDOUT](https://app.reserve.org/bsc/index-dtf/buildout/settings) | BSC | `0xd7ce7a841310982acd976d1a6fe7bb6063c5689d` |
| [NEOCLOUD](https://app.reserve.org/bsc/index-dtf/neocloud/settings) | BSC | `0xf571fe3f0d74521bc7310b111faea931c748f27b` |
| [POWER](https://app.reserve.org/bsc/index-dtf/power/settings) | BSC | `0x290bcc0fd5096cc3261ae2021841c7bc67cb0f51` |
| [ROBOTS](https://app.reserve.org/bsc/index-dtf/robots/settings) | BSC | `0x75617e7653f86f074cc30b9fd4ebf52ba9b62247` |
| [MAG7](https://app.reserve.org/base/index-dtf/mag7/settings) | Base | `0xcef8db49e456f872e288e1c042f916e9ced7c781` |

Addresses were resolved from the app's published catalog and verified through
onchain DTF admin roles, governor `timelock()`/`token()`, and vault registry/admin
links. Governor and timelock addresses are fixed in `DtfUpgrade.t.sol`. The five
BSC DTFs share vault `0xE744C8157c346B2931807F42552c8CBc0BB6D34f`; MAG7 uses
`0x2F0D6538807a77d4AdDCd4b4DAf214Ea2E818E3D` on Base. Each vault has its own
admin governor/timelock, distinct from the DTF's governor/timelock.

Each test starts from untouched 1.0.0 proxy code and chain state. It impersonates
the existing registry owner to register the locally deployed 1.1.0 release, then
uses actual delegates' existing votes to pass standard proposals. It upgrades
the vault through its own admin governance, and the DTF governor/timelock through
the DTF governance. The governor upgrade remains a direct proposal target
because its `onlyGovernance` guard requires the governor's exact execution
calldata; `UpgradeSpell_1_1_0` is used as an intermediate timelock
implementation to initialize the registry and self-upgrade to the registered
1.1.0 timelock implementation.
No proxy bytecode, storage, roles, balances, or voting power are overwritten with
cheatcodes. Only authorized actors are impersonated and proposal time is advanced.

Checks include implementation slots, registry initialization/replay rejection,
preservation of existing storage/configuration, vault balances and delegated
votes, governance roles, a post-upgrade governance action, and rejection of an
unregistered timelock implementation claiming the same version.

These tests prove compatibility and execution at the pinned chain state, assuming
the real registry owner approves the release and the real delegates approve the
proposals. They do not broadcast or assert that those approvals have been given.
The DTF token contract itself is not an upgrade target here: the three components
are the staking vault, governor, and timelock. For 1.0.0 migrations, upgrade the
vault first because the new governor reads its vote-integral API. Current-to-V2
upgrade permutations are separately covered by the non-fork suite.

## Checkpoint integral migration tests

`VoteIntegralUpgrade.t.sol` adds four vault-focused cases: earlier legacy
checkpoints and same-timestamp legacy checkpoints for each of the two vaults
above. They use the same pinned blocks and RPC settings. The BSC share holder
is `0xb209Eed4D80fB47E5C16577e44DaD1073c5C5015`; the Base share holder is
`0x49B4564cb533E092D43C628386258F0B78D86c52`.

These cases impersonate the existing registry owner and vault admin directly
and use actual share holders to move delegated votes before/after upgrading.
They preserve the deployed governor/timelock implementations and test only the
vault upgrade. No proxy storage, code, balances, roles or votes are patched.

Assertions cover ordinary storage, balances, supply, standard and optimistic
checkpoint samples, historical votes, the implementation slot, zero integral
before the first tracked movement, same-timestamp coalescing and subsequent
integral accumulation. The six `DtfUpgrade.t.sol` cases above separately prove
upgrades of all three components through real governance paths.
