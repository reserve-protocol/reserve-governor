#!/usr/bin/env bash
set -euo pipefail

# Source repository and pinned commit
REPO="reserve-protocol/reserve-index-dtf"
COMMIT="907e80f979a48b5d665a6565d97baa43138eb6c8"

BASE_URL="https://raw.githubusercontent.com/${REPO}/${COMMIT}/contracts"
OUT_DIR="$(dirname "$0")/../test/catalogue"

mkdir -p "$OUT_DIR"

# Files to fetch: <remote_path> <local_filename>
FILES=(
    "staking/StakingVault.sol StakingVault.sol"
    "staking/UnstakingManager.sol UnstakingManager.sol"
    "utils/Versioned.sol Versioned.sol"
)

for entry in "${FILES[@]}"; do
    read -r remote local <<< "$entry"
    echo "Fetching ${remote} -> ${OUT_DIR}/${local}"
    curl -sf "${BASE_URL}/${remote}" -o "${OUT_DIR}/${local}"
done

# Patch imports: all catalogue files live in a flat directory
sed -i '' 's|"../utils/Versioned.sol"|"./Versioned.sol"|g' "${OUT_DIR}/StakingVault.sol"

echo "Catalogue updated from ${REPO}@${COMMIT}"
