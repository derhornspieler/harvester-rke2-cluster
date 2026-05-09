#!/usr/bin/env bash
# =============================================================================
# nuke-cluster.sh — Nuclear cleanup for RKE2 cluster on Harvester via Rancher
# =============================================================================
# Use this when terraform destroy fails or leaves orphaned resources. This
# script bypasses Terraform entirely and removes all cluster resources directly
# via the Rancher API and Harvester kubectl, then wipes Terraform state.
#
# WARNING: This is a destructive, irreversible operation. The target cluster
#          and ALL of its resources will be permanently deleted.
#
# Usage:
#   ./nuke-cluster.sh              # Interactive (prompts for confirmation)
#   ./nuke-cluster.sh -y           # Skip confirmation
#   ./nuke-cluster.sh --yes        # Skip confirmation
#   ./nuke-cluster.sh -h           # Show help
# =============================================================================

set -euo pipefail

# --- Colors & Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()       { log_error "$*"; exit 1; }

# --- Constants ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARVESTER_KUBECONFIG="${SCRIPT_DIR}/kubeconfig-harvester.yaml"
KUBECTL="kubectl --kubeconfig=${HARVESTER_KUBECONFIG}"

# Track pass/fail for the final summary
declare -A CHECK_RESULTS

# --- Helper Functions ---

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Nuclear cleanup for the RKE2 cluster when normal terraform destroy fails or
leaves orphaned resources. This script bypasses Terraform and removes all
cluster resources directly via the Rancher API and Harvester kubectl.

WARNING: This is IRREVERSIBLE. The cluster and all its resources will be
permanently deleted.

Options:
  --env FILE    Path to env file (default: .env).
                Accepts absolute paths or paths relative to CWD, then script dir.
                Example: ./nuke-cluster.sh --env .env.rke2-test -y
  -y, --yes     Skip interactive confirmation
  -h, --help    Show this help message and exit

Steps performed (in order):
  1. Delete cluster from Rancher API (with finalizer cleanup)
  2. Delete orphaned CAPI machines in fleet-default
  3. Delete CAPI parent objects (Clusters, MachineDeployments, MachineSets,
     RKEControlPlanes, RKEBootstraps, etcd snapshots, management clusters)
  4. Force-delete all VMs and VMIs in the VM namespace
  5. Clean up Rancher resources (HarvesterConfigs, Fleet bundles)
  6. Clean up orphaned secrets and RBAC in fleet-default and Harvester
  7. Clean up Harvester resources (PVCs, DataVolumes, namespace leftovers)
  8. Wipe Terraform state
  9. Final verification

Prerequisites:
  - kubectl, terraform, jq, curl must be installed
  - kubeconfig-harvester.yaml must exist (or 'harvester' context in ~/.kube/config)
  - env file must contain RANCHER_URL, RANCHER_TOKEN, CLUSTER_NAME, VM_NAMESPACE, PRIVATE_CA_PEM_FILE
EOF
  exit 0
}

check_prerequisites() {
  local missing=()
  for cmd in kubectl terraform jq curl; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}"
  fi
  log_ok "Prerequisites found: kubectl, terraform, jq, curl"
}

check_connectivity() {
  if [[ ! -f "$HARVESTER_KUBECONFIG" ]]; then
    log_info "Harvester kubeconfig not found, extracting from ~/.kube/config (context: harvester)..."
    if kubectl config view --minify --context=harvester --raw > "$HARVESTER_KUBECONFIG" 2>/dev/null && [[ -s "$HARVESTER_KUBECONFIG" ]]; then
      chmod 600 "$HARVESTER_KUBECONFIG"
      log_ok "Harvester kubeconfig extracted to ${HARVESTER_KUBECONFIG}"
    else
      rm -f "$HARVESTER_KUBECONFIG"
      die "Harvester kubeconfig not found: ${HARVESTER_KUBECONFIG}"
    fi
  fi
  if ! $KUBECTL cluster-info &>/dev/null; then
    die "Cannot connect to Harvester cluster via ${HARVESTER_KUBECONFIG}"
  fi
  log_ok "Harvester cluster is reachable"
}

load_config() {
  local env_file="${ENV_FILE:-${SCRIPT_DIR}/.env}"
  [[ -f "${env_file}" ]] || die "env file not found: ${env_file}"
  log_info "Loading ${env_file}..."
  # shellcheck source=/dev/null
  source "${env_file}"

  [[ -z "${RANCHER_URL:-}" ]]    && die "RANCHER_URL not set in .env"
  [[ -z "${RANCHER_TOKEN:-}" ]]  && die "RANCHER_TOKEN not set in .env"
  [[ -z "${CLUSTER_NAME:-}" ]]   && die "CLUSTER_NAME not set in .env"
  [[ -z "${VM_NAMESPACE:-}" ]]   && die "VM_NAMESPACE not set in .env"

  AUTH_HEADER="Authorization: Bearer ${RANCHER_TOKEN}"

  log_ok "Config loaded: cluster=${CLUSTER_NAME}, namespace=${VM_NAMESPACE}"
  log_info "Rancher: ${RANCHER_URL}"
}

# Rancher API helper: rancher_api METHOD PATH [DATA]
# Create a temporary kubeconfig for Rancher API access with optional CA verification
_create_rancher_kubeconfig() {
  local tmpfile
  tmpfile=$(mktemp)

  # Try to get private CA PEM; if available, use it for TLS verification
  local private_ca_pem ca_data cert_auth_line
  if [[ -n "${PRIVATE_CA_PEM_FILE:-}" && -f "${PRIVATE_CA_PEM_FILE}" ]]; then
    private_ca_pem=$(cat "${PRIVATE_CA_PEM_FILE}")
  else
    private_ca_pem=""
  fi

  if [[ -n "$private_ca_pem" ]]; then
    # Base64 encode the CA PEM for kubeconfig
    ca_data=$(echo "$private_ca_pem" | base64 -w0)
    cert_auth_line="    certificate-authority-data: ${ca_data}"
  else
    # Fall back to insecure when CA not available
    cert_auth_line="    insecure-skip-tls-verify: true"
  fi

  cat > "$tmpfile" <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: ${RANCHER_URL}/k8s/clusters/local
${cert_auth_line}
  name: rancher-local
contexts:
- context:
    cluster: rancher-local
    user: rancher-token
  name: rancher-local
current-context: rancher-local
users:
- name: rancher-token
  user:
    token: ${RANCHER_TOKEN}
KUBECONFIG
  chmod 600 "$tmpfile"
  echo "$tmpfile"
}

