#!/usr/bin/env bash
set -euo pipefail

# Generate bytecode artifacts for contract deployment
# This script compiles contracts and embeds their bytecode into Solidity libraries

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACTS_DIR="$ROOT_DIR/contracts/artifacts"

cd "$ROOT_DIR"

echo "Building contracts..."
forge build --skip "test/**" --skip "contracts/artifacts/**"

generate_simple_artifact() {
    local contract_path="$1"
    local library_name="$2"
    local artifact_file="$3"
    local artifact_path="$ARTIFACTS_DIR/$artifact_file"

    echo "Generating artifact for $contract_path..."

    local bytecode
    bytecode=$(forge inspect "$contract_path" bytecode)

    if [[ -z "$bytecode" || "$bytecode" == "0x" ]]; then
        echo "Error: Could not get bytecode for $contract_path" >&2
        exit 1
    fi

    # Remove 0x prefix
    bytecode="${bytecode#0x}"

    cat > "$artifact_path" << EOF
// SPDX-License-Identifier: MIT
// AUTO-GENERATED FILE - DO NOT EDIT
// Run ./scripts/generate-artifacts.sh to regenerate
pragma solidity ^0.8.28;

import { DeployHelper } from "./DeployHelper.sol";

library ${library_name} {
    function deploy(bytes32 salt) internal returns (address) {
        return DeployHelper.deploy(initcode(), salt);
    }

    function deploy() internal returns (address) {
        return DeployHelper.deploy(initcode());
    }

    function initcode() internal pure returns (bytes memory) {
        return hex"${bytecode}";
    }
}
EOF

    echo "Updated $artifact_file"
}

