#!/usr/bin/env bash
# destroy-cluster.sh — Destroy the RKE2 cluster and clean up Harvester resources
#
# This is a convenience wrapper around ./terraform.sh destroy.
# It preserves cloud credentials so you don't need to re-run prepare.sh.
#
# Usage:
#   ./destroy-cluster.sh              # Interactive (prompts for confirmation)
#   ./destroy-cluster.sh -auto-approve  # Non-interactive
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/terraform.sh" destroy "$@"
