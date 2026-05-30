// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { VotesUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/utils/VotesUpgradeable.sol";
import {
    ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

import { IOptimisticVotes } from "@interfaces/IOptimisticVotes.sol";

/**
 * @title ERC20OptimisticVotesUpgradeable
 * @notice ERC20Votes extension that tracks a second, independent delegation graph for optimistic governance.
 *
 * @dev The optimistic graph uses the same ERC20 voting units as {ERC20VotesUpgradeable}, but stores delegate and
 *      checkpoint state at a separate ERC-7201 slot. Token mint, burn, and transfer events update both graphs through
 *      {_update}.
 */
abstract contract ERC20OptimisticVotesUpgradeable is ERC20VotesUpgradeable, IOptimisticVotes {
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

    function __ERC20OptimisticVotes_init() internal onlyInitializing {
        __ERC20Votes_init();
        __ERC20OptimisticVotes_init_unchained();
    }

    function __ERC20OptimisticVotes_init_unchained() internal onlyInitializing { }

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
        return $._delegateCheckpoints[account].upperLookupRecent(_validateTimepoint(timepoint));
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
        return $._totalCheckpoints.upperLookupRecent(_validateTimepoint(timepoint));
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
    function numOptimisticCheckpoints(address account) public view virtual returns (uint32) {
        return _numOptimisticCheckpoints(account);
    }

    /// @inheritdoc IOptimisticVotes
    function optimisticCheckpoints(address account, uint32 pos)
        public
        view
        virtual
        returns (Checkpoints.Checkpoint208 memory)
    {
        return _optimisticCheckpoints(account, pos);
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

    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);
        _transferOptimisticVotingUnits(from, to, value);
    }

    /**
     * @dev Transfers, mints, or burns optimistic voting units. To register a mint, `from` should be zero. To register
     *      a burn, `to` should be zero. The optimistic total supply is adjusted with mints and burns.
     */
    function _transferOptimisticVotingUnits(address from, address to, uint256 amount) internal virtual {
        VotesUpgradeable.VotesStorage storage $ = _getOptimisticVotesStorage();
        uint208 safeAmount = SafeCast.toUint208(amount);

        if (from == address(0)) {
            _pushOptimistic($._totalCheckpoints, $._totalCheckpoints.latest() + safeAmount);
        }
        if (to == address(0)) {
            _pushOptimistic($._totalCheckpoints, $._totalCheckpoints.latest() - safeAmount);
        }
        _moveOptimisticDelegateVotes(optimisticDelegates(from), optimisticDelegates(to), amount);
    }

    /// @dev Moves delegated optimistic votes from one delegate to another.
    function _moveOptimisticDelegateVotes(address from, address to, uint256 amount) internal virtual {
        VotesUpgradeable.VotesStorage storage $ = _getOptimisticVotesStorage();
        if (from != to && amount > 0) {
            uint208 safeAmount = SafeCast.toUint208(amount);

            if (from != address(0)) {
                (uint256 oldValue, uint256 newValue) =
                    _pushOptimistic($._delegateCheckpoints[from], $._delegateCheckpoints[from].latest() - safeAmount);
                emit OptimisticDelegateVotesChanged(from, oldValue, newValue);
            }
            if (to != address(0)) {
                (uint256 oldValue, uint256 newValue) =
                    _pushOptimistic($._delegateCheckpoints[to], $._delegateCheckpoints[to].latest() + safeAmount);
                emit OptimisticDelegateVotesChanged(to, oldValue, newValue);
            }
        }
    }

    /// @dev Get number of optimistic checkpoints for `account`.
    function _numOptimisticCheckpoints(address account) internal view virtual returns (uint32) {
        return SafeCast.toUint32(_getOptimisticVotesStorage()._delegateCheckpoints[account].length());
    }

    /// @dev Get the `pos`-th optimistic checkpoint for `account`.
    function _optimisticCheckpoints(address account, uint32 pos)
        internal
        view
        virtual
        returns (Checkpoints.Checkpoint208 memory)
    {
        return _getOptimisticVotesStorage()._delegateCheckpoints[account].at(pos);
    }

    function _pushOptimistic(Checkpoints.Trace208 storage store, uint208 value)
        private
        returns (uint208 oldValue, uint208 newValue)
    {
        return store.push(clock(), value);
    }
}
