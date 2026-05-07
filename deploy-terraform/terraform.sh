#!/usr/bin/env bash
# =============================================================================
# terraform.sh — multi-cluster Terraform wrapper for harvester-rke2-cluster
# =============================================================================
# Wraps `terraform init/plan/apply/destroy/validate` with the per-cluster
# tfvars + per-cluster Kubernetes-state-backend (`secret_suffix=<cluster>`)
# pattern this repo uses for rke2-test and rke2-prod.
#
# Usage:
#   ./terraform.sh --cluster rke2-prod init
#   ./terraform.sh --cluster rke2-prod apply
#   ./terraform.sh --cluster rke2-prod destroy
#   ./terraform.sh --cluster rke2-test plan
#   ./terraform.sh --cluster rke2-prod -- terraform-arg ...
#
# Or set CLUSTER env var instead of --cluster:
#   CLUSTER=rke2-prod ./terraform.sh apply
# =============================================================================

set -euo pipefail

# --- Colors & Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
TF_CLI_CONFIG_FILE="${TF_CLI_CONFIG_FILE:-}"

# --- Cluster selection (must come from --cluster flag or CLUSTER env) ---
CLUSTER="${CLUSTER:-}"

# These are populated once CLUSTER is known, in resolve_cluster_paths().
TFVARS_FILE=""
CLUSTER_KUBECONFIG_CRED=""
CLUSTER_KUBECONFIG_CP=""
SECRET_FILENAMES=()
SECRET_NAMES=()

resolve_cluster_paths() {
  [[ -n "${CLUSTER}" ]] || die "--cluster <name> is required (or set CLUSTER env). Examples: rke2-prod, rke2-test"
  TFVARS_FILE="${SCRIPT_DIR}/${CLUSTER}.tfvars"
  [[ -f "${TFVARS_FILE}" ]] || die "tfvars file not found: ${TFVARS_FILE}"
  CLUSTER_KUBECONFIG_CRED="${REPO_ROOT}/kubeconfig-harvester-cloud-cred-${CLUSTER}.yaml"
  CLUSTER_KUBECONFIG_CP="${REPO_ROOT}/harvester-cloud-provider-kubeconfig-${CLUSTER}"

  # Per-cluster .terraform/ so two clusters can run init/plan/apply concurrently
  # without trampling each other's backend config and provider cache.
  export TF_DATA_DIR="${SCRIPT_DIR}/.terraform-${CLUSTER}"

  # Files synced to/from K8s secrets so they survive across worker machines.
  SECRET_FILENAMES=(
    "${TFVARS_FILE}"
    "${HARVESTER_KUBECONFIG}"
    "${CLUSTER_KUBECONFIG_CRED}"
    "${CLUSTER_KUBECONFIG_CP}"
    "${REPO_ROOT}/vault-init.json"
  )
  SECRET_NAMES=(
    "${CLUSTER}-tfvars"
    "kubeconfig-harvester"
    "${CLUSTER}-kubeconfig-cloud-cred"
    "${CLUSTER}-cloud-provider-kubeconfig"
    "vault-init"
  )
}

# --- TFVARS readers (cluster-aware) ---
_get_tfvar_value() {
  awk -F'"' "/^${1}[[:space:]]/ {print \$2}" "${TFVARS_FILE}" 2>/dev/null || echo ""
}

_get_tfvar_heredoc() {
  local key="$1"
  local in_block=0
  while IFS= read -r line; do
    if [[ "$in_block" -eq 0 && "$line" =~ ^${key}[[:space:]]*=.*EOT$ ]]; then
      in_block=1
      continue
    elif [[ "$in_block" -eq 1 ]]; then
      [[ "$line" == "EOT" ]] && return 0
      echo "$line"
    fi
  done < "${TFVARS_FILE}"
  return 0
}

