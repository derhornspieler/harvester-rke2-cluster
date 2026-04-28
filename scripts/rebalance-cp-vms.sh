#!/usr/bin/env bash
# rebalance-cp-vms.sh — trigger live-migration for CP VMs after affinity patch
set -euo pipefail

CLUSTER="${1:-}"
if [[ -z "${CLUSTER}" ]]; then
  echo "Usage: $0 <cluster-name>  (e.g., rke2-test)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KC="${SCRIPT_DIR}/../kubeconfig-harvester-cloud-cred.yaml"

CP_VMS=$(kubectl --kubeconfig="${KC}" -n "${CLUSTER}" get vm -o name \
  | grep "controlplane" || true)

if [[ -z "${CP_VMS}" ]]; then
  echo "No CP VMs found in namespace ${CLUSTER}"
  exit 1
fi

echo "Current CP VM placement:"
kubectl --kubeconfig="${KC}" -n "${CLUSTER}" get vmi -o custom-columns=NAME:.metadata.name,NODE:.status.nodeName | grep controlplane

for vm in ${CP_VMS}; do
  name="${vm#virtualmachine.kubevirt.io/}"
  echo ">>> migrating ${name}"
  cat <<EOF | kubectl --kubeconfig="${KC}" -n "${CLUSTER}" apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  generateName: cp-rebalance-
  namespace: ${CLUSTER}
spec:
  vmiName: ${name}
EOF
  sleep 5
done

echo ""
echo "Waiting 60s for migrations to settle..."
sleep 60
echo "Post-migration placement:"
kubectl --kubeconfig="${KC}" -n "${CLUSTER}" get vmi -o custom-columns=NAME:.metadata.name,NODE:.status.nodeName | grep controlplane
