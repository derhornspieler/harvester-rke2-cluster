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
  -y, --yes     Skip interactive confirmation
  -h, --help    Show this help message and exit

Steps performed (in order):
  1. Delete cluster from Rancher API (with finalizer cleanup)
  2. Delete orphaned CAPI machines in fleet-default
  3. Force-delete all VMs and VMIs in the VM namespace
  4. Clean up Rancher resources (HarvesterConfigs, Fleet bundles, cloud creds)
  5. Clean up Harvester resources (PVCs, DataVolumes)
  6. Wipe Terraform state
  7. Final verification

Prerequisites:
  - kubectl, terraform, jq, curl must be installed
  - kubeconfig-harvester.yaml must exist (or 'harvester' context in ~/.kube/config)
  - terraform.tfvars must contain rancher_url, rancher_token, cluster_name, vm_namespace
EOF
  exit 0
}

# Extract a quoted tfvars value by variable name
_get_tfvar_value() {
  awk -F'"' "/^${1}[[:space:]]/ {print \$2}" "${SCRIPT_DIR}/terraform.tfvars" 2>/dev/null || echo ""
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
  if [[ ! -f "${SCRIPT_DIR}/terraform.tfvars" ]]; then
    die "terraform.tfvars not found in ${SCRIPT_DIR}"
  fi

  RANCHER_URL=$(_get_tfvar_value rancher_url)
  RANCHER_TOKEN=$(_get_tfvar_value rancher_token)
  CLUSTER_NAME=$(_get_tfvar_value cluster_name)
  VM_NAMESPACE=$(_get_tfvar_value vm_namespace)

  [[ -z "$RANCHER_URL" ]]    && die "rancher_url not set in terraform.tfvars"
  [[ -z "$RANCHER_TOKEN" ]]  && die "rancher_token not set in terraform.tfvars"
  [[ -z "$CLUSTER_NAME" ]]   && die "cluster_name not set in terraform.tfvars"
  [[ -z "$VM_NAMESPACE" ]]   && die "vm_namespace not set in terraform.tfvars"

  AUTH_HEADER="Authorization: Bearer ${RANCHER_TOKEN}"

  log_ok "Config loaded: cluster=${CLUSTER_NAME}, namespace=${VM_NAMESPACE}"
  log_info "Rancher: ${RANCHER_URL}"
}

# Rancher API helper: rancher_api METHOD PATH [DATA]
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
  log_info "=== Step 1/7: Delete cluster from Rancher API ==="

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
  log_info "=== Step 2/7: Delete orphaned CAPI machines ==="

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

step_force_delete_vms() {
  echo
  log_info "=== Step 3/7: Force-delete all VMs and VMIs ==="

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
  log_info "=== Step 4/7: Clean up Rancher resources ==="

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

  # --- Cloud credentials ---
  local cloud_creds
  cloud_creds=$(rancher_api GET "/v3/cloudCredentials" \
    | jq -r ".data[]? | select(.name | test(\"${CLUSTER_NAME}\")) | .id" 2>/dev/null || true)

  if [[ -n "$cloud_creds" ]]; then
    log_info "Deleting cloud credentials matching '${CLUSTER_NAME}'..."
    while IFS= read -r cred_id; do
      [[ -z "$cred_id" ]] && continue
      rancher_api DELETE "/v3/cloudCredentials/${cred_id}" > /dev/null 2>&1 || true
      log_info "  Deleted cloud credential: ${cred_id}"
    done <<< "$cloud_creds"
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

step_cleanup_harvester_resources() {
  echo
  log_info "=== Step 5/7: Clean up Harvester resources (PVCs, DataVolumes) ==="

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
}

step_wipe_terraform_state() {
  echo
  log_info "=== Step 6/7: Wipe Terraform state ==="

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
  log_info "=== Step 7/7: Final verification ==="
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

  # Check 2: 0 VMs
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

  # Check 4: 0 cloud credentials
  local cc_count
  cc_count=$(rancher_api GET "/v3/cloudCredentials" \
    | jq -r "[.data[]? | select(.name | test(\"${CLUSTER_NAME}\"))] | length" 2>/dev/null || echo "0")

  if [[ "$cc_count" -eq 0 ]]; then
    CHECK_RESULTS["Cloud credentials cleaned"]="PASS (0 creds)"
  else
    CHECK_RESULTS["Cloud credentials cleaned"]="FAIL (${cc_count} remaining)"
    all_passed=false
  fi

  # Check 5: 0 PVCs
  local pvc_count
  pvc_count=$($KUBECTL get pvc -n "$VM_NAMESPACE" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$pvc_count" -eq 0 ]]; then
    CHECK_RESULTS["PVCs in ${VM_NAMESPACE}"]="PASS (0 PVCs)"
  else
    CHECK_RESULTS["PVCs in ${VM_NAMESPACE}"]="FAIL (${pvc_count} PVCs remaining)"
    all_passed=false
  fi

  # Check 6: Terraform state empty
  cd "$SCRIPT_DIR"
  local tf_count
  tf_count=$(terraform state list 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$tf_count" -eq 0 ]]; then
    CHECK_RESULTS["Terraform state empty"]="PASS"
  else
    CHECK_RESULTS["Terraform state empty"]="FAIL (${tf_count} resources)"
    all_passed=false
  fi

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

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)
        skip_confirm=true
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
    echo -e "  - VMs:       ALL in namespace ${BOLD}${VM_NAMESPACE}${NC}"
    echo -e "  - PVCs:      ALL in namespace ${BOLD}${VM_NAMESPACE}${NC}"
    echo -e "  - State:     ALL resources from Terraform state"
    echo -e "  - Rancher:   HarvesterConfigs, Fleet bundles, cloud credentials"
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
  step_force_delete_vms
  step_cleanup_rancher_resources
  step_cleanup_harvester_resources
  step_wipe_terraform_state
  step_verify
}

main "$@"