# --- TF wrapper that picks up the filesystem mirror config (avoids registry rate-limits) ---
TF() {
  if [[ -n "${TF_CLI_CONFIG_FILE}" ]]; then
    TF_CLI_CONFIG_FILE="${TF_CLI_CONFIG_FILE}" terraform "$@"
  else
    terraform "$@"
  fi
}

check_prerequisites() {
  local missing=()
  for cmd in kubectl terraform jq; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] || { log_error "Missing required tools: ${missing[*]}"; exit 1; }
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
      die "Harvester kubeconfig not found: ${HARVESTER_KUBECONFIG} (and no 'harvester' context in ~/.kube/config)"
    fi
  fi
  $KUBECTL cluster-info &>/dev/null || die "Cannot connect to Harvester cluster via ${HARVESTER_KUBECONFIG}"
  log_ok "Harvester cluster is reachable"
}

ensure_namespace() {
  if ! $KUBECTL get namespace "$TF_NAMESPACE" &>/dev/null; then
    log_info "Creating namespace ${TF_NAMESPACE}..."
    $KUBECTL create namespace "$TF_NAMESPACE"
    log_ok "Namespace ${TF_NAMESPACE} created"
  fi
}

clear_stale_lock() {
  cd "$SCRIPT_DIR"
  local output
  output=$(TF plan -input=false -no-color -var-file="${TFVARS_FILE}" 2>&1 || true)
  if echo "$output" | grep -q "Error acquiring the state lock"; then
    local lock_id
    lock_id=$(echo "$output" | grep 'ID:' | head -1 | awk '{print $2}')
    if [[ -n "$lock_id" ]]; then
      log_warn "Terraform state is locked (stale lock from a previous run, ID=${lock_id})"
      log_info "Auto-unlocking..."
      TF force-unlock -force "$lock_id" 2>/dev/null && log_ok "State lock cleared" \
        || die "Failed to clear state lock. Run: terraform force-unlock -force ${lock_id}"
    fi
  fi
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

# Backend init — uses per-cluster secret_suffix.
tf_init_backend() {
  cd "$SCRIPT_DIR"
  log_info "terraform init -reconfigure -backend-config=\"secret_suffix=${CLUSTER}\""
  if ! TF init -input=false -reconfigure -backend-config="secret_suffix=${CLUSTER}" 2>&1; then
    die "Terraform init failed for cluster=${CLUSTER}. Check Harvester connectivity + RBAC on namespace ${TF_NAMESPACE}."
  fi
}

# --- Commands ---

cmd_init() {
  log_info "Initializing Terraform with Kubernetes backend for cluster ${CLUSTER}..."
  echo
  check_prerequisites
  check_connectivity
  ensure_namespace
  echo
  push_secrets
  echo
  log_info "Running: terraform init -migrate-state -backend-config=\"secret_suffix=${CLUSTER}\""
  cd "$SCRIPT_DIR"
  TF init -input=false -migrate-state -backend-config="secret_suffix=${CLUSTER}"
  echo
  log_ok "Initialization complete. State stored in K8s secret: tfstate-default-${CLUSTER}"
}

cmd_push_secrets() { check_connectivity; ensure_namespace; push_secrets; }
cmd_pull_secrets() { check_connectivity; pull_secrets; }

cmd_apply() {
  check_connectivity
  pull_secrets
  echo
  cd "$SCRIPT_DIR"

  # Re-init if missing or if tfvars changed
  local needs_init=false
  if [[ ! -d "${TF_DATA_DIR}" ]]; then
    needs_init=true
  elif [[ "${TFVARS_FILE}" -nt "${TF_DATA_DIR}" ]]; then
    log_info "${TFVARS_FILE} is newer than ${TF_DATA_DIR}/ — forcing re-init..."
    needs_init=true
  elif ! TF validate -no-color &>/dev/null; then
    needs_init=true
  fi
  [[ "$needs_init" == "true" ]] && tf_init_backend

  clear_stale_lock

  local plan_file="tfplan_${CLUSTER}_$(date +%Y%m%d_%H%M%S)"
  log_info "Running: terraform plan -var-file=${TFVARS_FILE##*/} -out=${plan_file}"
  TF plan -var-file="${TFVARS_FILE}" -out="$plan_file"
  echo

  log_info "Running: terraform apply ${plan_file}"
  local tf_exit=0
  TF apply "$plan_file" || tf_exit=$?
  rm -f "$plan_file"

  if [[ $tf_exit -ne 0 ]]; then
    if TF state list 2>/dev/null | grep -q "rancher2_cluster_v2"; then
      log_warn "Terraform exited $tf_exit but resources were created — continuing"
    else
      log_error "Terraform apply failed (exit $tf_exit)"
      return $tf_exit
    fi
  fi
  echo

  log_info "Pushing secrets to Harvester after successful apply..."
  ensure_namespace
  push_secrets
}

cmd_validate() {
  check_connectivity
  pull_secrets
  echo
  cd "$SCRIPT_DIR"

  if [[ ! -d "${TF_DATA_DIR}" ]] || ! TF validate -no-color &>/dev/null; then
    tf_init_backend
  fi

  log_info "terraform validate"
  TF validate || die "Terraform validation failed"
  log_ok "Terraform configuration is valid"
  echo

  local golden_image image_namespace
  golden_image=$(_get_tfvar_value golden_image_name)
  image_namespace=$(_get_tfvar_value harvester_image_namespace)
  [[ -n "$golden_image" ]] || die "golden_image_name not set in ${TFVARS_FILE}"
  # harvester_image_namespace defaults to "default" in variables.tf if unset.
  image_namespace="${image_namespace:-default}"

  log_info "Checking golden image '${golden_image}' exists in namespace '${image_namespace}'..."
  if $KUBECTL get virtualmachineimages.harvesterhci.io "${golden_image}" -n "${image_namespace}" &>/dev/null; then
    log_ok "Golden image '${golden_image}' found on Harvester"
  else
    die "Golden image '${golden_image}' not found in namespace '${image_namespace}' — upload before apply"
  fi
}

# Generic passthrough for `terraform <anything>` with var-file injection
cmd_terraform() {
  check_connectivity
  pull_secrets
  echo
  cd "$SCRIPT_DIR"

  # Init backend on first run / after backend reconfigure needs
  [[ -d "${TF_DATA_DIR}" ]] || tf_init_backend

  # Inject -var-file for commands that take vars
  case "$1" in
    plan|apply|destroy|refresh|console|import|taint|untaint)
      log_info "terraform $* -var-file=${TFVARS_FILE##*/}"
      TF "$@" -var-file="${TFVARS_FILE}"
      ;;
    *)
      log_info "terraform $*"
      TF "$@"
      ;;
  esac
}

