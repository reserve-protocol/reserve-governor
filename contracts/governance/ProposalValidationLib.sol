// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";

import { IOptimisticSelectorRegistry } from "../interfaces/IOptimisticSelectorRegistry.sol";
import { IReserveOptimisticGovernor } from "../interfaces/IReserveOptimisticGovernor.sol";

library ProposalValidationLib {
    /// Require proposal details are valid, for both optimistic and standard proposals
    function validateProposal(
        bool isOptimistic,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        IOptimisticSelectorRegistry selectorRegistry
    ) external view {
        // validate lengths

        require(
            targets.length == values.length && targets.length == calldatas.length,
            IGovernor.GovernorInvalidProposalLength(targets.length, calldatas.length, values.length)
        );

        require(targets.length != 0, IGovernor.GovernorInvalidProposalLength(0, 0, 0));

        // validate optimistic proposals only call (approved) functions

        for (uint256 i = 0; i < targets.length; i++) {
            address target = targets[i];

            if (!isOptimistic) {
                // pessimistic

                require(
                    target.code.length != 0 || calldatas[i].length == 0,
                    IReserveOptimisticGovernor.InvalidCall(target, calldatas[i])
                );
            } else {
                // optimistic

                require(
                    target.code.length != 0 && calldatas[i].length >= 4
                        && selectorRegistry.isAllowed(target, bytes4(calldatas[i])),
                    IReserveOptimisticGovernor.InvalidCall(target, calldatas[i])
                );
            }
        }
    }
}