rancher_api() {
  local method="$1" path="$2" data="${3:-}"
  local url="${RANCHER_URL}${path}"
  local args=(-sk -X "${method}" -H "${AUTH_HEADER}" -H "Content-Type: application/json")
  if [[ -n "$data" ]]; then
    args+=(-d "$data")
  fi
  curl "${args[@]}" "$url" 2>/dev/null
}

# --- Step Functions ---

step_delete_cluster() {
  echo
  log_info "=== Step 1/9: Delete cluster from Rancher API ==="

  # Check if cluster exists
  local http_code
  http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "${AUTH_HEADER}" \
    "${RANCHER_URL}/v1/provisioning.cattle.io.clusters/fleet-default/${CLUSTER_NAME}")

  if [[ "$http_code" == "404" ]]; then
    log_ok "Cluster '${CLUSTER_NAME}' does not exist in Rancher (already deleted)"
    return 0
  fi

  # Send DELETE request
  log_info "Sending DELETE for provisioning.cattle.io cluster '${CLUSTER_NAME}'..."
  rancher_api DELETE "/v1/provisioning.cattle.io.clusters/fleet-default/${CLUSTER_NAME}" > /dev/null || true

  # Poll for deletion, up to 5 minutes
  local timeout=300 interval=10 elapsed=0
  local finalizer_cleared=false
  while [[ $elapsed -lt $timeout ]]; do
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
      -H "${AUTH_HEADER}" \
      "${RANCHER_URL}/v1/provisioning.cattle.io.clusters/fleet-default/${CLUSTER_NAME}")

    if [[ "$http_code" == "404" ]]; then
      log_ok "Cluster '${CLUSTER_NAME}' deleted from Rancher"
      return 0
    fi

    # After 2 minutes, force-clear finalizers if the cluster is stuck
    if [[ $elapsed -ge 120 && "$finalizer_cleared" == "false" ]]; then
      log_warn "Cluster still deleting after ${elapsed}s — clearing finalizers..."
      curl -sk -X PATCH -H "${AUTH_HEADER}" \
        -H "Content-Type: application/merge-patch+json" \
        "${RANCHER_URL}/v1/provisioning.cattle.io.clusters/fleet-default/${CLUSTER_NAME}" \
        -d '{"metadata":{"finalizers":[]}}' > /dev/null 2>&1 || true
      finalizer_cleared=true
      log_info "Finalizers cleared, waiting for deletion..."
    fi

    log_info "  Cluster still present (${elapsed}s/${timeout}s)..."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  log_warn "Cluster deletion did not complete within ${timeout}s — continuing"
}

step_delete_capi_machines() {
  echo
  log_info "=== Step 2/9: Delete orphaned CAPI machines ==="

  # Find HarvesterMachines stuck in deletion
  local hm_names
  hm_names=$(rancher_api GET "/v1/rke-machine.cattle.io.harvestermachines" \
    | jq -r ".data[]? | select(.metadata.namespace == \"fleet-default\") | select(.metadata.name | test(\"${CLUSTER_NAME}\")) | .metadata.name" 2>/dev/null || true)

  if [[ -n "$hm_names" ]]; then
    log_info "Clearing HarvesterMachine finalizers and deleting..."
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      curl -sk -X PATCH -H "${AUTH_HEADER}" \
        -H "Content-Type: application/merge-patch+json" \
        "${RANCHER_URL}/v1/rke-machine.cattle.io.harvestermachines/fleet-default/${name}" \
        -d '{"metadata":{"finalizers":[]}}' > /dev/null 2>&1 || true
      rancher_api DELETE "/v1/rke-machine.cattle.io.harvestermachines/fleet-default/${name}" > /dev/null 2>&1 || true
      log_info "  Deleted HarvesterMachine: ${name}"
    done <<< "$hm_names"
    sleep 5
  else
    log_ok "No HarvesterMachines found"
  fi

  # Find CAPI machines stuck in deletion
  local capi_names
  capi_names=$(rancher_api GET "/v1/cluster.x-k8s.io.machines" \
    | jq -r ".data[]? | select(.metadata.namespace == \"fleet-default\") | select(.metadata.name | test(\"${CLUSTER_NAME}\")) | .metadata.name" 2>/dev/null || true)

  if [[ -n "$capi_names" ]]; then
    log_info "Clearing CAPI Machine finalizers and deleting..."
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      curl -sk -X PATCH -H "${AUTH_HEADER}" \
        -H "Content-Type: application/merge-patch+json" \
        "${RANCHER_URL}/v1/cluster.x-k8s.io.machines/fleet-default/${name}" \
        -d '{"metadata":{"finalizers":[]}}' > /dev/null 2>&1 || true
      rancher_api DELETE "/v1/cluster.x-k8s.io.machines/fleet-default/${name}" > /dev/null 2>&1 || true
      log_info "  Deleted CAPI Machine: ${name}"
    done <<< "$capi_names"
    sleep 5
  else
    log_ok "No CAPI machines found"
  fi
}