# --- Post-destroy cleanup (cluster-aware) ---
post_destroy_cleanup() {
  local vm_namespace="$1" cluster_name="$2"
  [[ -n "$vm_namespace" && -n "$cluster_name" ]] || { log_warn "VM namespace or cluster name missing — skipping cleanup"; return 0; }
  echo
  log_info "Post-destroy cleanup for cluster '${cluster_name}' in namespace '${vm_namespace}'..."

  local rancher_url rancher_token
  rancher_url=$(_get_tfvar_value rancher_url)
  rancher_token=$(_get_tfvar_value rancher_token)
  if [[ -z "$rancher_url" || -z "$rancher_token" ]]; then
    log_warn "rancher_url/rancher_token missing in tfvars — skipping API-based cleanup"
    return 0
  fi
  local auth_header="Authorization: Bearer ${rancher_token}"

  # HarvesterMachine + CAPI Machine + provisioning cluster finalizer cleanup
  for kind in 'rke-machine.cattle.io.harvestermachines' 'cluster.x-k8s.io.machines'; do
    local stuck
    stuck=$(curl -sk -H "$auth_header" "${rancher_url}/v1/${kind}" 2>/dev/null \
      | jq -r '.data[]? | select(.metadata.deletionTimestamp != null) | .metadata.name' 2>/dev/null || true)
    if [[ -n "$stuck" ]]; then
      log_warn "Clearing stuck ${kind} finalizers..."
      while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        curl -sk -X PATCH -H "$auth_header" -H "Content-Type: application/merge-patch+json" \
          "${rancher_url}/v1/${kind}/fleet-default/${name}" \
          -d '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
        curl -sk -X DELETE -H "$auth_header" \
          "${rancher_url}/v1/${kind}/fleet-default/${name}" >/dev/null 2>&1 || true
      done <<< "$stuck"
      sleep 5
    fi
  done

  # Cluster object finalizer
  local cluster_dt
  cluster_dt=$(curl -sk -H "$auth_header" \
    "${rancher_url}/v1/provisioning.cattle.io.clusters/fleet-default/${cluster_name}" 2>/dev/null \
    | jq -r '.metadata.deletionTimestamp // empty' 2>/dev/null || true)
  if [[ -n "$cluster_dt" ]]; then
    log_warn "Clearing stuck cluster '${cluster_name}' finalizers..."
    curl -sk -X PATCH -H "$auth_header" -H "Content-Type: application/merge-patch+json" \
      "${rancher_url}/v1/provisioning.cattle.io.clusters/fleet-default/${cluster_name}" \
      -d '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    sleep 5
  fi

  # Wait for VMs to terminate (cluster name prefix match)
  local timeout=300 interval=10 elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local vm_count
    vm_count=$($KUBECTL get vm -n "$vm_namespace" --no-headers 2>/dev/null | grep -c "^${cluster_name}-" || true)
    [[ "$vm_count" -eq 0 ]] && { log_ok "All cluster VMs deleted"; break; }
    log_info "  ${vm_count} VM(s) still deleting (${elapsed}s/${timeout}s)..."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  # Force-clear stuck VMs/VMIs
  local stuck_vms stuck_vmis
  stuck_vms=$($KUBECTL get vm -n "$vm_namespace" --no-headers -o name 2>/dev/null | grep "${cluster_name}" || true)
  if [[ -n "$stuck_vms" ]]; then
    log_warn "Removing stuck finalizers from remaining VMs..."
    while IFS= read -r vm; do
      [[ -z "$vm" ]] && continue
      $KUBECTL patch "$vm" -n "$vm_namespace" --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    done <<< "$stuck_vms"
    sleep 10
  fi
  stuck_vmis=$($KUBECTL get vmi -n "$vm_namespace" --no-headers -o name 2>/dev/null | grep "${cluster_name}" || true)
  if [[ -n "$stuck_vmis" ]]; then
    log_warn "Removing stuck VMIs..."
    while IFS= read -r vmi; do
      [[ -z "$vmi" ]] && continue
      $KUBECTL patch "$vmi" -n "$vm_namespace" --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      $KUBECTL delete "$vmi" -n "$vm_namespace" --wait=false 2>/dev/null || true
    done <<< "$stuck_vmis"
    sleep 5
  fi

  # Harvester-host CRs created via kubernetes_manifest (e.g. MigrationPolicies)
  # are not children of the prov.cattle.io cluster CR — UI cluster-delete and
  # rancher2_cluster_v2 destroy do not cascade to them. If a previous apply was
  # killed mid-flight, these survive as orphans and block re-apply with
  # "Cannot create resource that already exists". Clean them by label.
  local orphan_mp
  orphan_mp=$($KUBECTL get migrationpolicies.migrations.kubevirt.io \
    -l "rke.cattle.io/cluster-name=${cluster_name}" \
    --no-headers -o name 2>/dev/null || true)
  if [[ -n "$orphan_mp" ]]; then
    log_warn "Removing orphan MigrationPolicies labeled cluster=${cluster_name}..."
    while IFS= read -r mp; do
      [[ -z "$mp" ]] && continue
      $KUBECTL delete "$mp" --wait=false 2>/dev/null || true
    done <<< "$orphan_mp"
    log_ok "Cleaned orphan MigrationPolicies"
  fi

  # NOTE: cloud credentials are intentionally NOT deleted here.
  # cmd_destroy state-rms rancher2_cloud_credential.harvester before destroy so
  # the resource is preserved across cluster rebuilds (avoids Rancher-token
  # churn). For full teardown including creds, use nuke-cluster.sh.
}

