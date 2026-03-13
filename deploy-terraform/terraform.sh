#!/usr/bin/env bash
set -euo pipefail

# --- Colors & Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()       { log_error "$*"; exit 1; }

# --- Constants ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HARVESTER_KUBECONFIG="${REPO_ROOT}/kubeconfig-harvester.yaml"
TF_NAMESPACE="terraform-state"
KUBECTL="kubectl --kubeconfig=${HARVESTER_KUBECONFIG}"

# Files to store as secrets (parallel arrays: filename -> secret name)
# Paths relative to REPO_ROOT for credential files, SCRIPT_DIR for terraform.tfvars
SECRET_FILENAMES=("${SCRIPT_DIR}/terraform.tfvars" "${REPO_ROOT}/kubeconfig-harvester.yaml" "${REPO_ROOT}/kubeconfig-harvester-cloud-cred.yaml" "${REPO_ROOT}/harvester-cloud-provider-kubeconfig" "${REPO_ROOT}/vault-init.json")
SECRET_NAMES=("terraform-tfvars" "kubeconfig-harvester" "kubeconfig-harvester-cloud-cred" "harvester-cloud-provider-kubeconfig" "vault-init")

# --- Helper Functions ---

# Extract a quoted tfvars value by variable name
_get_tfvar_value() {
  awk -F'"' "/^${1}[[:space:]]/ {print \$2}" "${SCRIPT_DIR}/terraform.tfvars" 2>/dev/null || echo ""
}

# Extract a heredoc tfvars value (multiline, between <<-EOT and EOT).
# Usage: _get_tfvar_heredoc private_ca_pem
# Returns the content between the start marker and EOT.
_get_tfvar_heredoc() {
  local key="$1"
  local in_block=0
  while IFS= read -r line; do
    if [[ "$in_block" -eq 0 && "$line" =~ ^${key}[[:space:]]*=.*EOT$ ]]; then
      # Found start of multi-line heredoc
      in_block=1
      continue
    elif [[ "$in_block" -eq 1 ]]; then
      if [[ "$line" == "EOT" ]]; then
        return 0
      fi
      echo "$line"
    fi
  done < "${SCRIPT_DIR}/terraform.tfvars"
  return 0
}



check_prerequisites() {
  local missing=()
  for cmd in kubectl terraform jq; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    exit 1
  fi
  log_ok "Prerequisites found: kubectl, terraform, jq"
}

check_connectivity() {
  if [[ ! -f "$HARVESTER_KUBECONFIG" ]]; then
    log_info "Harvester kubeconfig not found, extracting from ~/.kube/config (context: harvester)..."
    if kubectl config view --minify --context=harvester --raw > "$HARVESTER_KUBECONFIG" 2>/dev/null && [[ -s "$HARVESTER_KUBECONFIG" ]]; then
      chmod 600 "$HARVESTER_KUBECONFIG"
      log_ok "Harvester kubeconfig extracted to ${HARVESTER_KUBECONFIG}"
    else
      rm -f "$HARVESTER_KUBECONFIG"
      log_error "Harvester kubeconfig not found: ${HARVESTER_KUBECONFIG}"
      log_error "Add a 'harvester' context to ~/.kube/config or place the file manually"
      exit 1
    fi
  fi
  if ! $KUBECTL cluster-info &>/dev/null; then
    log_error "Cannot connect to Harvester cluster via ${HARVESTER_KUBECONFIG}"
    exit 1
  fi
  log_ok "Harvester cluster is reachable"
}

ensure_namespace() {
  if ! $KUBECTL get namespace "$TF_NAMESPACE" &>/dev/null; then
    log_info "Creating namespace ${TF_NAMESPACE}..."
    $KUBECTL create namespace "$TF_NAMESPACE"
    log_ok "Namespace ${TF_NAMESPACE} created"
  else
    log_ok "Namespace ${TF_NAMESPACE} exists"
  fi
}

