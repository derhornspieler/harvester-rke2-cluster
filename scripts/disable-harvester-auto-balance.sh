#!/usr/bin/env bash
# disable-harvester-auto-balance.sh — disable Harvester VM Auto Balance addon
#
# Flips spec.enabled to false. Descheduler pods are stopped by Harvester's
# addon controller. The Addon object itself remains (set enabled=true again
# to re-enable with the same values). Use `kubectl delete -f addons/...` to
# fully remove.
#
# Usage:
#   ./scripts/disable-harvester-auto-balance.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-${REPO_ROOT}/kubeconfig-harvester.yaml}"

[[ -f "${KUBECONFIG_FILE}" ]] || { echo "kubeconfig not found: ${KUBECONFIG_FILE}" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not on PATH" >&2; exit 1; }

echo "=== Harvester VM Auto Balance — disable ==="
kubectl --kubeconfig="${KUBECONFIG_FILE}" -n kube-system \
  patch addon descheduler --type=merge -p '{"spec":{"enabled":false}}'

echo ""
echo "=== descheduler pods (should terminate shortly) ==="
kubectl --kubeconfig="${KUBECONFIG_FILE}" -n kube-system get pod -l app.kubernetes.io/name=descheduler 2>/dev/null || \
  echo "(no descheduler pods found — already disabled)"

echo ""
echo "To re-enable: ./scripts/apply-harvester-auto-balance.sh"
echo "To fully remove addon + RBAC:"
echo "  kubectl --kubeconfig=${KUBECONFIG_FILE} delete -f ${REPO_ROOT}/addons/harvester-vm-auto-balance.yaml"
echo "  kubectl --kubeconfig=${KUBECONFIG_FILE} delete -f ${REPO_ROOT}/addons/descheduler-metrics-rbac.yaml"