cmd_destroy() {
  check_connectivity
  pull_secrets
  echo

  cd "$SCRIPT_DIR"
  [[ -d "${TF_DATA_DIR}" ]] || tf_init_backend

  clear_stale_lock

  local vm_namespace cluster_name
  vm_namespace=$(_get_tfvar_value vm_namespace)
  cluster_name=$(_get_tfvar_value cluster_name)

  # Preserve cloud credential to avoid Rancher token invalidation
  if TF state show rancher2_cloud_credential.harvester &>/dev/null; then
    log_info "Preserving cloud credential (state rm to prevent token invalidation)..."
    TF state rm rancher2_cloud_credential.harvester &>/dev/null || true
    log_ok "Cloud credential preserved in Rancher"
  fi

  log_info "Running: terraform destroy -var-file=${TFVARS_FILE##*/} $*"
  cd "$SCRIPT_DIR"
  local tf_exit=0
  TF destroy -var-file="${TFVARS_FILE}" "$@" || tf_exit=$?
  if [[ $tf_exit -ne 0 ]]; then
    log_error "Terraform destroy failed (exit $tf_exit)"
    return $tf_exit
  fi

  post_destroy_cleanup "$vm_namespace" "$cluster_name"

  echo
  log_info "Pushing secrets to Harvester after successful destroy..."
  ensure_namespace
  push_secrets
}

