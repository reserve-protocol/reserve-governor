// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { VotesUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/utils/VotesUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { IERC6372 } from "@openzeppelin/contracts/interfaces/IERC6372.sol";
import { Time } from "@openzeppelin/contracts/utils/types/Time.sol";
import { Test } from "forge-std/Test.sol";

import { ERC20OptimisticVotesUpgradeable } from "@staking/ERC20OptimisticVotesUpgradeable.sol";

contract IntegralGasToken is ERC20Upgradeable, ERC20OptimisticVotesUpgradeable {
    function initialize() external initializer {
        __ERC20_init("Integral Gas Token", "IGT");
        __EIP712_init("Integral Gas Token", "1");
        __ERC20OptimisticVotes_init();
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20OptimisticVotesUpgradeable)
    {
        super._update(from, to, value);
    }

    function clock() public view override(VotesUpgradeable, IERC6372) returns (uint48) {
        return Time.timestamp();
    }

    function CLOCK_MODE() public pure override(VotesUpgradeable, IERC6372) returns (string memory) {
        return "mode=timestamp";
    }
}

contract IntegralGasBenchmarkTest is Test {
    IntegralGasToken private token;

    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant DELEGATE_A = address(0xDA);
    address private constant DELEGATE_B = address(0xDB);

    function setUp() public {
        vm.warp(1_000_000);
        token = new IntegralGasToken();
        token.initialize();
    }

    function _coolIntegralCall() private {
        vm.cool(address(token));
        // When running against the parent, also cool its linked VoteIntegralLib (see design notes).
    }

    /// @dev Each measured mutating call starts after vm.cool(token), so the target account and
    ///      its previously touched storage are cold. gasleft includes the test-to-token CALL
    ///      opcode and calldata cost, which are identical for both source snapshots.
    function testGas_mutations() public {
        _coolIntegralCall();
        uint256 gasBefore = gasleft();
        token.mint(ALICE, 1_000 ether);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("cold fresh mint", gasUsed);

        _coolIntegralCall();
        vm.prank(ALICE);
        gasBefore = gasleft();
        token.delegate(DELEGATE_A);
        gasUsed = gasBefore - gasleft();
        emit log_named_uint("cold initial delegate", gasUsed);

        token.mint(BOB, 1_000 ether);
        vm.prank(BOB);
        token.delegate(DELEGATE_B);

        vm.warp(block.timestamp + 10);
        _coolIntegralCall();
        gasBefore = gasleft();
        token.mint(ALICE, 100 ether);
        gasUsed = gasBefore - gasleft();
        emit log_named_uint("cold later mint to delegated account", gasUsed);

        vm.warp(block.timestamp + 10);
        _coolIntegralCall();
        vm.prank(ALICE);
        gasBefore = gasleft();
        token.transfer(BOB, 10 ether);
        gasUsed = gasBefore - gasleft();
        emit log_named_uint("cold transfer across distinct delegates", gasUsed);

        // The first transfer creates this timestamp's integral/checkpoint entries. The measured
        // second transfer must update/coalesce the same timestamp rather than append another.
        vm.warp(block.timestamp + 10);
        vm.prank(ALICE);
        token.transfer(BOB, 1 ether);
        _coolIntegralCall();
        vm.prank(ALICE);
        gasBefore = gasleft();
        token.transfer(BOB, 1 ether);
        gasUsed = gasBefore - gasleft();
        emit log_named_uint("cold same-timestamp coalesced transfer", gasUsed);

        vm.warp(block.timestamp + 10);
        _coolIntegralCall();
        gasBefore = gasleft();
        token.burn(ALICE, 10 ether);
        gasUsed = gasBefore - gasleft();
        emit log_named_uint("cold later burn from delegated account", gasUsed);

        assertEq(token.numCheckpoints(DELEGATE_A), 5);
        assertEq(token.numCheckpoints(DELEGATE_B), 3);
    }

    /// @dev Creates exactly 65 standard vote checkpoints for DELEGATE_A. Cold lookups call
    ///      vm.cool(token) first; each warm lookup immediately repeats the same query.
    function testGas_lookupWith65Checkpoints() public {
        token.mint(ALICE, 1_000 ether);
        vm.prank(ALICE);
        token.delegate(DELEGATE_A);

        uint48 midpoint;
        for (uint256 i = 1; i < 65; ++i) {
            vm.warp(block.timestamp + 10);
            token.mint(ALICE, 1 ether);
            if (i == 32) {
                midpoint = uint48(block.timestamp);
            }
        }
        assertEq(token.numCheckpoints(DELEGATE_A), 65);

        vm.warp(block.timestamp + 10);

        _coolIntegralCall();
        uint256 gasBefore = gasleft();
        uint256 historical = token.getPastVotesIntegral(DELEGATE_A, midpoint);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("cold historical lookup, 65 checkpoints", gasUsed);

        gasBefore = gasleft();
        uint256 historicalWarm = token.getPastVotesIntegral(DELEGATE_A, midpoint);
        gasUsed = gasBefore - gasleft();
        emit log_named_uint("warm historical lookup, 65 checkpoints", gasUsed);

        _coolIntegralCall();
        gasBefore = gasleft();
        uint256 current = token.getPastVotesIntegral(DELEGATE_A, block.timestamp);
        gasUsed = gasBefore - gasleft();
        emit log_named_uint("cold current lookup, 65 checkpoints", gasUsed);

        gasBefore = gasleft();
        uint256 currentWarm = token.getPastVotesIntegral(DELEGATE_A, block.timestamp);
        gasUsed = gasBefore - gasleft();
        emit log_named_uint("warm current lookup, 65 checkpoints", gasUsed);

        assertEq(historicalWarm, historical);
        assertEq(currentWarm, current);
        assertGt(current, historical);
    }
}
