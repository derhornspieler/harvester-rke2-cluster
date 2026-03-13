#!/usr/bin/env bash
# =============================================================================
# prepare.sh — Credential & Kubeconfig Preparation for RKE2 Cluster Deployment
# =============================================================================
# Standalone script for first-time setup. Generates:
#   1. kubeconfig-harvester.yaml           (Harvester management access)
#   2. kubeconfig-harvester-cloud-cred.yaml (Rancher cloud credential)
#   3. harvester-cloud-provider-kubeconfig  (Harvester cloud provider)
#   4. .env                                (from .env.example, for rancher-api-deploy.sh)
#   5. terraform.tfvars                    (from terraform/terraform.tfvars.example)
#
# Does NOT source lib.sh — intended for fresh environments with no prior setup.
#
# Usage:
#   cd cluster && ./prepare.sh
#   ./prepare.sh --help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Colors (match lib.sh)
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

die() {
  log_error "$@"
  exit 1
}

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Prepare credentials and kubeconfigs for RKE2 cluster deployment on Harvester.

Options:
  -h, --help                Show this help message and exit
  -r, --refresh-credentials Refresh only credentials and kubeconfigs without
                            touching other terraform.tfvars values. Requires an
                            existing terraform.tfvars (falls back to full setup
                            if missing).

Modes:
  Full setup (default):
    1. Verify prerequisites (curl, kubectl, jq, python3)
    2. Authenticate to Rancher and create a permanent API token
    3. Generate Harvester kubeconfigs (management, cloud credential, cloud provider)
    4. Create terraform.tfvars from terraform.tfvars.example with discovered values

  Credential refresh (--refresh-credentials):
    1. Read cluster settings from existing terraform.tfvars
    2. Prompt only for Rancher username and password
    3. Regenerate API token and all 3 kubeconfigs
    4. Update only rancher_token and harvester_cloud_credential_name in terraform.tfvars

All generated files are written to: ${SCRIPT_DIR}/

Prerequisites:
  - curl, kubectl, jq, python3 must be installed
  - Network access to the Rancher management server
  - Rancher admin (or equivalent) credentials
  - A Harvester cluster registered in Rancher

After running this script, edit terraform.tfvars to fill in remaining values,
then run: terraform init && terraform plan
EOF
  exit 0
}

# -----------------------------------------------------------------------------
# Read a simple key = "value" from terraform.tfvars
# Same pattern as _get_tfvar_value in terraform.sh / nuke-cluster.sh.
# -----------------------------------------------------------------------------
read_tfvar() {
  local key="$1"
  awk -F'"' "/^${key}[[:space:]]/ {print \$2}" "${SCRIPT_DIR}/terraform.tfvars" 2>/dev/null || echo ""
}

# -----------------------------------------------------------------------------
# Prompt helpers
# -----------------------------------------------------------------------------

# prompt_value PROMPT DEFAULT VARNAME
# Prompts the user and sets VARNAME to the input (or DEFAULT if empty).
prompt_value() {
  local prompt="$1" default="$2" varname="$3"
  local input
  if [[ -n "${default}" ]]; then
    read -rp "$(echo -e "${CYAN}${prompt}${NC} [${default}]: ")" input
    printf -v "${varname}" '%s' "${input:-${default}}"
  else
    read -rp "$(echo -e "${CYAN}${prompt}${NC}: ")" input
    [[ -z "${input}" ]] && die "A value is required for: ${prompt}"
    printf -v "${varname}" '%s' "${input}"
  fi
}

# prompt_secret PROMPT VARNAME
# Reads a password without echoing.
prompt_secret() {
  local prompt="$1" varname="$2"
  local input
  read -rsp "$(echo -e "${CYAN}${prompt}${NC}: ")" input
  echo ""
  [[ -z "${input}" ]] && die "A value is required for: ${prompt}"
  printf -v "${varname}" '%s' "${input}"
}

