// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { VotesUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/utils/VotesUpgradeable.sol";

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ContextUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import { NoncesUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import { EIP712Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";

import { IOptimisticVotes } from "@interfaces/IOptimisticVotes.sol";

/**
 * @title OptimisticVotesUpgradeable
 * @notice A 1:1 mirror of OpenZeppelin's {VotesUpgradeable}, tracking a *second*, independent delegation graph
 *         used exclusively for optimistic (veto) governance.
 *
 * @dev This is a base abstract contract that tracks optimistic voting units, which are a measure of veto power that can
 *      be transferred, and provides a system of vote delegation independent of the standard {VotesUpgradeable} graph.
 *      An account can therefore appoint one representative for standard proposals and a different one for vetoing
 *      optimistic proposals.
 *
 *      The full history of delegated optimistic votes (and of the optimistic total supply) is checkpointed on-chain so
 *      that governance can read veto power as-of a past timepoint. The deriving contract must implement
 *      {_getOptimisticVotingUnits} (typically the token balance) and call {_transferOptimisticVotingUnits} whenever
 *      those units move (typically from the token `_update` hook).
 *
 *      The optimistic graph reuses {VotesUpgradeable.VotesStorage} as its storage layout, but anchored at a distinct
 *      ERC-7201 slot so the two graphs never collide.
 */
abstract contract OptimisticVotesUpgradeable is
    Initializable,
    ContextUpgradeable,
    EIP712Upgradeable,
    NoncesUpgradeable,
    IOptimisticVotes
{
    using Checkpoints for Checkpoints.Trace208;

    bytes32 private constant OPTIMISTIC_DELEGATION_TYPEHASH =
        keccak256("OptimisticDelegation(address delegatee,uint256 nonce,uint256 expiry)");

    // keccak256(abi.encode(uint256(keccak256("reserve.storage.OptimisticVotes")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OptimisticVotesStorageLocation =
        0x70984a7d0b69c3ed645329f33455608f063bcf2582315816bc9835f4d0581600;

    /// @dev Reuses {VotesUpgradeable.VotesStorage} ({_delegatee}, {_delegateCheckpoints}, {_totalCheckpoints}).
    function _getOptimisticVotesStorage() private pure returns (VotesUpgradeable.VotesStorage storage $) {
        assembly {
            $.slot := OptimisticVotesStorageLocation
        }
    }

    /// @dev Emitted when an account changes their optimistic delegate.
    event OptimisticDelegateChanged(
        address indexed delegator, address indexed fromDelegate, address indexed toDelegate
    );

    /// @dev Emitted when a delegate's amount of optimistic votes changes.
    event OptimisticDelegateVotesChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes);

    function __OptimisticVotes_init() internal onlyInitializing { }

    function __OptimisticVotes_init_unchained() internal onlyInitializing { }

    /**
     * @dev Clock used for flagging checkpoints. Implemented by the deriving contract and shared with the standard
     *      {VotesUpgradeable} clock so both graphs checkpoint against the same timepoint.
     */
    function clock() public view virtual returns (uint48);

    /// @dev Returns the optimistic delegate that `account` has chosen.
    function optimisticDelegates(address account) public view virtual returns (address) {
        return _getOptimisticVotesStorage()._delegatee[account];
    }

    /// @dev Returns the current amount of optimistic votes that `account` has.
    function getOptimisticVotes(address account) public view virtual returns (uint256) {
        return _getOptimisticVotesStorage()._delegateCheckpoints[account].latest();
    }

    /**
     * @dev Returns the amount of optimistic votes that `account` had at a specific moment in the past.
     *
     * Requirements:
     *
     * - `timepoint` must be in the past.
     */
    function getPastOptimisticVotes(address account, uint256 timepoint) public view virtual returns (uint256) {
        VotesUpgradeable.VotesStorage storage $ = _getOptimisticVotesStorage();
        return $._delegateCheckpoints[account].upperLookupRecent(_validateOptimisticTimepoint(timepoint));
    }

    /**
     * @dev Returns the total supply of optimistic votes available at a specific moment in the past.
     *
     * NOTE: As with {VotesUpgradeable}, this is the sum of all available optimistic votes, which is not necessarily the
     * sum of all delegated optimistic votes. Undelegated units still count toward the total supply.
     *
     * Requirements:
     *
     * - `timepoint` must be in the past.
     */
    function getPastOptimisticTotalSupply(uint256 timepoint) public view virtual returns (uint256) {
        VotesUpgradeable.VotesStorage storage $ = _getOptimisticVotesStorage();
        return $._totalCheckpoints.upperLookupRecent(_validateOptimisticTimepoint(timepoint));
    }

    /// @dev Returns the current total supply of optimistic votes.
    function _getOptimisticTotalSupply() internal view virtual returns (uint256) {
        return _getOptimisticVotesStorage()._totalCheckpoints.latest();
    }

    /// @dev Delegates optimistic votes from the sender to `delegatee`.
    function delegateOptimistic(address delegatee) public virtual {
        _delegateOptimistic(_msgSender(), delegatee);
    }

    /// @dev Delegates optimistic votes from signer to `delegatee`.
    function delegateOptimisticBySig(address delegatee, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s)
        public
        virtual
    {
        if (block.timestamp > expiry) {
            revert IVotes.VotesExpiredSignature(expiry);
        }
        address signer = ECDSA.recover(
            _hashTypedDataV4(keccak256(abi.encode(OPTIMISTIC_DELEGATION_TYPEHASH, delegatee, nonce, expiry))), v, r, s
        );
        _useCheckedNonce(signer, nonce);
        _delegateOptimistic(signer, delegatee);
    }

    /// @inheritdoc IOptimisticVotes
    function numOptimisticCheckpoints(address account) external view virtual returns (uint32) {
        return SafeCast.toUint32(_getOptimisticVotesStorage()._delegateCheckpoints[account].length());
    }

    /// @inheritdoc IOptimisticVotes
    function optimisticCheckpoints(address account, uint32 pos)
        external
        view
        virtual
        returns (Checkpoints.Checkpoint208 memory)
    {
        return _getOptimisticVotesStorage()._delegateCheckpoints[account].at(pos);
    }

    /**
     * @dev Delegate all of `account`'s optimistic voting units to `delegatee`.
     *
     * Emits events {OptimisticDelegateChanged} and {OptimisticDelegateVotesChanged}.
     */
    function _delegateOptimistic(address account, address delegatee) internal virtual {
        VotesUpgradeable.VotesStorage storage $ = _getOptimisticVotesStorage();
        address oldDelegate = optimisticDelegates(account);
        $._delegatee[account] = delegatee;

        emit OptimisticDelegateChanged(account, oldDelegate, delegatee);
        _moveOptimisticDelegateVotes(oldDelegate, delegatee, _getVotingUnits(account));
    }

    /**
     * @dev Transfers, mints, or burns optimistic voting units. To register a mint, `from` should be zero. To register
     *      a burn, `to` should be zero. The optimistic total supply is adjusted with mints and burns.
     */
    function _transferOptimisticVotingUnits(address from, address to, uint256 amount) internal virtual {
        VotesUpgradeable.VotesStorage storage $ = _getOptimisticVotesStorage();
        if (from == address(0)) {
            _pushOptimistic($._totalCheckpoints, _addOptimistic, SafeCast.toUint208(amount));
        }
        if (to == address(0)) {
            _pushOptimistic($._totalCheckpoints, _subtractOptimistic, SafeCast.toUint208(amount));
        }
        _moveOptimisticDelegateVotes(optimisticDelegates(from), optimisticDelegates(to), amount);
    }

    /// @dev Moves delegated optimistic votes from one delegate to another.
    function _moveOptimisticDelegateVotes(address from, address to, uint256 amount) internal virtual {
        VotesUpgradeable.VotesStorage storage $ = _getOptimisticVotesStorage();
        if (from != to && amount > 0) {
            if (from != address(0)) {
                (uint256 oldValue, uint256 newValue) =
                    _pushOptimistic($._delegateCheckpoints[from], _subtractOptimistic, SafeCast.toUint208(amount));
                emit OptimisticDelegateVotesChanged(from, oldValue, newValue);
            }
            if (to != address(0)) {
                (uint256 oldValue, uint256 newValue) =
                    _pushOptimistic($._delegateCheckpoints[to], _addOptimistic, SafeCast.toUint208(amount));
                emit OptimisticDelegateVotesChanged(to, oldValue, newValue);
            }
        }
    }

    /// @dev Validate that a timepoint is in the past, and return it as a uint48.
    /// @dev Reuses {VotesUpgradeable.ERC5805FutureLookup} so the failure mode matches the standard votes graph.
    function _validateOptimisticTimepoint(uint256 timepoint) internal view returns (uint48) {
        uint48 currentTimepoint = clock();
        if (timepoint >= currentTimepoint) {
            revert VotesUpgradeable.ERC5805FutureLookup(timepoint, currentTimepoint);
        }
        return SafeCast.toUint48(timepoint);
    }

    function _pushOptimistic(
        Checkpoints.Trace208 storage store,
        function(uint208, uint208) view returns (uint208) op,
        uint208 delta
    ) private returns (uint208 oldValue, uint208 newValue) {
        return store.push(clock(), op(store.latest(), delta));
    }

    function _addOptimistic(uint208 a, uint208 b) private pure returns (uint208) {
        return a + b;
    }

    function _subtractOptimistic(uint208 a, uint208 b) private pure returns (uint208) {
        return a - b;
    }

    /**
     * @dev Must return the voting units held by an account. Shares the same signature (and, in practice, the same
     *      `balanceOf` implementation) as {VotesUpgradeable-_getVotingUnits}, so a single override in the deriving
     *      contract backs both the standard and optimistic graphs with identical units.
     */
    function _getVotingUnits(address) internal view virtual returns (uint256);
}
