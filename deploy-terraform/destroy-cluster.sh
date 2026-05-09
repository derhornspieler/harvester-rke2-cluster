#!/usr/bin/env bash
# destroy-cluster.sh — Destroy an RKE2 cluster and clean up Harvester resources
#
# Convenience wrapper around `./terraform.sh --cluster <name> destroy`.
# Preserves cloud credentials so you don't need to re-run prepare.sh.
#
# Usage:
#   ./destroy-cluster.sh --cluster rke2-test                  # Interactive
#   ./destroy-cluster.sh --cluster rke2-prod -auto-approve    # Non-interactive
#   CLUSTER=rke2-test ./destroy-cluster.sh                    # Same via env var
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --cluster flag (if any) must come before "destroy". Pass-through args follow.
exec "${SCRIPT_DIR}/terraform.sh" "$@" destroy