# confirm_overwrite FILE
# Returns 0 if OK to write, 1 if user declines.
confirm_overwrite() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    log_warn "File already exists: $(basename "${file}")"
    local answer
    read -rp "$(echo -e "${YELLOW}Overwrite? [y/N]:${NC} ")" answer
    [[ "${answer}" =~ ^[Yy] ]] && return 0
    log_info "Skipping $(basename "${file}")"
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Rancher API helper
# -----------------------------------------------------------------------------
SESSION_TOKEN=""

# rancher_api METHOD PATH [DATA]
# Calls the Rancher API using the session token. Returns the response body.
rancher_api() {
  local method="$1" path="$2" data="${3:-}"
  local url="${RANCHER_URL}${path}"
  local args=(-sk -X "${method}" -H "Authorization: Bearer ${SESSION_TOKEN}" -H "Content-Type: application/json")
  if [[ -n "${data}" ]]; then
    args+=(-d "${data}")
  fi
  curl "${args[@]}" "${url}" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------------------
check_prerequisites() {
  local require_example="${1:-true}"
  log_info "Checking prerequisites..."
  local missing=()
  for cmd in curl kubectl jq python3; do
    if ! command -v "${cmd}" &>/dev/null; then
      missing+=("${cmd}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required commands: ${missing[*]}"
  fi
  if [[ "${require_example}" == true && ! -f "${SCRIPT_DIR}/terraform.tfvars.example" ]]; then
    die "terraform.tfvars.example not found in ${SCRIPT_DIR}"
  fi
  log_ok "All prerequisites met"
}

# -----------------------------------------------------------------------------
# Rancher authentication
# -----------------------------------------------------------------------------
rancher_login() {
  log_info "Authenticating to Rancher..."
  local response
  response=$(curl -sk -X POST \
    "${RANCHER_URL}/v3-public/localProviders/local?action=login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${RANCHER_USER}\",\"password\":\"${RANCHER_PASS}\"}" 2>/dev/null)

  SESSION_TOKEN=$(echo "${response}" | jq -r '.token // empty')
  if [[ -z "${SESSION_TOKEN}" ]]; then
    local message
    message=$(echo "${response}" | jq -r '.message // "unknown error"')
    die "Rancher login failed: ${message}"
  fi
  log_ok "Authenticated to Rancher as ${RANCHER_USER}"
}

# -----------------------------------------------------------------------------
# API token creation
# -----------------------------------------------------------------------------
create_api_token() {
  log_info "Creating permanent API token for Terraform..."
  local response
  # NOTE: ttl=0 creates a non-expiring token intentionally for Terraform automation.
  # This allows unattended Terraform operations (e.g., CI/CD, scheduled tasks) without
  # requiring manual token rotation. The token is stored in terraform.tfvars with restricted
  # file permissions (0600). Rotate periodically in production.
  # TODO: Implement automated token rotation (e.g., annual, via CI job) and update this comment
  #       with a reference to the rotation procedure.
  response=$(rancher_api POST "/v3/tokens" \
    "{\"type\":\"token\",\"description\":\"Terraform - ${CLUSTER_NAME}\",\"ttl\":0}")

  API_TOKEN=$(echo "${response}" | jq -r '.token // empty')
  if [[ -z "${API_TOKEN}" ]]; then
    local message
    message=$(echo "${response}" | jq -r '.message // "unknown error"')
    die "Failed to create API token: ${message}"
  fi
  log_ok "API token created: ${API_TOKEN%%:*}:***"
}

# -----------------------------------------------------------------------------
# Harvester cluster discovery
# -----------------------------------------------------------------------------
discover_harvester_id() {
  log_info "Discovering Harvester cluster ID from Rancher..."
  local response
  response=$(rancher_api GET "/v3/clusters")

  HARVESTER_ID=$(echo "${response}" | jq -r \
    '.data[] | select(.driver == "harvester" or ((.labels // {}) | .["provider.cattle.io"] == "harvester")) | .id' \
    | head -1)

  if [[ -z "${HARVESTER_ID}" ]]; then
    die "No Harvester cluster found in Rancher. Is one registered?"
  fi
  log_ok "Harvester cluster ID: ${HARVESTER_ID}"
}

# -----------------------------------------------------------------------------
# Kubeconfig generation
# -----------------------------------------------------------------------------
generate_harvester_kubeconfig() {
  local output="${SCRIPT_DIR}/kubeconfig-harvester.yaml"
  confirm_overwrite "${output}" || return 0

  log_info "Generating Harvester kubeconfig..."
  local response
  response=$(rancher_api POST "/v3/clusters/${HARVESTER_ID}?action=generateKubeconfig")

  local config
  config=$(echo "${response}" | jq -r '.config // empty')
  if [[ -z "${config}" ]]; then
    die "Failed to generate Harvester kubeconfig"
  fi
  echo "${config}" > "${output}"
  chmod 600 "${output}"
  log_ok "Created $(basename "${output}")"

  # Validate connectivity
  log_info "Validating kubeconfig..."
  if kubectl --kubeconfig="${output}" cluster-info &>/dev/null; then
    log_ok "Harvester kubeconfig validated successfully"
  else
    log_warn "Could not reach Harvester API -- check network connectivity"
  fi
}

generate_cloud_cred_kubeconfig() {
  local source="${SCRIPT_DIR}/kubeconfig-harvester.yaml"
  local output="${SCRIPT_DIR}/kubeconfig-harvester-cloud-cred.yaml"

  if [[ ! -f "${source}" ]]; then
    log_warn "Skipping cloud-cred kubeconfig -- kubeconfig-harvester.yaml not found"
    return 0
  fi
  confirm_overwrite "${output}" || return 0

  log_info "Generating cloud credential kubeconfig..."
  local server ca_data token_value
  server=$(kubectl --kubeconfig="${source}" config view --raw -o jsonpath='{.clusters[0].cluster.server}')
  ca_data=$(kubectl --kubeconfig="${source}" config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  token_value=$(kubectl --kubeconfig="${source}" config view --raw -o jsonpath='{.users[0].user.token}')

  cat > "${output}" <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
- name: harvester
  cluster:
    server: ${server}
    certificate-authority-data: ${ca_data}
contexts:
- name: harvester
  context:
    cluster: harvester
    user: ${CLUSTER_NAME}-cloud-cred
current-context: harvester
users:
- name: ${CLUSTER_NAME}-cloud-cred
  user:
    token: ${token_value}
KUBECONFIG
  chmod 600 "${output}"
  log_ok "Created $(basename "${output}")"
}

generate_cloud_provider_kubeconfig() {
  local output="${SCRIPT_DIR}/harvester-cloud-provider-kubeconfig"
  confirm_overwrite "${output}" || return 0

  log_info "Generating cloud provider kubeconfig..."
  local response
  response=$(rancher_api POST "/k8s/clusters/${HARVESTER_ID}/v1/harvester/kubeconfig" \
    "{\"clusterRoleName\":\"harvesterhci.io:cloudprovider\",\"namespace\":\"${VM_NAMESPACE}\",\"serviceAccountName\":\"${CLUSTER_NAME}\"}")

  # Response is a JSON-escaped string -- unescape it
  local config
  config=$(echo "${response}" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()))")
  if [[ -z "${config}" || "${config}" == "None" ]]; then
    die "Failed to generate cloud provider kubeconfig"
  fi
  echo "${config}" > "${output}"
  chmod 600 "${output}"
  log_ok "Created $(basename "${output}")"
}

# -----------------------------------------------------------------------------
# Terraform state namespace
# -----------------------------------------------------------------------------
ensure_terraform_state_ns() {
  local kubeconfig="${SCRIPT_DIR}/kubeconfig-harvester.yaml"
  if [[ ! -f "${kubeconfig}" ]]; then
    log_warn "Skipping terraform-state namespace -- kubeconfig-harvester.yaml not found"
    return 0
  fi
  log_info "Ensuring terraform-state namespace exists on Harvester..."
  kubectl --kubeconfig="${kubeconfig}" create namespace terraform-state \
    --dry-run=client -o yaml | kubectl --kubeconfig="${kubeconfig}" apply -f - 2>/dev/null
  log_ok "Namespace terraform-state ready"
}

# -----------------------------------------------------------------------------
# terraform.tfvars generation (for Terraform — lives in deploy-terraform/)
# -----------------------------------------------------------------------------
generate_tfvars() {
  local source="${SCRIPT_DIR}/deploy-terraform/terraform.tfvars.example"
  local output="${SCRIPT_DIR}/deploy-terraform/terraform.tfvars"
  confirm_overwrite "${output}" || return 0

  log_info "Generating terraform.tfvars from example..."
  local cloud_cred_name="${CLUSTER_NAME}-harvester"
  cp "${source}" "${output}"

  # Replace known values using sed (delimiter = | to avoid URL conflicts)
  sed -i \
    -e "s|rancher_url.*=.*|rancher_url   = \"${RANCHER_URL}\"|" \
    -e "s|rancher_token.*=.*|rancher_token = \"${API_TOKEN}\"|" \
    -e "s|harvester_cluster_id.*=.*|harvester_cluster_id            = \"${HARVESTER_ID}\"|" \
    -e "s|harvester_cloud_credential_name.*=.*|harvester_cloud_credential_name = \"${cloud_cred_name}\"|" \
    -e "s|^cluster_name.*=.*|cluster_name       = \"${CLUSTER_NAME}\"|" \
    -e "s|^vm_namespace.*=.*|vm_namespace                = \"${VM_NAMESPACE}\"|" \
    "${output}"
  chmod 600 "${output}"
  log_ok "Created terraform.tfvars"
}

# -----------------------------------------------------------------------------
# .env generation (for rancher-api-deploy.sh / nuke-cluster.sh)
# -----------------------------------------------------------------------------
generate_env() {
  local source="${SCRIPT_DIR}/deploy-api/.env.example"
  local output="${SCRIPT_DIR}/deploy-api/.env"
  confirm_overwrite "${output}" || return 0

  log_info "Generating .env from example..."
  local cloud_cred_name="${CLUSTER_NAME}-harvester"
  cp "${source}" "${output}"

  # Replace known values using sed (delimiter = | to avoid URL conflicts)
  sed -i \
    -e "s|^RANCHER_URL=.*|RANCHER_URL=\"${RANCHER_URL}\"|" \
    -e "s|^RANCHER_TOKEN=.*|RANCHER_TOKEN=\"${API_TOKEN}\"|" \
    -e "s|^HARVESTER_CLUSTER_ID=.*|HARVESTER_CLUSTER_ID=\"${HARVESTER_ID}\"|" \
    -e "s|^CLOUD_CRED_NAME=.*|CLOUD_CRED_NAME=\"${cloud_cred_name}\"|" \
    -e "s|^CLUSTER_NAME=.*|CLUSTER_NAME=\"${CLUSTER_NAME}\"|" \
    -e "s|^VM_NAMESPACE=.*|VM_NAMESPACE=\"${VM_NAMESPACE}\"|" \
    "${output}"
  chmod 600 "${output}"
  log_ok "Created .env"
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
print_summary() {
  echo ""
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo -e "${BOLD}${BLUE}  Preparation Complete${NC}"
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo ""

  echo -e "${BOLD}Files created:${NC}"
  for f in kubeconfig-harvester.yaml kubeconfig-harvester-cloud-cred.yaml \
           harvester-cloud-provider-kubeconfig deploy-api/.env deploy-terraform/terraform.tfvars; do
    if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
      echo -e "  ${GREEN}+${NC} ${f}"
    else
      echo -e "  ${YELLOW}-${NC} ${f} (skipped)"
    fi
  done

  echo ""
  echo -e "${BOLD}${YELLOW}Manual edits required:${NC}"
  echo ""
  echo -e "  ${BOLD}In deploy-api/.env (for rancher-api-deploy.sh):${NC}"
  echo "    - GOLDEN_IMAGE_NAME            (must exist on Harvester)"
  echo "    - HARVESTER_NETWORK_NAME/NS    (VM network)"
  echo "    - BOOTSTRAP_REGISTRY           (bootstrap registry FQDN)"
  echo "    - HARBOR_FQDN                  (Harbor FQDN for proxy-cache)"
  echo "    - PRIVATE_CA_PEM_FILE          (path to PEM certificate file)"
  echo "    - SSH_KEY                      (SSH public key)"
  echo "    - TRAEFIK_LB_IP / CILIUM_LB_* (load balancer IP range)"
  echo "    - Node pool sizing             (CPU, memory, disk, counts)"
  echo ""
  echo -e "  ${BOLD}In deploy-terraform/terraform.tfvars (for Terraform, if used):${NC}"
  echo "    - Same values as above in HCL format"

  echo ""
  echo -e "${BOLD}Next steps:${NC}"
  echo "  Option A (recommended): ./deploy-api/rancher-api-deploy.sh --dry-run"
  echo "  Option B (Terraform):   cd deploy-terraform && terraform init && terraform plan"
  echo ""
}

# -----------------------------------------------------------------------------
# Refresh summary (credential refresh mode only)
# -----------------------------------------------------------------------------
print_refresh_summary() {
  echo ""
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo -e "${BOLD}${BLUE}  Credential Refresh Complete${NC}"
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo ""

  echo -e "${BOLD}Files regenerated:${NC}"
  for f in kubeconfig-harvester.yaml kubeconfig-harvester-cloud-cred.yaml \
           harvester-cloud-provider-kubeconfig; do
    if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
      echo -e "  ${GREEN}+${NC} ${f}"
    else
      echo -e "  ${YELLOW}-${NC} ${f} (skipped)"
    fi
  done

  echo ""
  echo -e "${BOLD}Updated credentials in:${NC}"
  if [[ -f "${SCRIPT_DIR}/deploy-terraform/terraform.tfvars" ]]; then
    echo -e "  ${GREEN}+${NC} deploy-terraform/terraform.tfvars  (rancher_token, harvester_cloud_credential_name)"
  fi
  if [[ -f "${SCRIPT_DIR}/deploy-api/.env" ]]; then
    echo -e "  ${GREEN}+${NC} deploy-api/.env              (RANCHER_TOKEN, CLOUD_CRED_NAME)"
  fi
  echo ""
  echo -e "${BOLD}Next steps:${NC}"
  echo "  Option A (recommended): ./deploy-api/rancher-api-deploy.sh --dry-run"
  echo "  Option B (Terraform):   cd deploy-terraform && terraform init && terraform plan"
  echo ""
}

# -----------------------------------------------------------------------------
# Credential refresh mode
# Reads existing settings from terraform.tfvars, prompts only for credentials,
# regenerates kubeconfigs and updates credential fields in-place.
# -----------------------------------------------------------------------------
refresh_credentials() {
  check_prerequisites false

  # Read existing settings from .env (preferred) or terraform.tfvars (fallback)
  if [[ -f "${SCRIPT_DIR}/deploy-api/.env" ]]; then
    log_info "Reading existing settings from deploy-api/.env..."
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/deploy-api/.env"
  elif [[ -f "${SCRIPT_DIR}/deploy-terraform/terraform.tfvars" ]]; then
    log_info "Reading existing settings from deploy-terraform/terraform.tfvars (no .env found)..."
    RANCHER_URL=$(read_tfvar rancher_url)
    CLUSTER_NAME=$(read_tfvar cluster_name)
    VM_NAMESPACE=$(read_tfvar vm_namespace)
  else
    die "Neither deploy-api/.env nor deploy-terraform/terraform.tfvars found — run full setup first"
  fi

  [[ -z "${RANCHER_URL:-}" ]]   && die "RANCHER_URL not found in config"
  [[ -z "${CLUSTER_NAME:-}" ]]  && die "CLUSTER_NAME not found in config"
  [[ -z "${VM_NAMESPACE:-}" ]]  && die "VM_NAMESPACE not found in config"

  log_ok "Rancher URL:   ${RANCHER_URL}"
  log_ok "Cluster name:  ${CLUSTER_NAME}"
  log_ok "VM namespace:  ${VM_NAMESPACE}"

  # Prompt only for credentials
  prompt_value "Rancher username" "admin" RANCHER_USER
  prompt_secret "Rancher password" RANCHER_PASS

  # Authenticate and create new API token
  rancher_login
  create_api_token

  # Discover/validate Harvester cluster ID
  discover_harvester_id

  # Regenerate all 3 kubeconfigs (overwrite without prompting — that's the point)
  log_info "Regenerating kubeconfigs..."

  # Harvester management kubeconfig
  local response config
  response=$(rancher_api POST "/v3/clusters/${HARVESTER_ID}?action=generateKubeconfig")
  config=$(echo "${response}" | jq -r '.config // empty')
  if [[ -z "${config}" ]]; then
    die "Failed to generate Harvester kubeconfig"
  fi
  echo "${config}" > "${SCRIPT_DIR}/kubeconfig-harvester.yaml"
  chmod 600 "${SCRIPT_DIR}/kubeconfig-harvester.yaml"
  log_ok "Regenerated kubeconfig-harvester.yaml"

  # Cloud credential kubeconfig
  local server ca_data token_value
  server=$(kubectl --kubeconfig="${SCRIPT_DIR}/kubeconfig-harvester.yaml" config view --raw -o jsonpath='{.clusters[0].cluster.server}')
  ca_data=$(kubectl --kubeconfig="${SCRIPT_DIR}/kubeconfig-harvester.yaml" config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  token_value=$(kubectl --kubeconfig="${SCRIPT_DIR}/kubeconfig-harvester.yaml" config view --raw -o jsonpath='{.users[0].user.token}')

  cat > "${SCRIPT_DIR}/kubeconfig-harvester-cloud-cred.yaml" <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
- name: harvester
  cluster:
    server: ${server}
    certificate-authority-data: ${ca_data}
contexts:
- name: harvester
  context:
    cluster: harvester
    user: ${CLUSTER_NAME}-cloud-cred
current-context: harvester
users:
- name: ${CLUSTER_NAME}-cloud-cred
  user:
    token: ${token_value}
KUBECONFIG
  chmod 600 "${SCRIPT_DIR}/kubeconfig-harvester-cloud-cred.yaml"
  log_ok "Regenerated kubeconfig-harvester-cloud-cred.yaml"

  # Cloud provider kubeconfig
  response=$(rancher_api POST "/k8s/clusters/${HARVESTER_ID}/v1/harvester/kubeconfig" \
    "{\"clusterRoleName\":\"harvesterhci.io:cloudprovider\",\"namespace\":\"${VM_NAMESPACE}\",\"serviceAccountName\":\"${CLUSTER_NAME}\"}")
  config=$(echo "${response}" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()))")
  if [[ -z "${config}" || "${config}" == "None" ]]; then
    die "Failed to generate cloud provider kubeconfig"
  fi
  echo "${config}" > "${SCRIPT_DIR}/harvester-cloud-provider-kubeconfig"
  chmod 600 "${SCRIPT_DIR}/harvester-cloud-provider-kubeconfig"
  log_ok "Regenerated harvester-cloud-provider-kubeconfig"

  # Update credential fields in terraform.tfvars (in-place)
  local cloud_cred_name="${CLUSTER_NAME}-harvester"
  if [[ -f "${SCRIPT_DIR}/deploy-terraform/terraform.tfvars" ]]; then
    log_info "Updating credentials in deploy-terraform/terraform.tfvars..."
    sed -i \
      -e "s|rancher_token.*=.*|rancher_token = \"${API_TOKEN}\"|" \
      -e "s|harvester_cloud_credential_name.*=.*|harvester_cloud_credential_name = \"${cloud_cred_name}\"|" \
      "${SCRIPT_DIR}/deploy-terraform/terraform.tfvars"
    log_ok "Updated rancher_token and harvester_cloud_credential_name in deploy-terraform/terraform.tfvars"
  fi

  # Update credential fields in .env (in-place)
  if [[ -f "${SCRIPT_DIR}/deploy-api/.env" ]]; then
    log_info "Updating credentials in deploy-api/.env..."
    sed -i \
      -e "s|^RANCHER_TOKEN=.*|RANCHER_TOKEN=\"${API_TOKEN}\"|" \
      -e "s|^CLOUD_CRED_NAME=.*|CLOUD_CRED_NAME=\"${cloud_cred_name}\"|" \
      "${SCRIPT_DIR}/deploy-api/.env"
    log_ok "Updated RANCHER_TOKEN and CLOUD_CRED_NAME in deploy-api/.env"
  fi

  # Ensure Terraform state namespace
  ensure_terraform_state_ns

  # Done
  print_refresh_summary
}

# -----------------------------------------------------------------------------
# Full setup (default mode — original behavior)
# -----------------------------------------------------------------------------
full_setup() {
  check_prerequisites

  # Warn if old-location config files exist
  if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    log_warn "Found .env at old location (project root)."
    log_warn "Config now lives in deploy-api/.env — please re-run prepare.sh."
  fi
  if [[ -f "${SCRIPT_DIR}/terraform.tfvars" ]]; then
    log_warn "Found terraform.tfvars at old location (project root)."
    log_warn "Config now lives in deploy-terraform/terraform.tfvars — please re-run prepare.sh."
  fi

  # Gather Rancher connection details
  prompt_value "Rancher URL (https://...)" "" RANCHER_URL
  [[ "${RANCHER_URL}" =~ ^https:// ]] || die "Rancher URL must start with https://"
  # Strip trailing slash
  RANCHER_URL="${RANCHER_URL%/}"

  prompt_value "Rancher username" "admin" RANCHER_USER
  prompt_secret "Rancher password" RANCHER_PASS

  # Authenticate and create API token
  rancher_login
  prompt_value "Cluster name" "rke2-prod" CLUSTER_NAME
  create_api_token

  # Discover Harvester cluster
  discover_harvester_id
  prompt_value "VM namespace on Harvester" "rke2-prod" VM_NAMESPACE

  # Generate kubeconfigs
  generate_harvester_kubeconfig
  generate_cloud_cred_kubeconfig
  generate_cloud_provider_kubeconfig

  # Ensure Terraform state namespace
  ensure_terraform_state_ns

  # Generate config files
  generate_env
  generate_tfvars

  # Done
  print_summary
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  local refresh_mode=false
  case "${1:-}" in
    -r|--refresh-credentials) refresh_mode=true ;;
    -h|--help)                usage ;;
    "")                       ;; # no args — full setup
    *)                        die "Unknown option: $1 (see --help)" ;;
  esac

  echo ""
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  if [[ "${refresh_mode}" == true ]]; then
    echo -e "${BOLD}${BLUE}  RKE2 Cluster — Credential Refresh${NC}"
  else
    echo -e "${BOLD}${BLUE}  RKE2 Cluster — Credential Preparation${NC}"
  fi
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo ""

  if [[ "${refresh_mode}" == true ]]; then
    if [[ -f "${SCRIPT_DIR}/deploy-api/.env" || -f "${SCRIPT_DIR}/deploy-terraform/terraform.tfvars" ]]; then
      refresh_credentials
    else
      log_warn "No deploy-api/.env or deploy-terraform/terraform.tfvars found — running full setup instead"
      full_setup
    fi
  else
    full_setup
  fi
}

main "$@"