step_delete_capi_parent_objects() {
  echo
  log_info "=== Step 3/9: Delete CAPI parent objects (shadow copies) ==="

  # These are the objects that survive UI deletion and block re-creation.
  # They live in fleet-default on the Rancher management cluster and require
  # the Rancher kubeconfig (not Harvester) to access.
  local RANCHER_KUBECONFIG=""
  RANCHER_KUBECONFIG=$(_create_rancher_kubeconfig)
  # shellcheck disable=SC2064
  trap "rm -f '${RANCHER_KUBECONFIG}'" RETURN
  local RKUBECTL="kubectl --kubeconfig=${RANCHER_KUBECONFIG}"

  # CAPI and Rancher resource types that can become orphaned
  local -a CAPI_TYPES=(
    "clusters.cluster.x-k8s.io"
    "machinedeployments.cluster.x-k8s.io"
    "machinesets.cluster.x-k8s.io"
    "rkecontrolplanes.rke.cattle.io"
    "rkebootstraps.rke.cattle.io"
    "rkebootstraptemplates.rke.cattle.io"
    "etcdsnapshots.rke.cattle.io"
    "clusterregistrationtokens.management.cattle.io"
  )

  local total_deleted=0

  for resource_type in "${CAPI_TYPES[@]}"; do
    local names
    names=$($RKUBECTL get "$resource_type" -n fleet-default --no-headers -o name 2>/dev/null \
      | grep "${CLUSTER_NAME}" || true)

    if [[ -z "$names" ]]; then
      continue
    fi

    local count
    count=$(echo "$names" | wc -l | tr -d ' ')
    log_info "Found ${count} ${resource_type} object(s) — clearing finalizers and deleting..."

    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      $RKUBECTL patch "$name" -n fleet-default --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      $RKUBECTL delete "$name" -n fleet-default --wait=false 2>/dev/null || true
      log_info "  Deleted: ${name}"
      total_deleted=$((total_deleted + 1))
    done <<< "$names"
  done

  # Rancher v3 management cluster object (cluster-scoped, not namespaced)
  local mgmt_clusters
  mgmt_clusters=$($RKUBECTL get clusters.management.cattle.io --no-headers -o custom-columns='NAME:.metadata.name,DISPLAY:.spec.displayName' 2>/dev/null \
    | grep "${CLUSTER_NAME}" | awk '{print $1}' || true)

  if [[ -n "$mgmt_clusters" ]]; then
    log_info "Found management.cattle.io cluster(s) matching '${CLUSTER_NAME}'..."
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      $RKUBECTL patch "clusters.management.cattle.io/${name}" --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      $RKUBECTL delete "clusters.management.cattle.io/${name}" --wait=false 2>/dev/null || true
      log_info "  Deleted management cluster: ${name}"
      total_deleted=$((total_deleted + 1))
    done <<< "$mgmt_clusters"
  fi

  # Also check for cluster-scoped clusterregistrationtokens matching the mgmt cluster ID
  if [[ -n "$mgmt_clusters" ]]; then
    while IFS= read -r mgmt_name; do
      [[ -z "$mgmt_name" ]] && continue
      local reg_tokens
      reg_tokens=$($RKUBECTL get clusterregistrationtokens.management.cattle.io -n "$mgmt_name" \
        --no-headers -o name 2>/dev/null || true)
      if [[ -n "$reg_tokens" ]]; then
        log_info "Deleting registration tokens in namespace '${mgmt_name}'..."
        while IFS= read -r token; do
          [[ -z "$token" ]] && continue
          $RKUBECTL delete "$token" -n "$mgmt_name" --wait=false 2>/dev/null || true
          total_deleted=$((total_deleted + 1))
        done <<< "$reg_tokens"
      fi
    done <<< "$mgmt_clusters"
  fi

  if [[ "$total_deleted" -gt 0 ]]; then
    log_ok "Deleted ${total_deleted} CAPI/management object(s)"
    sleep 5
  else
    log_ok "No orphaned CAPI parent objects found"
  fi
}