clear_stale_lock() {
  cd "$SCRIPT_DIR"
  # Try a quick plan to see if the state is locked
  local output
  output=$(terraform plan -input=false -no-color 2>&1 || true)
  if echo "$output" | grep -q "Error acquiring the state lock"; then
    local lock_id
    lock_id=$(echo "$output" | grep 'ID:' | head -1 | awk '{print $2}')
    if [[ -n "$lock_id" ]]; then
      log_warn "Terraform state is locked (stale lock from a previous run)"
      log_info "Lock ID: ${lock_id}"
      log_info "Auto-unlocking..."
      if terraform force-unlock -force "$lock_id" 2>/dev/null; then
        log_ok "State lock cleared"
      else
        log_error "Failed to clear state lock. Run: terraform force-unlock -force ${lock_id}"
        return 1
      fi
    fi
  fi
}

check_rbac() {
  local ok=true
  for action in "create secrets" "create leases"; do
    if ! $KUBECTL auth can-i $action -n "$TF_NAMESPACE" &>/dev/null; then
      log_error "Insufficient permissions: cannot ${action} in ${TF_NAMESPACE}"
      ok=false
    fi
  done
  if [[ "$ok" != "true" ]]; then
    exit 1
  fi
  log_ok "RBAC permissions verified (secrets + leases)"
}

push_secrets() {
  log_info "Pushing local files to K8s secrets in ${TF_NAMESPACE}..."
  local pushed=0
  for i in "${!SECRET_FILENAMES[@]}"; do
    local filepath="${SECRET_FILENAMES[$i]}"
    local secret_name="${SECRET_NAMES[$i]}"
    local filename
    filename="$(basename "${filepath}")"
    if [[ -f "$filepath" ]]; then
      $KUBECTL create secret generic "$secret_name" \
        --from-file="${filename}=${filepath}" \
        --namespace="$TF_NAMESPACE" \
        --dry-run=client -o yaml | $KUBECTL apply -f -
      log_ok "  ${secret_name} <- ${filename}"
      pushed=$((pushed + 1))
    else
      log_warn "  Skipping ${filename} (not found)"
    fi
  done
  log_ok "Pushed ${pushed} secret(s)"
}

pull_secrets() {
  log_info "Pulling secrets from ${TF_NAMESPACE} to local files..."
  local pulled=0
  for i in "${!SECRET_FILENAMES[@]}"; do
    local filepath="${SECRET_FILENAMES[$i]}"
    local secret_name="${SECRET_NAMES[$i]}"
    local filename
    filename="$(basename "${filepath}")"
    if $KUBECTL get secret "$secret_name" -n "$TF_NAMESPACE" &>/dev/null; then
      local tmpfile
      tmpfile=$(mktemp)
      $KUBECTL get secret "$secret_name" -n "$TF_NAMESPACE" -o json \
        | jq -r ".data[\"${filename}\"]" | base64 -d > "$tmpfile"
      mv "$tmpfile" "$filepath"
      chmod 600 "$filepath"
      log_ok "  ${filename} <- ${secret_name}"
      pulled=$((pulled + 1))
    else
      log_warn "  Skipping ${secret_name} (not found in cluster)"
    fi
  done
  log_ok "Pulled ${pulled} secret(s)"
}

# --- Commands ---

cmd_init() {
  log_info "Initializing Terraform with Kubernetes backend..."
  echo

  check_prerequisites
  check_connectivity
  ensure_namespace
  check_rbac
  echo

  push_secrets
  echo

  log_info "Running terraform init -migrate-state..."
  cd "$SCRIPT_DIR"
  terraform init -migrate-state
  echo

  log_ok "Initialization complete. State is now stored in K8s secret: tfstate-default-rke2-cluster"
}

cmd_push_secrets() {
  check_connectivity
  ensure_namespace
  push_secrets
}

cmd_pull_secrets() {
  check_connectivity
  pull_secrets
}