# --- Main ---

usage() {
  cat <<EOF
Usage: $(basename "$0") [--cluster <name>] <command> [args...]

  --cluster <name>    Required (or set CLUSTER env). One of: rke2-prod, rke2-test,
                      or any other <name>.tfvars in this directory.

Commands:
  init            Initialize K8s backend with secret_suffix=<cluster> + push secrets
  apply           Pull secrets → plan -var-file=<cluster>.tfvars → apply → push secrets
  destroy         terraform destroy -var-file=<cluster>.tfvars + cleanup orphaned resources
  push-secrets    Push local tfvars + kubeconfigs to K8s secrets
  pull-secrets    Pull tfvars + kubeconfigs from K8s secrets to local files
  validate        validate + check golden image exists on Harvester
  <any>           passthrough: terraform <any> -var-file=<cluster>.tfvars (when applicable)

Examples:
  ./$(basename "$0") --cluster rke2-prod init
  ./$(basename "$0") --cluster rke2-prod apply
  ./$(basename "$0") --cluster rke2-prod destroy -auto-approve
  ./$(basename "$0") --cluster rke2-test plan
  CLUSTER=rke2-prod ./$(basename "$0") apply
EOF
}

[[ $# -ge 1 ]] || { usage; exit 1; }

# Parse --cluster flag (must come before command)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)
      [[ $# -ge 2 ]] || die "--cluster requires a value"
      CLUSTER="$2"; shift 2 ;;
    --cluster=*)
      CLUSTER="${1#--cluster=}"; shift ;;
    -h|--help|help)
      usage; exit 0 ;;
    *) break ;;
  esac
done

[[ $# -ge 1 ]] || { usage; exit 1; }

resolve_cluster_paths

COMMAND="$1"; shift
case "$COMMAND" in
  init)         cmd_init ;;
  apply)        cmd_apply ;;
  push-secrets) cmd_push_secrets ;;
  pull-secrets) cmd_pull_secrets ;;
  destroy)      cmd_destroy "$@" ;;
  validate)     cmd_validate ;;
  *)            cmd_terraform "$COMMAND" "$@" ;;
esac
