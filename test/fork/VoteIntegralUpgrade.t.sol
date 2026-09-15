// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IReserveOptimisticGovernorDeployer } from "@interfaces/IDeployer.sol";
import { IAccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import { ReserveOptimisticGovernorDeployer } from "@src/Deployer.sol";
import { ReserveOptimisticGovernanceVersionRegistry } from "@src/VersionRegistry.sol";
import { StakingVault } from "@staking/StakingVault.sol";
import { Test } from "forge-std/Test.sol";

/// @dev Uses real 1.0.0 vaults and authorized registry/admin accounts. No storage, code, balances or votes are patched.
contract VoteIntegralUpgradeForkTest is Test {
    address private constant BSC_HOLDER = 0xb209Eed4D80fB47E5C16577e44DaD1073c5C5015;
    address private constant FRESH_DELEGATE = address(0x123456789);
    bytes32 private constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    function testFork_BSC_existingCheckpoints() public {
        _testUpgrade(true, false);
    }

    function testFork_BSC_sameTimestampCheckpoint() public {
        _testUpgrade(true, true);
    }

    function testFork_MAG7_existingCheckpoints() public {
        _testUpgrade(false, false);
    }

    function testFork_MAG7_sameTimestampCheckpoint() public {
        _testUpgrade(false, true);
    }

    function _testUpgrade(bool bsc, bool sameTimestamp) private {
        StakingVault vault;
        if (bsc) {
            vm.createSelectFork(
                vm.envOr("BSC_FORK_RPC_URL", string("https://bsc-mainnet.public.blastapi.io")), 122_054_000
            );
            vault = StakingVault(0xE744C8157c346B2931807F42552c8CBc0BB6D34f);
        } else {
            vm.createSelectFork(vm.envOr("BASE_FORK_RPC_URL", string("https://mainnet.base.org")), 51_348_400);
            vault = StakingVault(0x2F0D6538807a77d4AdDCd4b4DAf214Ea2E818E3D);
        }
        assertEq(vault.version(), "1.0.0");
        address holder = bsc ? BSC_HOLDER : 0x49B4564cb533E092D43C628386258F0B78D86c52;
        uint256 shares = vault.balanceOf(holder);
        address delegate = vault.delegates(holder);
        assertGt(shares, 0);
        assertTrue(delegate != address(0) && delegate != FRESH_DELEGATE);
        assertEq(vault.numCheckpoints(FRESH_DELEGATE), 0);
        uint256 oldVotes = vault.getVotes(delegate);
        uint256 oldTime = block.timestamp - 1;
        uint256 pastVotes = vault.getPastVotes(delegate, oldTime);

        if (sameTimestamp) {
            // Write a real legacy checkpoint immediately before the upgrade, in the same timestamp.
            vm.prank(holder);
            vault.delegate(FRESH_DELEGATE);
        }
        uint32 count = vault.numCheckpoints(delegate);
        bytes32 beforeState = _state(vault, delegate, holder);
        _upgradeVault(vault);
        assertEq(_state(vault, delegate, holder), beforeState, "upgrade changed existing storage/history");
        assertEq(vault.version(), "1.1.0");
        assertEq(vault.getPastVotesIntegral(delegate, block.timestamp), 0);
        assertEq(vault.getPastVotesIntegral(FRESH_DELEGATE, block.timestamp), 0);

        if (!sameTimestamp) {
            // Waiting and no-op delegation must not backfill old checkpoints or start tracking.
            vm.warp(block.timestamp + 100);
            vm.prank(holder);
            vault.delegate(delegate);
            assertEq(vault.getPastVotesIntegral(delegate, block.timestamp), 0);
        }
        uint256 start = block.timestamp;
        vm.prank(holder);
        vault.delegate(sameTimestamp ? delegate : FRESH_DELEGATE);
        assertEq(vault.numCheckpoints(delegate), sameTimestamp ? count : count + 1);
        assertEq(vault.numCheckpoints(FRESH_DELEGATE), 1);
        assertEq(vault.getPastVotesIntegral(delegate, start), 0);
        assertEq(vault.getPastVotesIntegral(delegate, start - 1), 0);

        vm.warp(start + 100);
        uint256 trackedVotes = sameTimestamp ? oldVotes : oldVotes - shares;
        uint256 freshVotes = sameTimestamp ? 0 : shares;
        assertEq(vault.getPastVotesIntegral(delegate, block.timestamp), trackedVotes * 100);
        assertEq(vault.getPastVotesIntegral(FRESH_DELEGATE, block.timestamp), freshVotes * 100);
        assertEq(vault.getPastVotes(delegate, oldTime), pastVotes);
        assertEq(vault.getPastVotes(delegate, start), trackedVotes);

        // Another movement must accumulate the previous interval exactly once.
        vm.prank(holder);
        vault.delegate(sameTimestamp ? FRESH_DELEGATE : delegate);
        vm.warp(start + 200);
        assertEq(
            vault.getPastVotesIntegral(delegate, block.timestamp),
            trackedVotes * 100 + (sameTimestamp ? oldVotes - shares : oldVotes) * 100
        );
        assertEq(vault.getPastVotesIntegral(FRESH_DELEGATE, block.timestamp), shares * 100);
        assertEq(vault.getPastVotesIntegral(delegate, start + 50), trackedVotes * 50);
        assertEq(vault.getPastVotes(delegate, oldTime), pastVotes);
    }

    function _upgradeVault(StakingVault vault) private {
        ReserveOptimisticGovernanceVersionRegistry registry = vault.versionRegistry();
        (,, IReserveOptimisticGovernorDeployer previous,) = registry.getLatestVersion();
        ReserveOptimisticGovernorDeployer oldDeployer = ReserveOptimisticGovernorDeployer(address(previous));
        address implementation = address(new StakingVault());
        ReserveOptimisticGovernorDeployer next = new ReserveOptimisticGovernorDeployer(
            address(registry),
            oldDeployer.rewardTokenRegistry(),
            oldDeployer.trustedFillerRegistry(),
            oldDeployer.guardian(),
            implementation,
            oldDeployer.governorImpl(),
            oldDeployer.timelockImpl(),
            oldDeployer.selectorRegistryImpl()
        );
        address owner = IAccessControlEnumerable(address(registry.roleRegistry())).getRoleMember(bytes32(0), 0);
        assertTrue(registry.roleRegistry().isOwner(owner));
        vm.prank(owner);
        registry.registerVersion(next);
        address admin = vault.getRoleMember(bytes32(0), 0);
        vm.prank(admin);
        vault.upgradeToAndCall(implementation, "");
        assertEq(address(uint160(uint256(vm.load(address(vault), IMPLEMENTATION_SLOT)))), implementation);
    }

    function _state(StakingVault vault, address delegate, address holder) private view returns (bytes32 hash) {
        // Ordinary storage and standard/optimistic checkpoint samples, including array elements beyond index zero.
        for (uint256 i; i < 14; ++i) {
            hash = keccak256(abi.encode(hash, vm.load(address(vault), bytes32(i))));
        }
        hash = keccak256(
            abi.encode(
                hash,
                vault.balanceOf(holder),
                vault.totalSupply(),
                vault.getPastTotalSupply(block.timestamp - 1),
                vault.delegates(holder),
                vault.optimisticDelegates(holder)
            )
        );
        address[3] memory accounts = [delegate, FRESH_DELEGATE, vault.optimisticDelegates(holder)];
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            uint32 count = vault.numCheckpoints(account);
            uint32 optimisticCount = vault.numOptimisticCheckpoints(account);
            hash = keccak256(
                abi.encode(hash, count, optimisticCount, vault.getVotes(account), vault.getOptimisticVotes(account))
            );
            if (count != 0) {
                hash = keccak256(
                    abi.encode(
                        hash,
                        vault.checkpoints(account, 0),
                        vault.checkpoints(account, count / 2),
                        vault.checkpoints(account, count - 1)
                    )
                );
            }
            if (optimisticCount != 0) {
                hash = keccak256(
                    abi.encode(
                        hash,
                        vault.optimisticCheckpoints(account, 0),
                        vault.optimisticCheckpoints(account, optimisticCount / 2),
                        vault.optimisticCheckpoints(account, optimisticCount - 1)
                    )
                );
            }
        }
    }
}