generate_governor_artifact() {
    local artifact_path="$ARTIFACTS_DIR/ReserveOptimisticGovernorArtifact.sol"

    echo "Generating artifact for ReserveOptimisticGovernor (with library linking)..."

    local bytecode
    bytecode=$(forge inspect "contracts/governance/ReserveOptimisticGovernor.sol:ReserveOptimisticGovernor" bytecode)

    if [[ -z "$bytecode" || "$bytecode" == "0x" ]]; then
        echo "Error: Could not get bytecode for ReserveOptimisticGovernor" >&2
        exit 1
    fi

    # Remove 0x prefix
    bytecode="${bytecode#0x}"

    # Solidity library placeholders are "__$" + first 34 chars of keccak256("path:Library") + "$__"
    local proposal_lib_id="contracts/governance/lib/ProposalLib.sol:ProposalLib"
    local throttle_lib_id="contracts/governance/lib/ThrottleLib.sol:ThrottleLib"
    local proposal_placeholder
    local throttle_placeholder
    local proposal_hash
    local throttle_hash

    proposal_hash=$(cast keccak "$proposal_lib_id")
    throttle_hash=$(cast keccak "$throttle_lib_id")
    proposal_hash="${proposal_hash#0x}"
    throttle_hash="${throttle_hash#0x}"
    proposal_placeholder=$(printf '__$%s$__' "${proposal_hash:0:34}")
    throttle_placeholder=$(printf '__$%s$__' "${throttle_hash:0:34}")

    local proposal_count
    local throttle_count
    local stripped

    stripped="${bytecode//$proposal_placeholder/}"
    proposal_count=$(( (${#bytecode} - ${#stripped}) / ${#proposal_placeholder} ))
    stripped="${bytecode//$throttle_placeholder/}"
    throttle_count=$(( (${#bytecode} - ${#stripped}) / ${#throttle_placeholder} ))

    if [[ $proposal_count -eq 0 ]]; then
        echo "Error: Could not find ProposalLib placeholder in ReserveOptimisticGovernor bytecode" >&2
        exit 1
    fi

    if [[ $throttle_count -eq 0 ]]; then
        echo "Error: Could not find ThrottleLib placeholder in ReserveOptimisticGovernor bytecode" >&2
        exit 1
    fi

    echo "Found $proposal_count ProposalLib placeholder(s) and $throttle_count ThrottleLib placeholder(s)"

    local linked_template="$bytecode"
    linked_template="${linked_template//$proposal_placeholder/|proposalLibAddr|}"
    linked_template="${linked_template//$throttle_placeholder/|throttleLibAddr|}"

    if echo "$linked_template" | grep -qE '__\$[a-f0-9]{34}\$__'; then
        echo "Error: Found unknown unresolved library placeholders in ReserveOptimisticGovernor bytecode" >&2
        exit 1
    fi

    cat > "$artifact_path" << 'HEADER'
// SPDX-License-Identifier: MIT
// AUTO-GENERATED FILE - DO NOT EDIT
// Run ./scripts/generate-artifacts.sh to regenerate
pragma solidity ^0.8.28;

import { DeployHelper } from "./DeployHelper.sol";

library ReserveOptimisticGovernorDeployer {
    /// @notice Deploy ReserveOptimisticGovernor with linked ProposalLib/ThrottleLib
    /// @param proposalLib Address of the deployed ProposalLib
    /// @param throttleLib Address of the deployed ThrottleLib
    /// @param salt CREATE2 salt
    function deploy(address proposalLib, address throttleLib, bytes32 salt) internal returns (address) {
        return DeployHelper.deploy(initcode(proposalLib, throttleLib), salt);
    }

    /// @notice Deploy ReserveOptimisticGovernor with linked ProposalLib/ThrottleLib
    /// @param proposalLib Address of the deployed ProposalLib
    /// @param throttleLib Address of the deployed ThrottleLib
    function deploy(address proposalLib, address throttleLib) internal returns (address) {
        return DeployHelper.deploy(initcode(proposalLib, throttleLib));
    }

    /// @notice Get the initcode with the library addresses linked
    /// @param proposalLib Address of the deployed ProposalLib
    /// @param throttleLib Address of the deployed ThrottleLib
    function initcode(address proposalLib, address throttleLib) internal pure returns (bytes memory) {
        bytes20 proposalLibAddr = bytes20(proposalLib);
        bytes20 throttleLibAddr = bytes20(throttleLib);
        return abi.encodePacked(
HEADER

    local -a parts=()
    IFS='|' read -r -a parts <<< "$linked_template"

    # Generate abi.encodePacked arguments from hex chunks and address placeholders.
    # Keep hex literal chunks small to avoid Solidity parser limits with giant literals.
    local first=true
    local hex_chunk_size=2048
    for part in "${parts[@]}"; do
        if [[ -z "$part" ]]; then
            continue
        fi

        if [[ "$part" == "proposalLibAddr" || "$part" == "throttleLibAddr" ]]; then
            if [[ "$first" == "true" ]]; then
                echo "            $part" >> "$artifact_path"
                first=false
            else
                echo "            , $part" >> "$artifact_path"
            fi
            continue
        fi

        local remaining="$part"
        while [[ -n "$remaining" ]]; do
            local chunk="${remaining:0:$hex_chunk_size}"
            remaining="${remaining:$hex_chunk_size}"
            if [[ "$first" == "true" ]]; then
                echo "            hex\"${chunk}\"" >> "$artifact_path"
                first=false
            else
                echo "            , hex\"${chunk}\"" >> "$artifact_path"
            fi
        done
    done

    if [[ "$first" == "true" ]]; then
        echo "Error: Failed to generate initcode segments for ReserveOptimisticGovernor artifact" >&2
        exit 1
    fi

    cat >> "$artifact_path" << 'FOOTER'
        );
    }
}
FOOTER

    echo "Updated ReserveOptimisticGovernorArtifact.sol"
}

generate_deployer_artifact() {
    local artifact_path="$ARTIFACTS_DIR/DeployerArtifact.sol"

    echo "Generating artifact for ReserveOptimisticGovernorDeployer..."

    local bytecode
    bytecode=$(forge inspect "contracts/Deployer.sol:ReserveOptimisticGovernorDeployer" bytecode)

    if [[ -z "$bytecode" || "$bytecode" == "0x" ]]; then
        echo "Error: Could not get bytecode for ReserveOptimisticGovernorDeployer" >&2
        exit 1
    fi

    # Remove 0x prefix
    bytecode="${bytecode#0x}"

    cat > "$artifact_path" << EOF
// SPDX-License-Identifier: MIT
// AUTO-GENERATED FILE - DO NOT EDIT
// Run ./scripts/generate-artifacts.sh to regenerate
pragma solidity ^0.8.28;

import { DeployHelper } from "./DeployHelper.sol";

library ReserveOptimisticGovernorDeployerDeployer {
    function deploy(
        address stakingVaultImpl,
        address governorImpl,
        address timelockImpl,
        address selectorRegistryImpl,
        bytes32 salt
    ) internal returns (address) {
        return DeployHelper.deploy(
            abi.encodePacked(initcode(), abi.encode(stakingVaultImpl, governorImpl, timelockImpl, selectorRegistryImpl)),
            salt
        );
    }

    function deploy(
        address stakingVaultImpl,
        address governorImpl,
        address timelockImpl,
        address selectorRegistryImpl
    ) internal returns (address) {
        return deploy(stakingVaultImpl, governorImpl, timelockImpl, selectorRegistryImpl, bytes32(0));
    }

    function initcode() internal pure returns (bytes memory) {
        return hex"${bytecode}";
    }
}
EOF

    echo "Updated DeployerArtifact.sol"
}

# Generate artifacts for each contract using path:name format for disambiguation
generate_simple_artifact "contracts/staking/StakingVault.sol:StakingVault" "StakingVaultDeployer" "StakingVaultArtifact.sol"
generate_simple_artifact "contracts/governance/lib/ProposalLib.sol:ProposalLib" "ProposalLibDeployer" "ProposalLibArtifact.sol"
generate_simple_artifact "contracts/governance/lib/ThrottleLib.sol:ThrottleLib" "ThrottleLibDeployer" "ThrottleLibArtifact.sol"
generate_governor_artifact
generate_simple_artifact "contracts/governance/TimelockControllerOptimistic.sol:TimelockControllerOptimistic" "TimelockControllerOptimisticDeployer" "TimelockControllerOptimisticArtifact.sol"
generate_simple_artifact "contracts/governance/OptimisticSelectorRegistry.sol:OptimisticSelectorRegistry" "OptimisticSelectorRegistryDeployer" "OptimisticSelectorRegistryArtifact.sol"
generate_deployer_artifact

echo "All artifacts generated successfully!"
