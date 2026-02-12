// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Roles
bytes32 constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE"); // 0xb09aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1
bytes32 constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE"); // 0xd8aa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63
bytes32 constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE"); // 0xfd643c72710c63c0180259aba6b2d05451e3591a24e58b62239378085726f783
bytes32 constant OPTIMISTIC_PROPOSER_ROLE = keccak256("OPTIMISTIC_PROPOSER_ROLE"); // 0x26f49d08685d9cdd4951a7470bc8fbe9dd0f00419c1a44c1b89f845867ae12e0

// ReserveOptimisticGovernor
uint256 constant MIN_OPTIMISTIC_VETO_DELAY = 1 seconds;
uint256 constant MIN_OPTIMISTIC_VETO_PERIOD = 30 minutes;

// ProposalThrottle
uint256 constant MAX_PROPOSAL_THROTTLE_CAPACITY = 10; // 10 per day
uint256 constant THROTTLE_PERIOD = 1 days;
