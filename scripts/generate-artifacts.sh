#!/usr/bin/env bash
set -euo pipefail

# Generate deployer libraries from Forge artifacts using forge-pack.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACTS_DIR="$ROOT_DIR/contracts/artifacts"

CONTRACTS=(
    "StakingVault"
    "ProposalLib"
    "ThrottleLib"
    "ReserveOptimisticGovernor"
    "TimelockControllerOptimistic"
    "OptimisticSelectorRegistry"
    "ReserveOptimisticGovernorDeployer"
    "ReserveOptimisticGovernanceVersionRegistry"
    "RewardTokenRegistry"
)

cd "$ROOT_DIR"

echo "Building contracts..."
forge clean
forge build --skip "test/**" --skip "contracts/artifacts/**"

echo "Generating deployer libraries with forge-pack..."
rm -rf "$ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR"

cat > "$ARTIFACTS_DIR/README.md" <<'EOF'
# Artifacts

NOT INTENDED FOR PRODUCTION USE
EOF

for contract in "${CONTRACTS[@]}"; do
    pnpm dlx forge-pack@latest "$contract" --out "./out" --output "$ARTIFACTS_DIR" --pragma "^0.8.28"
done

echo "All artifacts generated successfully!"
