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

    # Extract the library placeholder pattern (format: __$hash$__)
    # The placeholder is 40 characters (20 bytes = address size)
    local placeholder
    placeholder=$(echo "$bytecode" | grep -oE '__\$[a-f0-9]{34}\$__' | head -1 || true)

    if [[ -z "$placeholder" ]]; then
        echo "Error: Could not find library placeholder in ReserveOptimisticGovernor bytecode" >&2
        exit 1
    fi

    # Split bytecode at the placeholder(s) - there may be multiple occurrences
    # We'll use a runtime linking approach in Solidity

    cat > "$artifact_path" << 'HEADER'
// SPDX-License-Identifier: MIT
// AUTO-GENERATED FILE - DO NOT EDIT
// Run ./scripts/generate-artifacts.sh to regenerate
pragma solidity ^0.8.28;

import { DeployHelper } from "./DeployHelper.sol";

library ReserveOptimisticGovernorDeployer {
    /// @notice Deploy ReserveOptimisticGovernor with linked ThrottleLib
    /// @param proposalValidationLib Address of the deployed ThrottleLib
    /// @param salt CREATE2 salt
    function deploy(address proposalValidationLib, bytes32 salt) internal returns (address) {
        return DeployHelper.deploy(initcode(proposalValidationLib), salt);
    }

    /// @notice Deploy ReserveOptimisticGovernor with linked ThrottleLib
    /// @param proposalValidationLib Address of the deployed ThrottleLib
    function deploy(address proposalValidationLib) internal returns (address) {
        return DeployHelper.deploy(initcode(proposalValidationLib));
    }

    /// @notice Get the initcode with the library address linked
    /// @param proposalValidationLib Address of the deployed ThrottleLib
    function initcode(address proposalValidationLib) internal pure returns (bytes memory) {
        bytes20 libAddr = bytes20(proposalValidationLib);
        return abi.encodePacked(
HEADER

    # Now we need to generate the bytecode parts split by the placeholder
    # First, let's count how many placeholders there are
    local placeholder_count
    placeholder_count=$(echo "$bytecode" | grep -o "$placeholder" | wc -l | tr -d ' ')

    echo "Found $placeholder_count library placeholder(s)"

    # Split the bytecode at each placeholder
    local parts=()
    local remaining="$bytecode"
    local idx=0

    while [[ "$remaining" == *"$placeholder"* ]]; do
        local before="${remaining%%${placeholder}*}"
        parts+=("$before")
        remaining="${remaining#*${placeholder}}"
        ((idx++)) || true
    done
    parts+=("$remaining")

    # Generate the abi.encodePacked arguments
    local first=true
    for i in "${!parts[@]}"; do
        local part="${parts[$i]}"
        if [[ -n "$part" ]]; then
            if [[ "$first" == "true" ]]; then
                first=false
            else
                echo "," >> "$artifact_path"
            fi
            echo "            hex\"${part}\"" >> "$artifact_path"
        fi
        # Add libAddr after each part except the last
        if [[ $i -lt $((${#parts[@]} - 1)) ]]; then
            if [[ "$first" == "true" ]]; then
                first=false
            else
                echo "," >> "$artifact_path"
            fi
            echo "            libAddr" >> "$artifact_path"
        fi
    done

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