cmd_apply() {
  check_connectivity
  pull_secrets
  echo

  cd "$SCRIPT_DIR"

  # Detect stale .terraform/ — if terraform.tfvars is newer, force re-init
  local needs_init=false
  if [[ ! -d .terraform ]]; then
    needs_init=true
  elif [[ -f terraform.tfvars && terraform.tfvars -nt .terraform ]]; then
    log_info "terraform.tfvars is newer than .terraform/ — forcing re-init..."
    needs_init=true
  elif ! terraform validate -no-color &>/dev/null; then
    needs_init=true
  fi

  if [[ "$needs_init" == "true" ]]; then
    log_info "Initializing Terraform backend..."
    if ! terraform init -input=false 2>&1; then
      log_warn "Backend init failed — retrying with -reconfigure..."
      if ! terraform init -input=false -reconfigure 2>&1; then
        die "Terraform init failed even with -reconfigure. Check backend connectivity."
      fi
    fi
    echo
  fi

  clear_stale_lock

  # Generate dated plan file
  local plan_file="tfplan_$(date +%Y%m%d_%H%M%S)"
  log_info "Running: terraform plan -out=${plan_file}"
  terraform plan -out="$plan_file"
  echo

  log_info "Running: terraform apply ${plan_file}"
  local tf_exit=0
  terraform apply "$plan_file" || tf_exit=$?
  rm -f "$plan_file"

  # Terraform may exit 1 with "Error releasing the state lock" even when
  # apply succeeds (K8s backend lock timeout during long cluster creation).
  # Check if resources were actually created before failing.
  if [[ $tf_exit -ne 0 ]]; then
    if terraform state list 2>/dev/null | grep -q "rancher2_cluster_v2"; then
      log_warn "Terraform exited $tf_exit but resources were created — continuing"
    else
      log_error "Terraform apply failed (exit $tf_exit)"
      return $tf_exit
    fi
  fi
  echo

  # Always push secrets after successful apply
  log_info "Pushing secrets to Harvester after successful apply..."
  ensure_namespace
  push_secrets
}

cmd_terraform() {
  check_connectivity
  pull_secrets
  echo
  log_info "Running: terraform $*"
  cd "$SCRIPT_DIR"
  terraform "$@"
}