step_force_delete_vms() {
  echo
  log_info "=== Step 4/9: Force-delete all VMs and VMIs ==="

  # Delete all VMs in the namespace
  local vms
  vms=$($KUBECTL get virtualmachines.kubevirt.io -n "$VM_NAMESPACE" \
    --no-headers -o name 2>/dev/null || true)

  if [[ -n "$vms" ]]; then
    local vm_count
    vm_count=$(echo "$vms" | wc -l | tr -d ' ')
    log_info "Deleting ${vm_count} VM(s) in namespace '${VM_NAMESPACE}'..."
    while IFS= read -r vm; do
      [[ -z "$vm" ]] && continue
      $KUBECTL delete "$vm" -n "$VM_NAMESPACE" --wait=false 2>/dev/null || true
      log_info "  Delete requested: ${vm}"
    done <<< "$vms"
  else
    log_ok "No VMs found in namespace '${VM_NAMESPACE}'"
  fi

  # Delete all VMIs in the namespace
  local vmis
  vmis=$($KUBECTL get virtualmachineinstances.kubevirt.io -n "$VM_NAMESPACE" \
    --no-headers -o name 2>/dev/null || true)

  if [[ -n "$vmis" ]]; then
    local vmi_count
    vmi_count=$(echo "$vmis" | wc -l | tr -d ' ')
    log_info "Deleting ${vmi_count} VMI(s) in namespace '${VM_NAMESPACE}'..."
    while IFS= read -r vmi; do
      [[ -z "$vmi" ]] && continue
      $KUBECTL delete "$vmi" -n "$VM_NAMESPACE" --wait=false 2>/dev/null || true
    done <<< "$vmis"
  fi

  # Wait up to 3 minutes for VMs to be gone
  local timeout=180 interval=10 elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local remaining
    remaining=$($KUBECTL get virtualmachines.kubevirt.io -n "$VM_NAMESPACE" \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$remaining" -eq 0 ]]; then
      log_ok "All VMs deleted from namespace '${VM_NAMESPACE}'"
      break
    fi

    log_info "  ${remaining} VM(s) still present (${elapsed}s/${timeout}s)..."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  # Force-delete any stuck VMs by patching out finalizers
  local stuck_vms
  stuck_vms=$($KUBECTL get virtualmachines.kubevirt.io -n "$VM_NAMESPACE" \
    --no-headers -o name 2>/dev/null || true)

  if [[ -n "$stuck_vms" ]]; then
    log_warn "Force-deleting stuck VMs by removing finalizers..."
    while IFS= read -r vm; do
      [[ -z "$vm" ]] && continue
      $KUBECTL patch "$vm" -n "$VM_NAMESPACE" --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      log_info "  Patched finalizers: ${vm}"
    done <<< "$stuck_vms"
    sleep 10
  fi

  # Force-delete any stuck VMIs by patching out finalizers
  local stuck_vmis
  stuck_vmis=$($KUBECTL get virtualmachineinstances.kubevirt.io -n "$VM_NAMESPACE" \
    --no-headers -o name 2>/dev/null || true)

  if [[ -n "$stuck_vmis" ]]; then
    log_warn "Force-deleting stuck VMIs by removing finalizers..."
    while IFS= read -r vmi; do
      [[ -z "$vmi" ]] && continue
      $KUBECTL patch "$vmi" -n "$VM_NAMESPACE" --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      $KUBECTL delete "$vmi" -n "$VM_NAMESPACE" --wait=false 2>/dev/null || true
    done <<< "$stuck_vmis"
    sleep 5
  fi
}

step_cleanup_rancher_resources() {
  echo
  log_info "=== Step 5/9: Clean up Rancher resources ==="

  # --- HarvesterConfigs ---
  local harvester_configs
  harvester_configs=$(rancher_api GET "/v1/rke-machine-config.cattle.io.harvesterconfigs/fleet-default" \
    | jq -r ".data[]? | select(.metadata.name | test(\"${CLUSTER_NAME}\")) | .metadata.name" 2>/dev/null || true)

  if [[ -n "$harvester_configs" ]]; then
    log_info "Deleting HarvesterConfigs matching '${CLUSTER_NAME}'..."
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      # Clear finalizers first in case they are stuck
      curl -sk -X PATCH -H "${AUTH_HEADER}" \
        -H "Content-Type: application/merge-patch+json" \
        "${RANCHER_URL}/v1/rke-machine-config.cattle.io.harvesterconfigs/fleet-default/${name}" \
        -d '{"metadata":{"finalizers":[]}}' > /dev/null 2>&1 || true
      rancher_api DELETE "/v1/rke-machine-config.cattle.io.harvesterconfigs/fleet-default/${name}" > /dev/null 2>&1 || true
      log_info "  Deleted HarvesterConfig: ${name}"
    done <<< "$harvester_configs"
  else
    log_ok "No HarvesterConfigs found"
  fi

  # --- Fleet bundles ---
  local fleet_bundles
  fleet_bundles=$(rancher_api GET "/v1/fleet.cattle.io.bundles/fleet-default" \
    | jq -r ".data[]? | select(.metadata.name | test(\"${CLUSTER_NAME}\")) | .metadata.name" 2>/dev/null || true)

  if [[ -n "$fleet_bundles" ]]; then
    local bundle_count
    bundle_count=$(echo "$fleet_bundles" | wc -l | tr -d ' ')
    log_info "Deleting ${bundle_count} Fleet bundle(s) matching '${CLUSTER_NAME}'..."
    while IFS= read -r bundle; do
      [[ -z "$bundle" ]] && continue
      rancher_api DELETE "/v1/fleet.cattle.io.bundles/fleet-default/${bundle}" > /dev/null 2>&1 || true
      log_info "  Deleted Fleet bundle: ${bundle}"
    done <<< "$fleet_bundles"
  else
    log_ok "No Fleet bundles found"
  fi

  # --- Cloud credentials (nuclear = delete all, next apply creates fresh) ---
  local cloud_creds
  cloud_creds=$(rancher_api GET "/v3/cloudCredentials" \
    | jq -r ".data[]? | select(.name | startswith(\"${CLUSTER_NAME}\")) | .id" 2>/dev/null || true)

  if [[ -n "$cloud_creds" ]]; then
    local cc_count
    cc_count=$(echo "$cloud_creds" | wc -l | tr -d ' ')
    log_info "Deleting ${cc_count} cloud credential(s)..."
    while IFS= read -r cred_id; do
      [[ -z "$cred_id" ]] && continue
      rancher_api DELETE "/v3/cloudCredentials/${cred_id}" > /dev/null 2>&1 || true
    done <<< "$cloud_creds"
    log_ok "Deleted ${cc_count} cloud credential(s)"
  else
    log_ok "No cloud credentials found"
  fi

  # --- Dockerhub auth secrets ---
  local dockerhub_secrets
  dockerhub_secrets=$($KUBECTL get secrets -n fleet-default \
    --no-headers -o name 2>/dev/null \
    | grep -E "dockerhub|docker-registry" || true)

  if [[ -n "$dockerhub_secrets" ]]; then
    log_info "Deleting Docker Hub auth secrets in fleet-default..."
    while IFS= read -r secret; do
      [[ -z "$secret" ]] && continue
      $KUBECTL delete "$secret" -n fleet-default --wait=false 2>/dev/null || true
      log_info "  Deleted: ${secret}"
    done <<< "$dockerhub_secrets"
  else
    log_ok "No Docker Hub auth secrets found"
  fi
}

step_cleanup_orphaned_secrets_and_rbac() {
  echo
  log_info "=== Step 6/9: Clean up orphaned secrets and RBAC ==="

  # Use kubectl via Rancher API for fleet-default access (Harvester kubeconfig
  # connects to 172.16.2.2 with limited RBAC and cannot see fleet-default)
  local RANCHER_KUBECONFIG=""
  RANCHER_KUBECONFIG=$(_create_rancher_kubeconfig)
  trap 'rm -f "${RANCHER_KUBECONFIG:-}"' RETURN
  local RKUBECTL="kubectl --kubeconfig=${RANCHER_KUBECONFIG}"

  # --- machine-driver-secret: ${CLUSTER_NAME}-*-machine-driver-secret ---
  local driver_secrets
  driver_secrets=$($RKUBECTL get secrets -n fleet-default --no-headers -o name 2>/dev/null \
    | grep "${CLUSTER_NAME}-.*-machine-driver-secret" || true)

  local driver_count=0
  if [[ -n "$driver_secrets" ]]; then
    driver_count=$(echo "$driver_secrets" | wc -l | tr -d ' ')
    log_info "Deleting ${driver_count} machine-driver-secret(s)..."
    while IFS= read -r secret; do
      [[ -z "$secret" ]] && continue
      $RKUBECTL delete "$secret" -n fleet-default --wait=false 2>/dev/null || true
    done <<< "$driver_secrets"
  fi

  # --- machine-state: ${CLUSTER_NAME}-*-machine-state ---
  local state_secrets
  state_secrets=$($RKUBECTL get secrets -n fleet-default --no-headers -o name 2>/dev/null \
    | grep "${CLUSTER_NAME}-.*-machine-state" || true)

  local state_count=0
  if [[ -n "$state_secrets" ]]; then
    state_count=$(echo "$state_secrets" | wc -l | tr -d ' ')
    log_info "Deleting ${state_count} machine-state secret(s)..."
    while IFS= read -r secret; do
      [[ -z "$secret" ]] && continue
      $RKUBECTL delete "$secret" -n fleet-default --wait=false 2>/dev/null || true
    done <<< "$state_secrets"
  fi

  # --- machine-certs-*: only delete those with NO ownerReferences ---
  local orphan_certs
  orphan_certs=$($RKUBECTL get secrets -n fleet-default -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.name | startswith("machine-certs-")) | select((.metadata.ownerReferences // []) | length == 0) | .metadata.name' 2>/dev/null || true)

  local cert_count=0
  if [[ -n "$orphan_certs" ]]; then
    cert_count=$(echo "$orphan_certs" | wc -l | tr -d ' ')
    log_info "Deleting ${cert_count} orphaned machine-certs secret(s) (no ownerReferences)..."
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      $RKUBECTL delete secret "$name" -n fleet-default --wait=false 2>/dev/null || true
    done <<< "$orphan_certs"
  fi

  # --- harvesterconfig* secrets in fleet-default ---
  local hc_secrets
  hc_secrets=$($RKUBECTL get secrets -n fleet-default --no-headers -o name 2>/dev/null \
    | grep "harvesterconfig" || true)

  local hc_count=0
  if [[ -n "$hc_secrets" ]]; then
    hc_count=$(echo "$hc_secrets" | wc -l | tr -d ' ')
    log_info "Deleting ${hc_count} harvesterconfig secret(s)..."
    while IFS= read -r secret; do
      [[ -z "$secret" ]] && continue
      $RKUBECTL delete "$secret" -n fleet-default --wait=false 2>/dev/null || true
    done <<< "$hc_secrets"
  fi

  # --- dockerhub-auth secret (created by rancher2_secret_v2.dockerhub_auth) ---
  local dh_count=0
  if $RKUBECTL get secret "${CLUSTER_NAME}-dockerhub-auth" -n fleet-default &>/dev/null; then
    $RKUBECTL delete secret "${CLUSTER_NAME}-dockerhub-auth" -n fleet-default --wait=false 2>/dev/null || true
    log_info "Deleted dockerhub-auth secret: ${CLUSTER_NAME}-dockerhub-auth"
    dh_count=1
  fi

  local secret_total=$((driver_count + state_count + cert_count + hc_count + dh_count))
  if [[ "$secret_total" -gt 0 ]]; then
    log_ok "Cleaned ${secret_total} orphaned secret(s) from fleet-default"
  else
    log_ok "No orphaned secrets found in fleet-default"
  fi

  # --- Harvester RBAC cleanup ---
  echo
  log_info "Cleaning Harvester RBAC for cluster '${CLUSTER_NAME}'..."

  # ClusterRoleBindings on Rancher management cluster matching cluster name
  local rancher_crbs
  rancher_crbs=$($RKUBECTL get clusterrolebindings --no-headers -o name 2>/dev/null \
    | grep "${CLUSTER_NAME}" || true)

  local rancher_crb_count=0
  if [[ -n "$rancher_crbs" ]]; then
    rancher_crb_count=$(echo "$rancher_crbs" | wc -l | tr -d ' ')
    log_info "Deleting ${rancher_crb_count} ClusterRoleBinding(s) on Rancher..."
    while IFS= read -r crb; do
      [[ -z "$crb" ]] && continue
      $RKUBECTL delete "$crb" --wait=false 2>/dev/null || true
      log_info "  Deleted: ${crb}"
    done <<< "$rancher_crbs"
  fi

  # ServiceAccount for the cluster in default namespace (on Harvester)
  if $KUBECTL get serviceaccount "${CLUSTER_NAME}" -n default &>/dev/null; then
    $KUBECTL delete serviceaccount "${CLUSTER_NAME}" -n default --wait=false 2>/dev/null || true
    log_info "Deleted ServiceAccount '${CLUSTER_NAME}' in default namespace (Harvester)"
  fi

  # ClusterRoleBindings on Harvester matching cluster name
  local hvst_crbs
  hvst_crbs=$($KUBECTL get clusterrolebindings --no-headers -o name 2>/dev/null \
    | grep "${CLUSTER_NAME}" || true)

  local hvst_crb_count=0
  if [[ -n "$hvst_crbs" ]]; then
    hvst_crb_count=$(echo "$hvst_crbs" | wc -l | tr -d ' ')
    log_info "Deleting ${hvst_crb_count} ClusterRoleBinding(s) on Harvester..."
    while IFS= read -r crb; do
      [[ -z "$crb" ]] && continue
      $KUBECTL delete "$crb" --wait=false 2>/dev/null || true
      log_info "  Deleted: ${crb}"
    done <<< "$hvst_crbs"
  fi

  # RoleBinding in the VM namespace on Harvester
  local ns_rbs
  ns_rbs=$($KUBECTL get rolebindings -n "${VM_NAMESPACE}" --no-headers -o name 2>/dev/null \
    | grep "${CLUSTER_NAME}" || true)

  local ns_rb_count=0
  if [[ -n "$ns_rbs" ]]; then
    ns_rb_count=$(echo "$ns_rbs" | wc -l | tr -d ' ')
    log_info "Deleting ${ns_rb_count} RoleBinding(s) in namespace '${VM_NAMESPACE}'..."
    while IFS= read -r rb; do
      [[ -z "$rb" ]] && continue
      $KUBECTL delete "$rb" -n "${VM_NAMESPACE}" --wait=false 2>/dev/null || true
      log_info "  Deleted: ${rb}"
    done <<< "$ns_rbs"
  fi

  local rbac_total=$((rancher_crb_count + hvst_crb_count + ns_rb_count))
  if [[ "$rbac_total" -gt 0 ]]; then
    log_ok "Cleaned ${rbac_total} RBAC resource(s)"
  else
    log_ok "No orphaned RBAC resources found"
  fi
}

step_cleanup_harvester_resources() {
  echo
  log_info "=== Step 7/9: Clean up Harvester resources (PVCs, DataVolumes) ==="

  # --- DataVolumes ---
  local all_dvs
  all_dvs=$($KUBECTL get datavolumes.cdi.kubevirt.io -n "$VM_NAMESPACE" \
    --no-headers -o name 2>/dev/null || true)

  if [[ -n "$all_dvs" ]]; then
    local dv_count
    dv_count=$(echo "$all_dvs" | wc -l | tr -d ' ')
    log_info "Deleting ${dv_count} DataVolume(s) in namespace '${VM_NAMESPACE}'..."
    while IFS= read -r dv; do
      [[ -z "$dv" ]] && continue
      $KUBECTL patch "$dv" -n "$VM_NAMESPACE" --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      $KUBECTL delete "$dv" -n "$VM_NAMESPACE" --wait=false 2>/dev/null || true
      log_info "  Deleted: ${dv}"
    done <<< "$all_dvs"
  else
    log_ok "No DataVolumes found"
  fi

  # --- PVCs ---
  local all_pvcs
  all_pvcs=$($KUBECTL get pvc -n "$VM_NAMESPACE" --no-headers -o name 2>/dev/null || true)

  if [[ -n "$all_pvcs" ]]; then
    local pvc_count
    pvc_count=$(echo "$all_pvcs" | wc -l | tr -d ' ')
    log_info "Deleting ${pvc_count} PVC(s) in namespace '${VM_NAMESPACE}'..."
    while IFS= read -r pvc; do
      [[ -z "$pvc" ]] && continue
      $KUBECTL patch "$pvc" -n "$VM_NAMESPACE" --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      $KUBECTL delete "$pvc" -n "$VM_NAMESPACE" --wait=false 2>/dev/null || true
      log_info "  Deleted: ${pvc}"
    done <<< "$all_pvcs"
  else
    log_ok "No PVCs found"
  fi

  # --- Namespace leftovers: secrets, configmaps, service accounts ---
  # VirtualMachineImages are preserved (golden images are expensive to recreate)
  log_info "Cleaning namespace leftovers in '${VM_NAMESPACE}' (preserving VirtualMachineImages)..."

  # Secrets in the VM namespace (SA token secrets, etc.)
  local ns_secrets
  ns_secrets=$($KUBECTL get secrets -n "$VM_NAMESPACE" --no-headers -o name 2>/dev/null || true)

  if [[ -n "$ns_secrets" ]]; then
    local ns_secret_count
    ns_secret_count=$(echo "$ns_secrets" | wc -l | tr -d ' ')
    log_info "Deleting ${ns_secret_count} secret(s) in namespace '${VM_NAMESPACE}'..."
    while IFS= read -r secret; do
      [[ -z "$secret" ]] && continue
      $KUBECTL delete "$secret" -n "$VM_NAMESPACE" --wait=false 2>/dev/null || true
    done <<< "$ns_secrets"
  fi

  # ConfigMaps in the VM namespace
  local ns_cms
  ns_cms=$($KUBECTL get configmaps -n "$VM_NAMESPACE" --no-headers -o name 2>/dev/null || true)

  if [[ -n "$ns_cms" ]]; then
    local ns_cm_count
    ns_cm_count=$(echo "$ns_cms" | wc -l | tr -d ' ')
    log_info "Deleting ${ns_cm_count} ConfigMap(s) in namespace '${VM_NAMESPACE}'..."
    while IFS= read -r cm; do
      [[ -z "$cm" ]] && continue
      $KUBECTL delete "$cm" -n "$VM_NAMESPACE" --wait=false 2>/dev/null || true
    done <<< "$ns_cms"
  fi

  # Service accounts in the VM namespace (non-default)
  local ns_sas
  ns_sas=$($KUBECTL get serviceaccounts -n "$VM_NAMESPACE" --no-headers -o name 2>/dev/null \
    | grep -v "^serviceaccount/default$" || true)

  if [[ -n "$ns_sas" ]]; then
    local ns_sa_count
    ns_sa_count=$(echo "$ns_sas" | wc -l | tr -d ' ')
    log_info "Deleting ${ns_sa_count} ServiceAccount(s) in namespace '${VM_NAMESPACE}'..."
    while IFS= read -r sa; do
      [[ -z "$sa" ]] && continue
      $KUBECTL delete "$sa" -n "$VM_NAMESPACE" --wait=false 2>/dev/null || true
    done <<< "$ns_sas"
  fi
}

step_wipe_terraform_state() {
  echo
  log_info "=== Step 8/9: Wipe Terraform state ==="

  cd "$SCRIPT_DIR"

  # Ensure backend is initialized so we can manipulate state
  if [[ ! -d .terraform ]] || ! terraform validate -no-color &>/dev/null; then
    log_info "Initializing Terraform backend..."
    if ! terraform init -input=false 2>/dev/null; then
      terraform init -input=false -reconfigure 2>/dev/null || true
    fi
  fi

  # List all resources in state
  local resources
  resources=$(terraform state list 2>/dev/null || true)

  if [[ -z "$resources" ]]; then
    log_ok "Terraform state is already empty"
    return 0
  fi

  local resource_count
  resource_count=$(echo "$resources" | wc -l | tr -d ' ')
  log_info "Removing ${resource_count} resource(s) from Terraform state..."

  while IFS= read -r resource; do
    [[ -z "$resource" ]] && continue
    terraform state rm "$resource" 2>/dev/null || true
    log_info "  Removed: ${resource}"
  done <<< "$resources"

  # Verify state is empty
  local remaining
  remaining=$(terraform state list 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$remaining" -eq 0 ]]; then
    log_ok "Terraform state is empty"
  else
    log_warn "${remaining} resource(s) still in Terraform state"
  fi
}

step_verify() {
  echo
  log_info "=== Step 9/9: Final verification ==="
  echo

  local all_passed=true

  # Check 1: Cluster gone from Rancher
  local http_code
  http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "${AUTH_HEADER}" \
    "${RANCHER_URL}/v1/provisioning.cattle.io.clusters/fleet-default/${CLUSTER_NAME}")

  if [[ "$http_code" == "404" ]]; then
    CHECK_RESULTS["Cluster deleted from Rancher"]="PASS"
  else
    CHECK_RESULTS["Cluster deleted from Rancher"]="FAIL (HTTP ${http_code})"
    all_passed=false
  fi

  # Check 2: CAPI parent objects gone
  local RANCHER_KUBECONFIG_VERIFY=""
  RANCHER_KUBECONFIG_VERIFY=$(_create_rancher_kubeconfig)
  local RKUBECTL_VERIFY="kubectl --kubeconfig=${RANCHER_KUBECONFIG_VERIFY}"

  local capi_remaining=0
  local -a CAPI_VERIFY_TYPES=(
    "clusters.cluster.x-k8s.io"
    "machinedeployments.cluster.x-k8s.io"
    "machinesets.cluster.x-k8s.io"
    "rkecontrolplanes.rke.cattle.io"
  )
  for rt in "${CAPI_VERIFY_TYPES[@]}"; do
    local rt_count
    rt_count=$($RKUBECTL_VERIFY get "$rt" -n fleet-default --no-headers 2>/dev/null \
      | grep -c "${CLUSTER_NAME}" || true)
    capi_remaining=$((capi_remaining + rt_count))
  done

  if [[ "$capi_remaining" -eq 0 ]]; then
    CHECK_RESULTS["CAPI objects cleaned"]="PASS (0 remaining)"
  else
    CHECK_RESULTS["CAPI objects cleaned"]="FAIL (${capi_remaining} remaining)"
    all_passed=false
  fi

  # Check 3: 0 VMs
  local vm_count
  vm_count=$($KUBECTL get virtualmachines.kubevirt.io -n "$VM_NAMESPACE" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$vm_count" -eq 0 ]]; then
    CHECK_RESULTS["VMs in ${VM_NAMESPACE}"]="PASS (0 VMs)"
  else
    CHECK_RESULTS["VMs in ${VM_NAMESPACE}"]="FAIL (${vm_count} VMs remaining)"
    all_passed=false
  fi

  # Check 3: 0 HarvesterConfigs
  local hc_count
  hc_count=$(rancher_api GET "/v1/rke-machine-config.cattle.io.harvesterconfigs/fleet-default" \
    | jq -r "[.data[]? | select(.metadata.name | test(\"${CLUSTER_NAME}\"))] | length" 2>/dev/null || echo "0")

  if [[ "$hc_count" -eq 0 ]]; then
    CHECK_RESULTS["HarvesterConfigs cleaned"]="PASS (0 configs)"
  else
    CHECK_RESULTS["HarvesterConfigs cleaned"]="FAIL (${hc_count} remaining)"
    all_passed=false
  fi

  # Check 4: Cloud credentials cleaned
  local cc_count
  cc_count=$(rancher_api GET "/v3/cloudCredentials" \
    | jq -r "[.data[]? | select(.name | startswith(\"${CLUSTER_NAME}\"))] | length" 2>/dev/null || echo "0")

  if [[ "$cc_count" -eq 0 ]]; then
    CHECK_RESULTS["Cloud credentials cleaned"]="PASS"
  else
    CHECK_RESULTS["Cloud credentials cleaned"]="FAIL (${cc_count} remaining)"
    all_passed=false
  fi

  # Check 5: Orphaned secrets cleaned from fleet-default
  local orphan_driver_count orphan_state_count orphan_cert_count
  orphan_driver_count=$($RKUBECTL_VERIFY get secrets -n fleet-default --no-headers 2>/dev/null \
    | grep -c "${CLUSTER_NAME}-.*-machine-driver-secret" || true)
  orphan_state_count=$($RKUBECTL_VERIFY get secrets -n fleet-default --no-headers 2>/dev/null \
    | grep -c "${CLUSTER_NAME}-.*-machine-state" || true)
  orphan_cert_count=$($RKUBECTL_VERIFY get secrets -n fleet-default -o json 2>/dev/null \
    | jq -r '[.items[] | select(.metadata.name | startswith("machine-certs-")) | select((.metadata.ownerReferences // []) | length == 0)] | length' 2>/dev/null || echo "0")

  local orphan_total=$((orphan_driver_count + orphan_state_count + orphan_cert_count))
  if [[ "$orphan_total" -eq 0 ]]; then
    CHECK_RESULTS["Orphaned secrets cleaned"]="PASS (0 remaining)"
  else
    CHECK_RESULTS["Orphaned secrets cleaned"]="FAIL (${orphan_total} remaining)"
    all_passed=false
  fi

  # Check 6: RBAC cleaned
  local crb_remaining
  crb_remaining=$($KUBECTL get clusterrolebindings --no-headers 2>/dev/null \
    | grep -c "${CLUSTER_NAME}" || true)
  local sa_remaining=0
  if $KUBECTL get serviceaccount "${CLUSTER_NAME}" -n default &>/dev/null; then
    sa_remaining=1
  fi

  local rbac_remaining=$((crb_remaining + sa_remaining))
  if [[ "$rbac_remaining" -eq 0 ]]; then
    CHECK_RESULTS["RBAC cleaned (Harvester)"]="PASS (0 remaining)"
  else
    CHECK_RESULTS["RBAC cleaned (Harvester)"]="FAIL (${rbac_remaining} remaining)"
    all_passed=false
  fi

  # Check 8: 0 PVCs
  local pvc_count
  pvc_count=$($KUBECTL get pvc -n "$VM_NAMESPACE" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$pvc_count" -eq 0 ]]; then
    CHECK_RESULTS["PVCs in ${VM_NAMESPACE}"]="PASS (0 PVCs)"
  else
    CHECK_RESULTS["PVCs in ${VM_NAMESPACE}"]="FAIL (${pvc_count} PVCs remaining)"
    all_passed=false
  fi

  # Check 9: Terraform state empty
  cd "$SCRIPT_DIR"
  local tf_count
  tf_count=$(terraform state list 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$tf_count" -eq 0 ]]; then
    CHECK_RESULTS["Terraform state empty"]="PASS"
  else
    CHECK_RESULTS["Terraform state empty"]="FAIL (${tf_count} resources)"
    all_passed=false
  fi

  # Clean up temp kubeconfig
  rm -f "${RANCHER_KUBECONFIG_VERIFY:-}"

  # --- Print summary table ---
  echo
  echo -e "${BOLD}============================================================${NC}"
  echo -e "${BOLD}  Nuke Verification Summary — ${CLUSTER_NAME}${NC}"
  echo -e "${BOLD}============================================================${NC}"
  printf "  %-35s %s\n" "CHECK" "RESULT"
  printf "  %-35s %s\n" "-----------------------------------" "-------------------"

  # Sort keys for deterministic output
  local sorted_keys
  sorted_keys=$(printf '%s\n' "${!CHECK_RESULTS[@]}" | sort)

  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    local result="${CHECK_RESULTS[$key]}"
    if [[ "$result" == PASS* ]]; then
      printf "  %-35s ${GREEN}%s${NC}\n" "$key" "$result"
    else
      printf "  %-35s ${RED}%s${NC}\n" "$key" "$result"
    fi
  done <<< "$sorted_keys"

  echo -e "${BOLD}============================================================${NC}"
  echo

  if [[ "$all_passed" == "true" ]]; then
    log_ok "All checks passed. Cluster '${CLUSTER_NAME}' has been completely removed."
    return 0
  else
    log_error "Some checks failed. Manual cleanup may be required."
    return 1
  fi
}

# --- Main ---

main() {
  local skip_confirm=false
  ENV_FILE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)
        skip_confirm=true
        shift
        ;;
      --env)
        [[ $# -ge 2 ]] || die "--env requires a file path argument"
        ENV_FILE="$2"
        shift 2
        ;;
      --env=*)
        ENV_FILE="${1#--env=}"
        shift
        ;;
      -h|--help)
        usage
        ;;
      *)
        log_error "Unknown option: $1"
        echo
        usage
        ;;
    esac
  done

  # Resolve ENV_FILE: absolute as-is, else try CWD then SCRIPT_DIR/
  if [[ -n "${ENV_FILE}" ]]; then
    if [[ "${ENV_FILE}" != /* ]]; then
      if [[ -f "${PWD}/${ENV_FILE}" ]]; then
        ENV_FILE="${PWD}/${ENV_FILE}"
      elif [[ -f "${SCRIPT_DIR}/${ENV_FILE}" ]]; then
        ENV_FILE="${SCRIPT_DIR}/${ENV_FILE}"
      fi
    fi
    export ENV_FILE
  fi

  echo
  echo -e "${BOLD}${RED}============================================================${NC}"
  echo -e "${BOLD}${RED}  NUCLEAR CLEANUP — RKE2 Cluster Destruction${NC}"
  echo -e "${BOLD}${RED}============================================================${NC}"
  echo

  check_prerequisites
  check_connectivity
  load_config
  echo

  # Confirmation gate
  if [[ "$skip_confirm" == "false" ]]; then
    echo -e "${RED}${BOLD}WARNING: This will permanently destroy:${NC}"
    echo -e "  - Cluster:   ${BOLD}${CLUSTER_NAME}${NC} (from Rancher)"
    echo -e "  - CAPI:      Clusters, MachineDeployments, MachineSets, RKEControlPlanes"
    echo -e "  - Machines:  HarvesterMachines, CAPI Machines, RKEBootstraps"
    echo -e "  - VMs:       ALL in namespace ${BOLD}${VM_NAMESPACE}${NC}"
    echo -e "  - PVCs:      ALL in namespace ${BOLD}${VM_NAMESPACE}${NC}"
    echo -e "  - Secrets:   Orphaned machine secrets in fleet-default"
    echo -e "  - RBAC:      ClusterRoleBindings, ServiceAccounts for the cluster"
    echo -e "  - State:     ALL resources from Terraform state"
    echo -e "  - Rancher:   HarvesterConfigs, Fleet bundles, management clusters"
    echo -e "  - Deleted:   Cloud credentials (next apply creates fresh)"
    echo
    echo -e "${RED}This action is IRREVERSIBLE.${NC}"
    echo
    local answer
    read -rp "Type the cluster name to confirm destruction [${CLUSTER_NAME}]: " answer
    if [[ "$answer" != "$CLUSTER_NAME" ]]; then
      die "Confirmation failed. Expected '${CLUSTER_NAME}', got '${answer}'. Aborting."
    fi
    echo
  fi

  log_info "Starting nuclear cleanup for cluster '${CLUSTER_NAME}'..."

  step_delete_cluster
  step_delete_capi_machines
  step_delete_capi_parent_objects
  step_force_delete_vms
  step_cleanup_rancher_resources
  step_cleanup_orphaned_secrets_and_rbac
  step_cleanup_harvester_resources
  step_wipe_terraform_state
  step_verify
}

main "$@"
