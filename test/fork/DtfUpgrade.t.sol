// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IAccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { Test } from "forge-std/Test.sol";

import { ReserveOptimisticGovernor } from "@governance/ReserveOptimisticGovernor.sol";
import { TimelockControllerOptimistic } from "@governance/TimelockControllerOptimistic.sol";
import { GovernanceUpgradeLib } from "@governance/lib/GovernanceUpgradeLib.sol";
import { IReserveOptimisticGovernorDeployer } from "@interfaces/IDeployer.sol";
import { ReserveOptimisticGovernorDeployer } from "@src/Deployer.sol";
import { ReserveOptimisticGovernanceVersionRegistry } from "@src/VersionRegistry.sol";
import { UpgradeSpell_1_1_0 } from "@src/spells/upgrades/UpgradeSpell_1_1_0.sol";
import { StakingVault } from "@staking/StakingVault.sol";
import { CANCELLER_ROLE, EXECUTOR_ROLE, OPTIMISTIC_PROPOSER_ROLE, PROPOSER_ROLE } from "@utils/Constants.sol";

/// @dev Live 1.0.0 proxies discovered from the six app.reserve.org settings pages.
///      No proxy bytecode, storage, balances, votes, or roles are replaced by cheatcodes.
///      Only existing voters/registry owner are impersonated, and proposal time is advanced.
contract DtfUpgradeForkTest is Test {
    uint256 private constant BSC_BLOCK = 122_054_000;
    uint256 private constant BASE_BLOCK = 51_348_400;
    bytes32 private constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    struct Fixture {
        uint256 chainId;
        address dtf;
        address governor;
        address timelock;
        address vault;
    }

    struct System {
        StakingVault vault;
        ReserveOptimisticGovernor governor;
        TimelockControllerOptimistic timelock;
        ReserveOptimisticGovernanceVersionRegistry registry;
    }

    function testFork_PHOTON_upgradeAllComponents() public {
        _testUpgrade(
            _bsc(
                0xa0Fe4e0aEca5479705ce996615B2EACB6b6a10Fb,
                0xf6F73C085b22D791705b8173712F37A2FeEE58e1,
                0x823677Ea4c1aBb3E4F26EEE767c550F48425e042
            )
        );
    }

    function testFork_BUILDOUT_upgradeAllComponents() public {
        _testUpgrade(
            _bsc(
                0xD7cE7a841310982AcD976D1a6fe7BB6063c5689D,
                0x11DdDE7845764C5317042c51e7e5EC665db33055,
                0xf95e970cDD970e94aB16C6286d0e1e948aA5AC91
            )
        );
    }

    function testFork_NEOCLOUD_upgradeAllComponents() public {
        _testUpgrade(
            _bsc(
                0xf571Fe3F0d74521Bc7310B111Faea931C748f27B,
                0x72b4Be10fBb28Af7b227C1db48EdC3f2B111Ec6E,
                0x4c2aF6f60CF6CCd4C4E006e78A58498D0d1710F8
            )
        );
    }

    function testFork_POWER_upgradeAllComponents() public {
        _testUpgrade(
            _bsc(
                0x290bCc0Fd5096cC3261AE2021841c7BC67Cb0f51,
                0x056CCC0F4CEDc4246F79cBf5Fe40F4D170Cb6769,
                0x26a6A9c3803c0217e7a50B9204F5cfA9b8e535a4
            )
        );
    }

    function testFork_ROBOTS_upgradeAllComponents() public {
        _testUpgrade(
            _bsc(
                0x75617e7653f86f074Cc30b9Fd4eBf52bA9b62247,
                0x736242C3fB5cFeEE70267D5C3B123211b760C966,
                0xF3994d261b77be02916fb4D03FF3971a18560d32
            )
        );
    }

    function testFork_MAG7_upgradeAllComponents() public {
        _testUpgrade(
            Fixture(
                8453,
                0xCEF8Db49E456f872E288E1C042F916E9ceD7c781,
                0x91deCceF10A7FCE6485a3Ea62794d1a90781bdC1,
                0xDb29158Ce7AB8f9C59cB20DfCd0221160b4EaE37,
                0x2F0D6538807a77d4AdDCd4b4DAf214Ea2E818E3D
            )
        );
    }

    function _bsc(address dtf, address governor, address timelock) private pure returns (Fixture memory) {
        return Fixture(56, dtf, governor, timelock, 0xE744C8157c346B2931807F42552c8CBc0BB6D34f);
    }

    function _testUpgrade(Fixture memory fixture) private {
        if (fixture.chainId == 56) {
            vm.createSelectFork(
                vm.envOr("BSC_FORK_RPC_URL", string("https://bsc-mainnet.public.blastapi.io")), BSC_BLOCK
            );
        } else {
            vm.createSelectFork(vm.envOr("BASE_FORK_RPC_URL", string("https://mainnet.base.org")), BASE_BLOCK);
        }
        assertEq(block.chainid, fixture.chainId);
        System memory sys = System(
            StakingVault(fixture.vault),
            ReserveOptimisticGovernor(payable(fixture.governor)),
            TimelockControllerOptimistic(payable(fixture.timelock)),
            StakingVault(fixture.vault).versionRegistry()
        );
        assertTrue(IAccessControlEnumerable(fixture.dtf).hasRole(bytes32(0), fixture.timelock));
        assertEq(sys.governor.timelock(), fixture.timelock);
        assertEq(address(sys.governor.token()), fixture.vault);
        assertEq(sys.vault.version(), "1.0.0");
        assertEq(sys.governor.version(), "1.0.0");
        assertEq(sys.timelock.version(), "1.0.0");

        address vaultImpl = address(new StakingVault());
        address governorImpl = address(new ReserveOptimisticGovernor());
        address timelockImpl = address(new TimelockControllerOptimistic());
        _registerRelease(sys.registry, vaultImpl, governorImpl, timelockImpl);

        // The shared vault has its own admin timelock/governor, distinct from the DTF governance.
        _upgradeVault(sys.vault);
        _upgradeGovernance(sys, governorImpl, timelockImpl);

        assertEq(_implementation(fixture.vault), vaultImpl);
        assertEq(_implementation(fixture.governor), governorImpl);
        assertEq(_implementation(fixture.timelock), timelockImpl);
        assertEq(sys.vault.version(), "1.1.0");
        assertEq(sys.governor.version(), "1.1.0");
        assertEq(sys.timelock.version(), "1.1.0");
        assertEq(address(sys.governor.versionRegistry()), address(sys.registry));
        assertEq(address(sys.timelock.versionRegistry()), address(sys.registry));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(fixture.timelock);
        sys.governor.initializeVersionRegistry(address(sys.registry));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(fixture.timelock);
        sys.timelock.initializeVersionRegistry(address(sys.registry));

        // Exercise the new governor's proposal eligibility, voting and timelock execution.
        uint256 newCapacity = sys.governor.proposalThrottleCapacity() + 1;
        (address[] memory targets, uint256[] memory values, bytes[] memory data) =
            _singleCall(fixture.governor, abi.encodeCall(sys.governor.setProposalThrottle, (newCapacity)));
        _passAndExecute(sys.governor, targets, values, data, "Post-upgrade governance");
        assertEq(sys.governor.proposalThrottleCapacity(), newCapacity);

        // Even the privileged caller cannot install another implementation claiming the same release.
        address rogueTimelock = address(new TimelockControllerOptimistic());
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceUpgradeLib.Governance__NotLatestTimelock.selector, rogueTimelock)
        );
        vm.prank(fixture.timelock);
        sys.timelock.upgradeToAndCall(rogueTimelock, "");
    }

    function _registerRelease(
        ReserveOptimisticGovernanceVersionRegistry registry,
        address vaultImpl,
        address governorImpl,
        address timelockImpl
    ) private {
        (,, IReserveOptimisticGovernorDeployer previous,) = registry.getLatestVersion();
        ReserveOptimisticGovernorDeployer oldDeployer = ReserveOptimisticGovernorDeployer(address(previous));
        ReserveOptimisticGovernorDeployer next = new ReserveOptimisticGovernorDeployer(
            address(registry),
            oldDeployer.rewardTokenRegistry(),
            oldDeployer.trustedFillerRegistry(),
            oldDeployer.guardian(),
            vaultImpl,
            governorImpl,
            timelockImpl,
            oldDeployer.selectorRegistryImpl()
        );
        address registryOwner = IAccessControlEnumerable(address(registry.roleRegistry())).getRoleMember(bytes32(0), 0);
        assertTrue(registry.roleRegistry().isOwner(registryOwner));
        vm.prank(registryOwner);
        registry.registerVersion(next);
    }

    function _upgradeVault(StakingVault vault) private {
        address admin = vault.getRoleMember(bytes32(0), 0);
        address ownerGovernor = IAccessControlEnumerable(admin).getRoleMember(PROPOSER_ROLE, 0);
        ReserveOptimisticGovernor governor = ReserveOptimisticGovernor(payable(ownerGovernor));
        assertEq(governor.timelock(), admin);
        assertEq(address(governor.token()), address(vault));
        UpgradeSpell_1_1_0 spell = new UpgradeSpell_1_1_0();
        assertEq(vault.getRoleMemberCount(vault.DEFAULT_ADMIN_ROLE()), 1);

        uint256 snapshot = vm.snapshotState();
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.startPrank(admin);
        vault.grantRole(adminRole, address(spell));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(UpgradeSpell_1_1_0.UpgradeSpell__Error.selector, 3));
        spell.cast(vault);
        vm.revertToState(snapshot);

        address[] memory targets = new address[](2);
        targets[0] = address(vault);
        targets[1] = address(spell);
        uint256[] memory values = new uint256[](2);
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeCall(vault.grantRole, (vault.DEFAULT_ADMIN_ROLE(), address(spell)));
        data[1] = abi.encodeCall(spell.cast, (vault));
        bytes32 descriptionHash = _passAndQueue(governor, targets, values, data, "Upgrade shared staking vault");
        bytes32 beforeState = _vaultState(vault);
        governor.execute(targets, values, data, descriptionHash);
        assertEq(_vaultState(vault), beforeState, "vault state changed during upgrade");
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(spell)));
        assertEq(vault.getRoleMemberCount(vault.DEFAULT_ADMIN_ROLE()), 1);
        assertEq(vault.getRoleMember(vault.DEFAULT_ADMIN_ROLE(), 0), admin);
    }

    function _upgradeGovernance(System memory sys, address governorImpl, address timelockImpl) private {
        address[] memory targets = new address[](2);
        targets[0] = address(sys.governor);
        targets[1] = address(sys.timelock);
        uint256[] memory values = new uint256[](2);
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeCall(
            sys.governor.upgradeToAndCall,
            (governorImpl, abi.encodeCall(sys.governor.initializeVersionRegistry, (address(sys.registry))))
        );
        data[1] = abi.encodeCall(
            sys.timelock.upgradeToAndCall,
            (timelockImpl, abi.encodeCall(sys.timelock.initializeVersionRegistry, (address(sys.registry))))
        );
        bytes32 descriptionHash = _passAndQueue(sys.governor, targets, values, data, "Upgrade DTF governance");
        bytes32 beforeState = _governanceState(sys);
        sys.governor.execute(targets, values, data, descriptionHash);
        assertEq(_governanceState(sys), beforeState, "governance state changed during upgrade");
    }

    function _passAndExecute(
        ReserveOptimisticGovernor governor,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory data,
        string memory description
    ) private {
        bytes32 descriptionHash = _passAndQueue(governor, targets, values, data, description);
        governor.execute(targets, values, data, descriptionHash);
        assertEq(
            uint256(governor.state(governor.getProposalId(targets, values, data, descriptionHash))),
            uint256(IGovernor.ProposalState.Executed)
        );
    }

    function _passAndQueue(
        ReserveOptimisticGovernor governor,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory data,
        string memory description
    ) private returns (bytes32 descriptionHash) {
        address[] memory voters = _voters();
        vm.prank(voters[0]);
        uint256 id = governor.propose(targets, values, data, description);
        vm.warp(governor.proposalSnapshot(id) + 1);
        for (uint256 i; i < voters.length; ++i) {
            assertGt(governor.getVotes(voters[i], governor.proposalSnapshot(id)), 0);
            vm.prank(voters[i]);
            governor.castVote(id, 1);
        }
        vm.warp(governor.proposalDeadline(id) + 1);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Succeeded));
        descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, data, descriptionHash);
        vm.warp(governor.proposalEta(id) + 1);
    }

    function _voters() private view returns (address[] memory voters) {
        if (block.chainid == 56) {
            voters = new address[](5);
            voters[0] = 0x49B4564cb533E092D43C628386258F0B78D86c52;
            voters[1] = 0x6774DB46FF94Ff6bC70a5F69c438a3630ee52E68;
            voters[2] = 0x67510E1104112484E73c20BB609070989E4E3f9b;
            voters[3] = 0xc1ee3dD75C2a0582E0a9264C1429a063C9CB045F;
            voters[4] = 0xb209Eed4D80fB47E5C16577e44DaD1073c5C5015;
        } else {
            voters = new address[](1);
            voters[0] = 0xb209Eed4D80fB47E5C16577e44DaD1073c5C5015;
        }
    }

    function _vaultState(StakingVault vault) private view returns (bytes32) {
        address[] memory voters = _voters();
        bytes32 voterState;
        for (uint256 i; i < voters.length; ++i) {
            voterState = keccak256(
                abi.encode(
                    voterState,
                    vault.balanceOf(voters[i]),
                    vault.getVotes(voters[i]),
                    vault.getOptimisticVotes(voters[i]),
                    vault.delegates(voters[i]),
                    vault.optimisticDelegates(voters[i])
                )
            );
        }
        return keccak256(
            abi.encode(
                _storageHash(address(vault), 14),
                voterState,
                vault.totalSupply(),
                vault.totalAssets(),
                vault.asset(),
                vault.unstakingDelay(),
                vault.tokenJar(),
                vault.getAllRewardTokens()
            )
        );
    }

    function _governanceState(System memory sys) private view returns (bytes32) {
        bytes32 roles;
        bytes32[5] memory roleIds = [bytes32(0), PROPOSER_ROLE, EXECUTOR_ROLE, CANCELLER_ROLE, OPTIMISTIC_PROPOSER_ROLE];
        for (uint256 i; i < roleIds.length; ++i) {
            for (uint256 j; j < sys.timelock.getRoleMemberCount(roleIds[i]); ++j) {
                roles = keccak256(abi.encode(roles, roleIds[i], sys.timelock.getRoleMember(roleIds[i], j)));
            }
        }
        return keccak256(
            abi.encode(
                _storageHash(address(sys.governor), 6),
                roles,
                sys.governor.timelock(),
                sys.governor.token(),
                sys.governor.votingDelay(),
                sys.governor.votingPeriod(),
                sys.governor.quorumNumerator(),
                sys.timelock.getMinDelay()
            )
        );
    }

    function _storageHash(address target, uint256 count) private view returns (bytes32 hash) {
        for (uint256 i; i < count; ++i) {
            hash = keccak256(abi.encode(hash, vm.load(target, bytes32(i))));
        }
    }

    function _implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _singleCall(address target, bytes memory callData)
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory data)
    {
        targets = new address[](1);
        values = new uint256[](1);
        data = new bytes[](1);
        targets[0] = target;
        data[0] = callData;
    }
}