cmd_validate() {
  check_connectivity
  pull_secrets
  echo

  cd "$SCRIPT_DIR"

  # Ensure backend is initialized
  if [[ ! -d .terraform ]] || ! terraform validate -no-color &>/dev/null; then
    log_info "Initializing Terraform backend..."
    terraform init -input=false -reconfigure 2>/dev/null || true
  fi

  # Run terraform validate
  log_info "Running terraform validate..."
  if terraform validate; then
    log_ok "Terraform configuration is valid"
  else
    log_error "Terraform validation failed"
    return 1
  fi
  echo

  # Check golden image exists on Harvester
  local golden_image vm_namespace
  golden_image=$(_get_tfvar_value golden_image_name)
  vm_namespace=$(_get_tfvar_value vm_namespace)

  if [[ -z "$golden_image" ]]; then
    log_error "golden_image_name not set in terraform.tfvars"
    return 1
  fi
  if [[ -z "$vm_namespace" ]]; then
    log_error "vm_namespace not set in terraform.tfvars"
    return 1
  fi

  log_info "Checking golden image '${golden_image}' exists in Harvester namespace '${vm_namespace}'..."
  if $KUBECTL get virtualmachineimages.harvesterhci.io "${golden_image}" -n "${vm_namespace}" &>/dev/null; then
    log_ok "Golden image '${golden_image}' found on Harvester"
  else
    log_error "Golden image '${golden_image}' not found in namespace '${vm_namespace}'"
    log_error "Upload the golden image to Harvester before running terraform apply"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Post-destroy cleanup: remove orphaned VMs, VMIs, DataVolumes, and PVCs
# from Harvester that terraform destroy leaves behind.
#
# Why this is needed:
#   terraform destroy deletes rancher2_cluster_v2 → Rancher starts async
#   VM teardown via CAPI → Terraform then deletes the cloud credential →
#   Harvester node driver loses access → VMs get stuck with finalizers →
#   VM disk PVCs accumulate on every destroy/recreate cycle.
# ---------------------------------------------------------------------------
post_destroy_cleanup() {
  local vm_namespace="$1"
  local cluster_name="$2"

  if [[ -z "$vm_namespace" || -z "$cluster_name" ]]; then
    log_warn "Could not determine VM namespace or cluster name — skipping Harvester cleanup"
    return 0
  fi

  echo
  log_info "Post-destroy cleanup: checking for orphaned resources in Harvester namespace '${vm_namespace}'..."

  # --- Clear stuck CAPI finalizers on Rancher management cluster ---
  local rancher_url rancher_token
  rancher_url=$(_get_tfvar_value rancher_url)
  rancher_token=$(_get_tfvar_value rancher_token)

  if [[ -n "$rancher_url" && -n "$rancher_token" ]]; then
    local auth_header="Authorization: Bearer ${rancher_token}"

    # Clear HarvesterMachine finalizers FIRST (they're the root)
    # NOTE: Use PATCH with merge-patch, NOT GET+jq+PUT — JSON responses contain
    #       binary cloud-init data that breaks jq parsing
    local hm_names
    hm_names=$(curl -sk -H "$auth_header" \
      "${rancher_url}/v1/rke-machine.cattle.io.harvestermachines" 2>/dev/null \
      | jq -r '.data[]? | select(.metadata.deletionTimestamp != null) | .metadata.name' 2>/dev/null || true)

    if [[ -n "$hm_names" ]]; then
      log_warn "Clearing stuck HarvesterMachine finalizers on Rancher..."
      while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        curl -sk -X PATCH -H "$auth_header" \
          -H "Content-Type: application/merge-patch+json" \
          "${rancher_url}/v1/rke-machine.cattle.io.harvestermachines/fleet-default/${name}" \
          -d '{"metadata":{"finalizers":[]}}' > /dev/null 2>&1 || true
        # Explicitly delete the HarvesterMachine after clearing finalizers
        curl -sk -X DELETE -H "$auth_header" \
          "${rancher_url}/v1/rke-machine.cattle.io.harvestermachines/fleet-default/${name}" > /dev/null 2>&1 || true
        log_info "  Patched + deleted: ${name}"
      done <<< "$hm_names"
      sleep 5
    fi

    # Clear CAPI Machine finalizers (cascade from HarvesterMachines)
    local capi_names
    capi_names=$(curl -sk -H "$auth_header" \
      "${rancher_url}/v1/cluster.x-k8s.io.machines" 2>/dev/null \
      | jq -r '.data[]? | select(.metadata.deletionTimestamp != null) | .metadata.name' 2>/dev/null || true)

    if [[ -n "$capi_names" ]]; then
      log_warn "Clearing stuck CAPI Machine finalizers on Rancher..."
      while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        curl -sk -X PATCH -H "$auth_header" \
          -H "Content-Type: application/merge-patch+json" \
          "${rancher_url}/v1/cluster.x-k8s.io.machines/fleet-default/${name}" \
          -d '{"metadata":{"finalizers":[]}}' > /dev/null 2>&1 || true
        log_info "  Patched: ${name}"
      done <<< "$capi_names"
      sleep 5
    fi

    # Clear provisioning cluster finalizers (if cluster is stuck deleting)
    local cluster_dt
    cluster_dt=$(curl -sk -H "$auth_header" \
      "${rancher_url}/v1/provisioning.cattle.io.clusters/fleet-default/${cluster_name}" 2>/dev/null \
      | jq -r '.metadata.deletionTimestamp // empty' 2>/dev/null || true)

    if [[ -n "$cluster_dt" ]]; then
      log_warn "Clearing stuck cluster finalizers on Rancher..."
      curl -sk -X PATCH -H "$auth_header" \
        -H "Content-Type: application/merge-patch+json" \
        "${rancher_url}/v1/provisioning.cattle.io.clusters/fleet-default/${cluster_name}" \
        -d '{"metadata":{"finalizers":[]}}' > /dev/null 2>&1 || true
      log_info "  Patched cluster: ${cluster_name}"
      sleep 5
    fi

    # Clean up orphaned Fleet bundles for the destroyed cluster
    local fleet_bundles
    fleet_bundles=$(curl -sk -H "$auth_header" \
      "${rancher_url}/v1/fleet.cattle.io.bundles/fleet-default" 2>/dev/null \
      | jq -r ".data[]? | select(.metadata.name | test(\"${cluster_name}\")) | .metadata.name" 2>/dev/null || true)

    if [[ -n "$fleet_bundles" ]]; then
      local bundle_count
      bundle_count=$(echo "$fleet_bundles" | wc -l | tr -d ' ')
      log_info "Cleaning up ${bundle_count} orphaned Fleet bundle(s) for '${cluster_name}'..."
      while IFS= read -r bundle; do
        [[ -z "$bundle" ]] && continue
        curl -sk -X DELETE -H "$auth_header" \
          "${rancher_url}/v1/fleet.cattle.io.bundles/fleet-default/${bundle}" > /dev/null 2>&1 || true
        log_info "  Deleted: ${bundle}"
      done <<< "$fleet_bundles"
    fi
  fi

  # --- Wait for VMs to be deleted (async CAPI teardown) ---
  local timeout=300 interval=10 elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local vm_count
    vm_count=$($KUBECTL get virtualmachines.kubevirt.io -n "$vm_namespace" --no-headers 2>/dev/null \
      | grep -c "^${cluster_name}-" || true)

    if [[ "$vm_count" -eq 0 ]]; then
      log_ok "All cluster VMs deleted from Harvester"
      break
    fi

    log_info "  ${vm_count} VM(s) still deleting (${elapsed}s/${timeout}s)..."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  # --- Remove stuck finalizers on VMs ---
  local stuck_vms
  stuck_vms=$($KUBECTL get virtualmachines.kubevirt.io -n "$vm_namespace" \
    --no-headers -o name 2>/dev/null | grep "${cluster_name}" || true)

  if [[ -n "$stuck_vms" ]]; then
    log_warn "Removing stuck finalizers from remaining VMs..."
    while IFS= read -r vm; do
      [[ -z "$vm" ]] && continue
      $KUBECTL patch "$vm" -n "$vm_namespace" --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      log_info "  Patched: ${vm}"
    done <<< "$stuck_vms"
    sleep 10
  fi

  # --- Remove stuck VMIs ---
  local stuck_vmis
  stuck_vmis=$($KUBECTL get virtualmachineinstances.kubevirt.io -n "$vm_namespace" \
    --no-headers -o name 2>/dev/null | grep "${cluster_name}" || true)

  if [[ -n "$stuck_vmis" ]]; then
    log_warn "Removing stuck VirtualMachineInstances..."
    while IFS= read -r vmi; do
      [[ -z "$vmi" ]] && continue
      $KUBECTL patch "$vmi" -n "$vm_namespace" --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      $KUBECTL delete "$vmi" -n "$vm_namespace" --wait=false 2>/dev/null || true
    done <<< "$stuck_vmis"
    sleep 5
  fi

  # --- Safety check: confirm namespace matches terraform.tfvars ---
  local expected_ns
  expected_ns=$(_get_tfvar_value vm_namespace 2>/dev/null || echo "")
  if [[ -n "$expected_ns" && "$vm_namespace" != "$expected_ns" ]]; then
    log_warn "VM namespace '${vm_namespace}' doesn't match tfvars '${expected_ns}' — skipping PVC cleanup"
    return 0
  fi

  # --- Delete ALL DataVolumes in namespace (workload PVCs from cluster services) ---
  local all_dvs
  all_dvs=$($KUBECTL get datavolumes.cdi.kubevirt.io -n "$vm_namespace" \
    --no-headers -o name 2>/dev/null || true)

  # --- Delete ALL PVCs in namespace (VM disks + workload volumes) ---
  # The namespace is dedicated to this cluster, so all PVCs are safe to remove.
  local all_pvcs
  all_pvcs=$($KUBECTL get pvc -n "$vm_namespace" --no-headers -o name 2>/dev/null || true)

  # High-count sanity check — warn if namespace has unexpectedly many resources
  local dv_count=0 pvc_count=0
  [[ -n "$all_dvs" ]] && dv_count=$(echo "$all_dvs" | wc -l | tr -d ' ')
  [[ -n "$all_pvcs" ]] && pvc_count=$(echo "$all_pvcs" | wc -l | tr -d ' ')
  if [[ $((dv_count + pvc_count)) -gt 20 ]]; then
    log_warn "Found ${dv_count} DVs + ${pvc_count} PVCs in '${vm_namespace}' — unusually high count"
    log_warn "Verify this is the correct namespace before cleanup completes"
  fi

  if [[ -n "$all_dvs" ]]; then
    log_warn "Found ${dv_count} DataVolume(s) in namespace — deleting..."
    while IFS= read -r dv; do
      [[ -z "$dv" ]] && continue
      $KUBECTL patch "$dv" -n "$vm_namespace" --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      $KUBECTL delete "$dv" -n "$vm_namespace" --wait=false 2>/dev/null || true
    done <<< "$all_dvs"
    sleep 5
  fi

  if [[ -n "$all_pvcs" ]]; then
    log_warn "Found ${pvc_count} PVC(s) in namespace — deleting..."
    while IFS= read -r pvc; do
      [[ -z "$pvc" ]] && continue
      $KUBECTL patch "$pvc" -n "$vm_namespace" --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      $KUBECTL delete "$pvc" -n "$vm_namespace" --wait=false 2>/dev/null || true
      log_info "  Deleted: ${pvc}"
    done <<< "$all_pvcs"
    log_ok "All PVCs cleaned up"
  else
    log_ok "No PVCs found"
  fi

  # --- Clean orphaned secrets in fleet-default (Rancher management cluster) ---
  # These secrets have no ownerReferences and are NOT cleaned up when Rancher
  # deletes the cluster: machine-driver-secret, machine-state, machine-certs-*,
  # and harvesterconfig* secrets.
  #
  # The Harvester kubeconfig (172.16.2.2) has limited RBAC and cannot see
  # fleet-default. We must use the Rancher API kubectl context instead.
  if [[ -n "$rancher_url" && -n "$rancher_token" ]]; then
    echo
    log_info "Cleaning orphaned secrets in fleet-default (via Rancher API)..."

    local rancher_kubeconfig
    rancher_kubeconfig="$(mktemp)"

    # Try to get private CA PEM; if available, use it for TLS verification
    local private_ca_pem ca_data cert_auth_line
    private_ca_pem=$(_get_tfvar_heredoc private_ca_pem)

    if [[ -n "$private_ca_pem" ]]; then
      # Base64 encode the CA PEM for kubeconfig
      ca_data=$(echo "$private_ca_pem" | base64 -w0)
      cert_auth_line="    certificate-authority-data: ${ca_data}"
    else
      # Fall back to insecure when CA not available
      cert_auth_line="    insecure-skip-tls-verify: true"
    fi

    cat > "$rancher_kubeconfig" <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: ${rancher_url}/k8s/clusters/local
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
    token: ${rancher_token}
KUBECONFIG
    chmod 600 "$rancher_kubeconfig"

    local RKUBECTL="kubectl --kubeconfig=${rancher_kubeconfig}"

    # machine-driver-secret: ${cluster_name}-*-machine-driver-secret
    local driver_secrets
    driver_secrets=$($RKUBECTL get secrets -n fleet-default --no-headers -o name 2>/dev/null \
      | grep "${cluster_name}-.*-machine-driver-secret" || true)

    local driver_count=0
    if [[ -n "$driver_secrets" ]]; then
      driver_count=$(echo "$driver_secrets" | wc -l | tr -d ' ')
      log_info "Deleting ${driver_count} machine-driver-secret(s)..."
      while IFS= read -r secret; do
        [[ -z "$secret" ]] && continue
        $RKUBECTL delete "$secret" -n fleet-default --wait=false 2>/dev/null || true
      done <<< "$driver_secrets"
    fi

    # machine-state: ${cluster_name}-*-machine-state (type rke.cattle.io/machine-state)
    local state_secrets
    state_secrets=$($RKUBECTL get secrets -n fleet-default --no-headers -o name 2>/dev/null \
      | grep "${cluster_name}-.*-machine-state" || true)

    local state_count=0
    if [[ -n "$state_secrets" ]]; then
      state_count=$(echo "$state_secrets" | wc -l | tr -d ' ')
      log_info "Deleting ${state_count} machine-state secret(s)..."
      while IFS= read -r secret; do
        [[ -z "$secret" ]] && continue
        $RKUBECTL delete "$secret" -n fleet-default --wait=false 2>/dev/null || true
      done <<< "$state_secrets"
    fi

    # machine-certs-*: only delete those with NO ownerReferences
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

    # harvesterconfig* secrets in fleet-default
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

    # dockerhub-auth secret (created by rancher2_secret_v2.dockerhub_auth)
    local dh_count=0
    if $RKUBECTL get secret "${cluster_name}-dockerhub-auth" -n fleet-default &>/dev/null; then
      $RKUBECTL delete secret "${cluster_name}-dockerhub-auth" -n fleet-default --wait=false 2>/dev/null || true
      log_info "Deleted dockerhub-auth secret: ${cluster_name}-dockerhub-auth"
      dh_count=1
    fi

    local secret_total=$((driver_count + state_count + cert_count + hc_count + dh_count))
    if [[ "$secret_total" -gt 0 ]]; then
      log_ok "Cleaned ${secret_total} orphaned secret(s) from fleet-default"
    else
      log_ok "No orphaned secrets found in fleet-default"
    fi

    # --- Clean stale cloud credentials ---
    # cmd_destroy() preserves the credential during destroy to prevent token
    # invalidation, but old credentials accumulate across destroy/apply cycles.
    # Safe to delete here since destroy is complete and next apply creates a fresh one.
    local stale_creds
    stale_creds=$(curl -sk -H "Authorization: Bearer ${rancher_token}" \
      "${rancher_url}/v3/cloudCredentials" 2>/dev/null \
      | jq -r ".data[] | select(.name | startswith(\"${cluster_name}\")) | .id" || true)

    local cred_count=0
    if [[ -n "$stale_creds" ]]; then
      cred_count=$(echo "$stale_creds" | wc -l | tr -d ' ')
      log_info "Deleting ${cred_count} stale cloud credential(s)..."
      while IFS= read -r cred_id; do
        [[ -z "$cred_id" ]] && continue
        curl -sk -X DELETE -H "Authorization: Bearer ${rancher_token}" \
          "${rancher_url}/v3/cloudCredentials/${cred_id}" >/dev/null 2>&1 || true
      done <<< "$stale_creds"
      log_ok "Cleaned ${cred_count} stale cloud credential(s)"
    else
      log_ok "No stale cloud credentials found"
    fi

    # --- Clean orphaned HarvesterConfigs ---
    local hc_list
    hc_list=$(curl -sk -H "Authorization: Bearer ${rancher_token}" \
      "${rancher_url}/v1/rke-machine-config.cattle.io.harvesterconfigs/fleet-default" 2>/dev/null \
      | jq -r ".data[]? | select(.metadata.name | startswith(\"${cluster_name}\")) | .metadata.name" || true)

    local hc_cfg_count=0
    if [[ -n "$hc_list" ]]; then
      hc_cfg_count=$(echo "$hc_list" | wc -l | tr -d ' ')
      log_info "Deleting ${hc_cfg_count} orphaned HarvesterConfig(s)..."
      while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        # Clear finalizers first in case they are stuck
        curl -sk -X PATCH -H "Authorization: Bearer ${rancher_token}" \
          -H "Content-Type: application/merge-patch+json" \
          "${rancher_url}/v1/rke-machine-config.cattle.io.harvesterconfigs/fleet-default/${name}" \
          -d '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
        curl -sk -X DELETE -H "Authorization: Bearer ${rancher_token}" \
          "${rancher_url}/v1/rke-machine-config.cattle.io.harvesterconfigs/fleet-default/${name}" >/dev/null 2>&1 || true
        log_info "  Deleted: ${name}"
      done <<< "$hc_list"
      log_ok "Cleaned ${hc_cfg_count} orphaned HarvesterConfig(s)"
    else
      log_ok "No orphaned HarvesterConfigs found"
    fi

    # --- Clean Harvester RBAC for the destroyed cluster ---
    echo
    log_info "Cleaning Harvester RBAC for cluster '${cluster_name}'..."

    # ClusterRoleBindings matching the cluster name (on Rancher management cluster)
    local crbs
    crbs=$($RKUBECTL get clusterrolebindings --no-headers -o name 2>/dev/null \
      | grep "${cluster_name}" || true)

    local crb_count=0
    if [[ -n "$crbs" ]]; then
      crb_count=$(echo "$crbs" | wc -l | tr -d ' ')
      log_info "Deleting ${crb_count} ClusterRoleBinding(s)..."
      while IFS= read -r crb; do
        [[ -z "$crb" ]] && continue
        $RKUBECTL delete "$crb" --wait=false 2>/dev/null || true
        log_info "  Deleted: ${crb}"
      done <<< "$crbs"
    fi

    # ServiceAccount for the cluster in default namespace (on Harvester)
    if $KUBECTL get serviceaccount "${cluster_name}" -n default &>/dev/null; then
      $KUBECTL delete serviceaccount "${cluster_name}" -n default --wait=false 2>/dev/null || true
      log_info "Deleted ServiceAccount '${cluster_name}' in default namespace (Harvester)"
    fi

    # ClusterRoleBindings on Harvester matching the cluster name
    local hvst_crbs
    hvst_crbs=$($KUBECTL get clusterrolebindings --no-headers -o name 2>/dev/null \
      | grep "${cluster_name}" || true)

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

    local rbac_total=$((crb_count + hvst_crb_count))
    if [[ "$rbac_total" -gt 0 ]]; then
      log_ok "Cleaned ${rbac_total} RBAC resource(s)"
    else
      log_ok "No orphaned RBAC resources found"
    fi

    # Clean up temp kubeconfig
    rm -f "$rancher_kubeconfig"
  else
    log_warn "Rancher URL or token not available — skipping fleet-default and RBAC cleanup"
  fi

  # --- Summary ---
  local remaining
  remaining=$($KUBECTL get pvc -n "$vm_namespace" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$remaining" -gt 0 ]]; then
    log_warn "${remaining} PVC(s) still in namespace '${vm_namespace}' (deletion may be in progress)"
    $KUBECTL get pvc -n "$vm_namespace" --no-headers 2>/dev/null | while read -r line; do
      log_info "  ${line}"
    done
  else
    log_ok "Namespace '${vm_namespace}' is clean"
  fi
}

cmd_destroy() {
  check_connectivity
  pull_secrets
  echo

  # Ensure backend is initialized (may be missing after fresh clone or .terraform cleanup)
  cd "$SCRIPT_DIR"
  if [[ ! -d .terraform ]] || ! terraform validate -no-color &>/dev/null; then
    log_info "Initializing Terraform backend..."
    if ! terraform init -input=false 2>&1; then
      log_warn "Backend init failed — retrying with -reconfigure (backend config hash may be stale)..."
      terraform init -input=false -reconfigure
    fi
    echo
  fi

  clear_stale_lock

  # Capture VM namespace and cluster name BEFORE destroy removes Terraform state
  local vm_namespace cluster_name
  vm_namespace=$(_get_tfvar_value vm_namespace)
  cluster_name=$(_get_tfvar_value cluster_name)

  # ---------------------------------------------------------------------------
  # Preserve cloud credential across destroy/recreate cycles.
  #
  # The cloud credential kubeconfig shares a Rancher token with the state
  # backend kubeconfig. If Terraform destroys the credential, Rancher
  # invalidates the token and Terraform can't save state (403). Instead of
  # a complex recovery dance, we simply remove the credential from state
  # before destroy — Rancher keeps it alive, tokens stay valid, and the
  # next 'apply' will recreate it in state.
  # ---------------------------------------------------------------------------
  if terraform state show rancher2_cloud_credential.harvester &>/dev/null; then
    log_info "Preserving cloud credential (removing from state to prevent token invalidation)..."
    terraform state rm rancher2_cloud_credential.harvester &>/dev/null || true
    log_ok "Cloud credential preserved in Rancher"
  fi

  log_info "Running: terraform destroy $*"
  cd "$SCRIPT_DIR"
  local tf_exit=0
  terraform destroy "$@" || tf_exit=$?

  if [[ $tf_exit -ne 0 ]]; then
    log_error "Terraform destroy failed (exit $tf_exit)"
    return $tf_exit
  fi

  # Clean up orphaned Harvester resources that terraform destroy leaves behind
  post_destroy_cleanup "$vm_namespace" "$cluster_name"

  # Push secrets after successful destroy (state is now empty but secrets persist)
  echo
  log_info "Pushing secrets to Harvester after successful destroy..."
  ensure_namespace
  push_secrets
}

# --- Main ---

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args...]

Commands:
  init            Initialize K8s backend (create namespace, push secrets, migrate state)
  apply           Pull secrets → plan (saved) → apply → push secrets to Harvester
  destroy         Destroy cluster + cleanup orphaned VMs/PVCs + push secrets
  push-secrets    Push local tfvars + kubeconfigs to K8s secrets
  pull-secrets    Pull tfvars + kubeconfigs from K8s secrets to local files
  validate        Validate config + check golden image exists on Harvester
  <any>           Pull secrets, then run 'terraform <any>' (e.g., plan, output)

Examples:
  $(basename "$0") init
  $(basename "$0") apply
  $(basename "$0") destroy -auto-approve
  $(basename "$0") plan
  $(basename "$0") push-secrets
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
  init)
    cmd_init
    ;;
  apply)
    cmd_apply
    ;;
  push-secrets)
    cmd_push_secrets
    ;;
  pull-secrets)
    cmd_pull_secrets
    ;;
  destroy)
    cmd_destroy "$@"
    ;;
  validate)
    cmd_validate
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    cmd_terraform "$COMMAND" "$@"
    ;;
esac
