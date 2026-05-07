#!/usr/bin/env bash
# apply-harvester-auto-balance.sh — enable Harvester VM Auto Balance addon
#
# Applies addons/harvester-vm-auto-balance.yaml against the Harvester cluster
# using kubeconfig-harvester.yaml (management kubeconfig). Idempotent:
# re-apply updates the spec; addon status is reconciled by Harvester.
#
# Usage:
#   ./scripts/apply-harvester-auto-balance.sh
#   ./scripts/apply-harvester-auto-balance.sh --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST="${REPO_ROOT}/addons/harvester-vm-auto-balance.yaml"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-${REPO_ROOT}/kubeconfig-harvester.yaml}"

DRY_RUN=false
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      grep -E '^# ' "$0" | head -15 | sed 's|^# \{0,1\}||'
      exit 0
      ;;
    *) echo "Unknown option: ${arg}" >&2; exit 1 ;;
  esac
done

[[ -f "${MANIFEST}" ]] || { echo "manifest not found: ${MANIFEST}" >&2; exit 1; }
[[ -f "${KUBECONFIG_FILE}" ]] || { echo "kubeconfig not found: ${KUBECONFIG_FILE}" >&2; exit 1; }

command -v kubectl >/dev/null || { echo "kubectl not on PATH" >&2; exit 1; }

echo "=== Harvester VM Auto Balance — apply ==="
echo "Manifest:   ${MANIFEST}"
echo "Kubeconfig: ${KUBECONFIG_FILE}"
echo ""

if [[ "${DRY_RUN}" == true ]]; then
  kubectl --kubeconfig="${KUBECONFIG_FILE}" apply -f "${MANIFEST}" --dry-run=server
  echo ""
  echo "[DRY-RUN] no changes applied"
  exit 0
fi

kubectl --kubeconfig="${KUBECONFIG_FILE}" apply -f "${MANIFEST}"
echo ""
echo "=== addon status (wait up to 60s for reconcile) ==="
# Harvester ships the descheduler Addon at kube-system/descheduler with display
# label "virtual-machine-auto-balance" — our manifest patches THAT object.
for i in {1..12}; do
  status=$(kubectl --kubeconfig="${KUBECONFIG_FILE}" -n kube-system get addon descheduler -o jsonpath='{.status.status}' 2>/dev/null || echo "")
  echo "  attempt $i: status=${status:-pending}"
  [[ "${status}" == "AddonDeploySuccessful" ]] && break
  sleep 5
done

echo ""
echo "=== descheduler pods ==="
kubectl --kubeconfig="${KUBECONFIG_FILE}" -n kube-system get pod -l app.kubernetes.io/name=descheduler 2>/dev/null || \
  echo "(descheduler pods not yet visible — addon may still be installing)"

echo ""
echo "=== next steps ==="
echo "  - watch for live-migration events: kubectl --kubeconfig=${KUBECONFIG_FILE} get vmim -A --watch"
echo "  - disable/rollback:                ./scripts/disable-harvester-auto-balance.sh"
