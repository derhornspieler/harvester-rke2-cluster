#!/usr/bin/env bash
# destroy-cluster.sh — Delete the RKE2 cluster via Rancher API
#
# This is a convenience wrapper around rancher-api-deploy.sh --delete.
#
# Usage:
#   ./destroy-cluster.sh              # Interactive (prompts for confirmation)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/rancher-api-deploy.sh" --delete "$@"
