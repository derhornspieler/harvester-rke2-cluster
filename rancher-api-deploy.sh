#!/usr/bin/env bash
# =============================================================================
# rancher-api-deploy.sh — Provision RKE2 cluster via Rancher API (no Terraform)
# =============================================================================
# Alternative to Terraform for creating an RKE2 cluster on Harvester via Rancher.
# Uses curl to call Rancher's Steve & v3 APIs directly.
#
# Prerequisites:
#   - .env file must exist in the script directory with valid values
#   - PRIVATE_CA_PEM_FILE must point to a file containing the private CA PEM
#   - CLOUD_PROVIDER_KUBECONFIG_FILE must point to the cloud provider kubeconfig
#   - CLOUD_CRED_KUBECONFIG_FILE must point to the cloud credential kubeconfig
#
# Usage:
#   ./rancher-api-deploy.sh            # Create cluster
#   ./rancher-api-deploy.sh --dry-run  # Show what would be created (JSON payloads)
#   ./rancher-api-deploy.sh --update   # Update existing cluster (k8s version, etc.)
#   ./rancher-api-deploy.sh --delete   # Delete cluster and all associated resources
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Colors & Logging
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
die()       { log_error "$@"; exit 1; }

# -----------------------------------------------------------------------------
# Load configuration from .env
# -----------------------------------------------------------------------------
load_config() {
  local env_file="${SCRIPT_DIR}/.env"
  [[ -f "${env_file}" ]] || die ".env file not found: ${env_file}"

  log_info "Loading configuration from .env..."

  # shellcheck source=/dev/null
  source "${env_file}"

  # Read file-based values
  [[ -z "${PRIVATE_CA_PEM_FILE:-}" ]]            && die "PRIVATE_CA_PEM_FILE not set in .env"
  [[ -f "${PRIVATE_CA_PEM_FILE}" ]]              || die "PRIVATE_CA_PEM_FILE not found: ${PRIVATE_CA_PEM_FILE}"
  PRIVATE_CA_PEM=$(cat "${PRIVATE_CA_PEM_FILE}")

  [[ -z "${CLOUD_PROVIDER_KUBECONFIG_FILE:-}" ]] && die "CLOUD_PROVIDER_KUBECONFIG_FILE not set in .env"
  [[ -f "${CLOUD_PROVIDER_KUBECONFIG_FILE}" ]]   || die "CLOUD_PROVIDER_KUBECONFIG_FILE not found: ${CLOUD_PROVIDER_KUBECONFIG_FILE}"
  CLOUD_PROVIDER_KUBECONFIG=$(cat "${CLOUD_PROVIDER_KUBECONFIG_FILE}")

  [[ -z "${CLOUD_CRED_KUBECONFIG_FILE:-}" ]]     && die "CLOUD_CRED_KUBECONFIG_FILE not set in .env"
  [[ -f "${CLOUD_CRED_KUBECONFIG_FILE}" ]]       || die "CLOUD_CRED_KUBECONFIG_FILE not found: ${CLOUD_CRED_KUBECONFIG_FILE}"
  CLOUD_CRED_KUBECONFIG=$(cat "${CLOUD_CRED_KUBECONFIG_FILE}")

  # Validate required fields
  [[ -z "${RANCHER_URL:-}" ]]    && die "RANCHER_URL not set in .env"
  [[ -z "${RANCHER_TOKEN:-}" ]]  && die "RANCHER_TOKEN not set in .env"
  [[ -z "${CLUSTER_NAME:-}" ]]   && die "CLUSTER_NAME not set in .env"
  [[ -z "${K8S_VERSION:-}" ]]    && die "K8S_VERSION not set in .env"
  [[ -z "${PRIVATE_CA_PEM}" ]]   && die "PRIVATE_CA_PEM_FILE is empty: ${PRIVATE_CA_PEM_FILE}"

  # Image full name for disk_info
  IMAGE_FULL_NAME="${VM_NAMESPACE}/${GOLDEN_IMAGE_NAME}"

  # Base64-encode CA PEM for registries config
  CA_BUNDLE_B64=$(echo "${PRIVATE_CA_PEM}" | base64 -w0)

  log_ok "Configuration loaded for cluster: ${CLUSTER_NAME}"
}

# -----------------------------------------------------------------------------
# Rancher API helper
# -----------------------------------------------------------------------------
rancher_api() {
  local method="$1" path="$2" data="${3:-}"
  local url="${RANCHER_URL}${path}"
  local args=(-sk -X "${method}" -H "Authorization: Bearer ${RANCHER_TOKEN}" -H "Content-Type: application/json")
  if [[ -n "${data}" ]]; then
    args+=(-d "${data}")
  fi
  curl "${args[@]}" "${url}" 2>/dev/null
}

rancher_api_patch() {
  local path="$1" data="$2"
  local url="${RANCHER_URL}${path}"
  curl -sk -X PATCH \
    -H "Authorization: Bearer ${RANCHER_TOKEN}" \
    -H "Content-Type: application/merge-patch+json" \
    -d "${data}" "${url}" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Step 1: Create Cloud Credential
# -----------------------------------------------------------------------------
create_cloud_credential() {
  log_info "Creating cloud credential: ${CLOUD_CRED_NAME}..."

  # Check if it already exists
  local existing
  existing=$(rancher_api GET "/v3/cloudCredentials" | jq -r \
    ".data[] | select(.name == \"${CLOUD_CRED_NAME}\") | .id" 2>/dev/null || echo "")

  if [[ -n "${existing}" ]]; then
    log_ok "Cloud credential already exists: ${existing}"
    CLOUD_CRED_ID="${existing}"
    return 0
  fi

  local kubeconfig_escaped
  kubeconfig_escaped=$(echo "${CLOUD_CRED_KUBECONFIG}" | jq -Rs .)

  local payload
  payload=$(cat <<CRED_EOF
{
  "type": "cloudCredential",
  "name": "${CLOUD_CRED_NAME}",
  "harvestercredentialConfig": {
    "clusterId": "${HARVESTER_CLUSTER_ID}",
    "clusterType": "imported",
    "kubeconfigContent": ${kubeconfig_escaped}
  }
}
CRED_EOF
  )

  if [[ "${DRY_RUN}" == true ]]; then
    echo "${payload}" | jq .
    CLOUD_CRED_ID="cattle-global-data:cc-dry-run"
    return 0
  fi

  local response
  response=$(rancher_api POST "/v3/cloudCredentials" "${payload}")
  CLOUD_CRED_ID=$(echo "${response}" | jq -r '.id // empty')

  if [[ -z "${CLOUD_CRED_ID}" ]]; then
    local msg
    msg=$(echo "${response}" | jq -r '.message // .Message // "unknown error"')
    die "Failed to create cloud credential: ${msg}"
  fi
  log_ok "Cloud credential created: ${CLOUD_CRED_ID}"
}

# -----------------------------------------------------------------------------
# Step 2: Create Docker Hub auth secret
# -----------------------------------------------------------------------------
create_dockerhub_secret() {
  if [[ -z "${DOCKERHUB_USERNAME}" ]]; then
    log_info "No Docker Hub credentials configured, skipping"
    DOCKERHUB_SECRET_NAME=""
    return 0
  fi

  DOCKERHUB_SECRET_NAME="${CLUSTER_NAME}-dockerhub-auth"
  log_info "Creating Docker Hub auth secret: ${DOCKERHUB_SECRET_NAME}..."

  # Check if it already exists
  local existing
  existing=$(rancher_api GET "/v1/secrets/fleet-default/${DOCKERHUB_SECRET_NAME}" | jq -r '.id // empty' 2>/dev/null || echo "")

  if [[ -n "${existing}" && "${existing}" != "null" ]]; then
    log_ok "Docker Hub secret already exists"
    return 0
  fi

  local user_b64 pass_b64
  user_b64=$(echo -n "${DOCKERHUB_USERNAME}" | base64 -w0)
  pass_b64=$(echo -n "${DOCKERHUB_TOKEN}" | base64 -w0)

  local payload
  payload=$(cat <<SECRET_EOF
{
  "type": "secret",
  "metadata": {
    "name": "${DOCKERHUB_SECRET_NAME}",
    "namespace": "fleet-default"
  },
  "type": "kubernetes.io/basic-auth",
  "data": {
    "username": "${user_b64}",
    "password": "${pass_b64}"
  }
}
SECRET_EOF
  )

  if [[ "${DRY_RUN}" == true ]]; then
    echo "${payload}" | jq .
    return 0
  fi

  local response
  response=$(rancher_api POST "/v1/secrets" "${payload}")
  local created
  created=$(echo "${response}" | jq -r '.metadata.name // empty' 2>/dev/null || echo "")

  if [[ -z "${created}" ]]; then
    log_warn "Docker Hub secret creation may have failed -- continuing anyway"
  else
    log_ok "Docker Hub secret created"
  fi
}

# -----------------------------------------------------------------------------
# Step 3: Create HarvesterConfig machine configs via Steve API
# -----------------------------------------------------------------------------
build_cloud_init_cp() {
  cat <<CLOUDINIT_CP
#cloud-config

ssh_authorized_keys:
  - ${SSH_KEY}

write_files:
- path: /var/lib/rancher/rke2/server/manifests/cilium-lb-ippool.yaml
  permissions: '0644'
  content: |
    apiVersion: "cilium.io/v2alpha1"
    kind: CiliumLoadBalancerIPPool
    metadata:
      name: ingress-pool
    spec:
      blocks:
        - start: "${CILIUM_LB_POOL_START}"
          stop: "${CILIUM_LB_POOL_STOP}"

- path: /var/lib/rancher/rke2/server/manifests/cilium-l2-policy.yaml
  permissions: '0644'
  content: |
    apiVersion: "cilium.io/v2alpha1"
    kind: CiliumL2AnnouncementPolicy
    metadata:
      name: l2-policy
    spec:
      serviceSelector:
        matchLabels: {}
      nodeSelector:
        matchExpressions:
          - key: node-role.kubernetes.io/control-plane
            operator: DoesNotExist
      interfaces:
        - ^eth1$
      externalIPs: true
      loadBalancerIPs: true

- path: /var/lib/rancher/rke2/server/manifests/vault-root-ca.yaml
  permissions: '0644'
  content: |
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: vault-root-ca
      namespace: kube-system
    data:
      ca.crt: |
$(echo "${PRIVATE_CA_PEM}" | sed 's/^/        /')

- path: /etc/pki/ca-trust/source/anchors/private-ca.pem
  permissions: '0644'
  content: |
$(echo "${PRIVATE_CA_PEM}" | sed 's/^/    /')

- path: /etc/sysconfig/iptables
  permissions: '0600'
  content: |
    *filter
    :INPUT DROP [0:0]
    :FORWARD ACCEPT [0:0]
    :OUTPUT DROP [0:0]
    # --- INPUT rules ---
    -A INPUT -i lo -j ACCEPT
    -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    -A INPUT -p icmp -j ACCEPT
    -A INPUT -p tcp --dport 22 -j ACCEPT
    -A INPUT -p tcp --dport 6443 -j ACCEPT
    -A INPUT -p tcp --dport 9345 -j ACCEPT
    -A INPUT -p tcp --dport 2379:2381 -j ACCEPT
    -A INPUT -p tcp --dport 10250 -j ACCEPT
    -A INPUT -p tcp --dport 10257 -j ACCEPT
    -A INPUT -p tcp --dport 10259 -j ACCEPT
    -A INPUT -p tcp --dport 30000:32767 -j ACCEPT
    -A INPUT -p udp --dport 30000:32767 -j ACCEPT
    -A INPUT -p tcp --dport 4240 -j ACCEPT
    -A INPUT -p udp --dport 8472 -j ACCEPT
    -A INPUT -p tcp --dport 4244 -j ACCEPT
    -A INPUT -p tcp --dport 4245 -j ACCEPT
    -A INPUT -p tcp --dport 9962 -j ACCEPT
    -A INPUT -p tcp --dport 9100 -j ACCEPT
    # --- OUTPUT rules (airgap enforcement) ---
    -A OUTPUT -o lo -j ACCEPT
    -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    -A OUTPUT -d 10.0.0.0/8 -j ACCEPT
    -A OUTPUT -d 172.16.0.0/12 -j ACCEPT
    -A OUTPUT -d 192.168.0.0/16 -j ACCEPT
    -A OUTPUT -p udp --dport 53 -j ACCEPT
    -A OUTPUT -p tcp --dport 53 -j ACCEPT
    -A OUTPUT -p udp --dport 123 -j ACCEPT
    -A OUTPUT -p icmp -j ACCEPT
    COMMIT

runcmd:
- mkdir -p /var/lib/rancher/rke2/server/manifests
- update-ca-trust
- systemctl enable --now iptables
CLOUDINIT_CP
}

build_cloud_init_worker() {
  cat <<CLOUDINIT_WORKER
#cloud-config

ssh_authorized_keys:
  - ${SSH_KEY}

write_files:
- path: /etc/sysctl.d/90-arp.conf
  permissions: '0644'
  content: |
    net.ipv4.conf.all.arp_ignore=1
    net.ipv4.conf.all.arp_announce=2

- path: /etc/NetworkManager/dispatcher.d/10-ingress-routing
  permissions: '0755'
  content: |
    #!/bin/bash
    IFACE=\$1
    ACTION=\$2
    if [ "\$IFACE" = "eth1" ] && [ "\$ACTION" = "up" ]; then
      IP=\$(ip -4 addr show eth1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
      SUBNET=\$(ip -4 route show dev eth1 scope link | awk '{print \$1}' | head -1)
      GW=\$(ip -4 route show dev eth1 | grep default | awk '{print \$3}')
      [ -z "\$GW" ] && GW=\$(ip -4 route show default | awk '{print \$3}' | head -1)
      grep -q "^200 ingress" /etc/iproute2/rt_tables || echo "200 ingress" >> /etc/iproute2/rt_tables
      ip rule add from \$IP table ingress priority 100 2>/dev/null || true
      ip route replace default via \$GW dev eth1 table ingress 2>/dev/null || true
      [ -n "\$SUBNET" ] && ip route replace \$SUBNET dev eth1 table ingress 2>/dev/null || true
    fi

- path: /etc/pki/ca-trust/source/anchors/private-ca.pem
  permissions: '0644'
  content: |
$(echo "${PRIVATE_CA_PEM}" | sed 's/^/    /')

- path: /etc/sysconfig/iptables
  permissions: '0600'
  content: |
    *filter
    :INPUT DROP [0:0]
    :FORWARD ACCEPT [0:0]
    :OUTPUT DROP [0:0]
    # --- INPUT rules ---
    -A INPUT -i lo -j ACCEPT
    -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    -A INPUT -p icmp -j ACCEPT
    -A INPUT -p tcp --dport 22 -j ACCEPT
    -A INPUT -p tcp --dport 6443 -j ACCEPT
    -A INPUT -p tcp --dport 9345 -j ACCEPT
    -A INPUT -p tcp --dport 2379:2381 -j ACCEPT
    -A INPUT -p tcp --dport 10250 -j ACCEPT
    -A INPUT -p tcp --dport 10257 -j ACCEPT
    -A INPUT -p tcp --dport 10259 -j ACCEPT
    -A INPUT -p tcp --dport 30000:32767 -j ACCEPT
    -A INPUT -p udp --dport 30000:32767 -j ACCEPT
    -A INPUT -p tcp --dport 4240 -j ACCEPT
    -A INPUT -p udp --dport 8472 -j ACCEPT
    -A INPUT -p tcp --dport 4244 -j ACCEPT
    -A INPUT -p tcp --dport 4245 -j ACCEPT
    -A INPUT -p tcp --dport 9962 -j ACCEPT
    -A INPUT -p tcp --dport 9100 -j ACCEPT
    # --- OUTPUT rules (airgap enforcement) ---
    -A OUTPUT -o lo -j ACCEPT
    -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    -A OUTPUT -d 10.0.0.0/8 -j ACCEPT
    -A OUTPUT -d 172.16.0.0/12 -j ACCEPT
    -A OUTPUT -d 192.168.0.0/16 -j ACCEPT
    -A OUTPUT -p udp --dport 53 -j ACCEPT
    -A OUTPUT -p tcp --dport 53 -j ACCEPT
    -A OUTPUT -p udp --dport 123 -j ACCEPT
    -A OUTPUT -p icmp -j ACCEPT
    COMMIT

runcmd:
- sysctl --system
- restorecon -R /etc/NetworkManager/dispatcher.d/ || true
- update-ca-trust
- systemctl enable --now iptables
CLOUDINIT_WORKER
}

create_harvester_config() {
  local pool_name="$1" cpu="$2" memory="$3" disk_size="$4" network_info="$5" user_data="$6"

  local config_name="${CLUSTER_NAME}-${pool_name}"
  log_info "Creating HarvesterConfig: ${config_name}..."

  # Check if it already exists
  local existing
  existing=$(rancher_api GET "/v1/rke-machine-config.cattle.io.harvesterconfigs/fleet-default/${config_name}" \
    | jq -r '.id // empty' 2>/dev/null || echo "")

  if [[ -n "${existing}" && "${existing}" != "null" ]]; then
    log_ok "HarvesterConfig ${config_name} already exists"
    return 0
  fi

  local disk_info
  disk_info=$(jq -n --arg img "${IMAGE_FULL_NAME}" --argjson sz "${disk_size}" \
    '{disks: [{imageName: $img, size: $sz, bootOrder: 1}]}' | jq -c .)

  local user_data_escaped
  user_data_escaped=$(echo "${user_data}" | jq -Rs .)

  local payload
  payload=$(jq -n \
    --arg name "${config_name}" \
    --arg ns "fleet-default" \
    --arg vmns "${VM_NAMESPACE}" \
    --arg cpu "${cpu}" \
    --arg mem "${memory}" \
    --arg sshuser "${SSH_USER}" \
    --arg diskinfo "${disk_info}" \
    --arg netinfo "${network_info}" \
    --argjson userdata "${user_data_escaped}" \
    '{
      apiVersion: "rke-machine-config.cattle.io/v1",
      kind: "HarvesterConfig",
      metadata: {
        name: $name,
        namespace: $ns
      },
      cpuCount: $cpu,
      memorySize: $mem,
      reservedMemorySize: "-1",
      diskInfo: $diskinfo,
      networkInfo: $netinfo,
      sshUser: $sshuser,
      userData: $userdata,
      vmNamespace: $vmns,
      enableEfi: true
    }')

  if [[ "${DRY_RUN}" == true ]]; then
    echo "${payload}" | jq .
    return 0
  fi

  local response
  response=$(rancher_api POST "/v1/rke-machine-config.cattle.io.harvesterconfigs" "${payload}")
  local created
  created=$(echo "${response}" | jq -r '.metadata.name // .id // empty' 2>/dev/null || echo "")

  if [[ -z "${created}" ]]; then
    local msg
    msg=$(echo "${response}" | jq -r '.message // .Message // "unknown error"')
    die "Failed to create HarvesterConfig ${config_name}: ${msg}"
  fi
  log_ok "HarvesterConfig created: ${config_name}"
}

create_all_machine_configs() {
  # Network info JSON
  local net_cp net_worker
  net_cp=$(jq -n --arg net "${HARVESTER_NETWORK_NS}/${HARVESTER_NETWORK_NAME}" \
    '{interfaces: [{networkName: $net}]}' | jq -c .)

  net_worker=$(jq -n \
    --arg net1 "${HARVESTER_NETWORK_NS}/${HARVESTER_NETWORK_NAME}" \
    --arg net2 "${SERVICES_NETWORK_NS}/${SERVICES_NETWORK_NAME}" \
    '{interfaces: [{networkName: $net1}, {networkName: $net2}]}' | jq -c .)

  # Cloud-init
  local ud_cp ud_worker
  ud_cp=$(build_cloud_init_cp)
  ud_worker=$(build_cloud_init_worker)

  create_harvester_config "cp"       "${CP_CPU}"   "${CP_MEM}"   "${CP_DISK}"   "${net_cp}"     "${ud_cp}"
  create_harvester_config "general"  "${GEN_CPU}"  "${GEN_MEM}"  "${GEN_DISK}"  "${net_worker}" "${ud_worker}"
  create_harvester_config "compute"  "${COMP_CPU}" "${COMP_MEM}" "${COMP_DISK}" "${net_worker}" "${ud_worker}"
  create_harvester_config "database" "${DB_CPU}"   "${DB_MEM}"   "${DB_DISK}"   "${net_worker}" "${ud_worker}"
}

# -----------------------------------------------------------------------------
# Step 4: Create provisioning cluster
# -----------------------------------------------------------------------------
build_chart_values() {
  # Build the chart_values YAML as a string, then pass it through
  cat <<CHART_VALUES_EOF
harvester-cloud-provider:
  clusterName: ${CLUSTER_NAME}
  cloudConfigPath: /var/lib/rancher/rke2/etc/config-files/cloud-provider-config
rke2-cilium:
  kubeProxyReplacement: true
  k8sServiceHost: "127.0.0.1"
  k8sServicePort: 6443
  l2announcements:
    enabled: true
  externalIPs:
    enabled: true
  gatewayAPI:
    enabled: true
  operator:
    replicas: 1
  hubble:
    enabled: true
    relay:
      enabled: true
    ui:
      enabled: true
  prometheus:
    enabled: true
  k8sClientRateLimit:
    qps: 25
    burst: 50
rke2-traefik:
  service:
    type: LoadBalancer
    spec:
      loadBalancerIP: "${TRAEFIK_LB_IP}"
  providers:
    kubernetesGateway:
      enabled: true
      experimentalChannel: true
  logs:
    access:
      enabled: true
  ports:
    web:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
    ssh:
      port: 2222
      expose:
        default: true
      exposedPort: 22
      protocol: TCP
  volumes:
  - name: vault-root-ca
    mountPath: /vault-ca
    type: configMap
  - name: combined-ca
    mountPath: /combined-ca
    type: emptyDir
  deployment:
    initContainers:
    - name: combine-ca
      image: docker.io/library/alpine:3.21
      command:
      - sh
      - -c
      - "cp /etc/ssl/certs/ca-certificates.crt /combined-ca/ca-certificates.crt 2>/dev/null || true; if [ -s /vault-ca/ca.crt ]; then cat /vault-ca/ca.crt >> /combined-ca/ca-certificates.crt; fi"
      volumeMounts:
      - name: vault-root-ca
        mountPath: /vault-ca
        readOnly: true
      - name: combined-ca
        mountPath: /combined-ca
  env:
  - name: SSL_CERT_FILE
    value: /combined-ca/ca-certificates.crt
  additionalArguments:
  - "--api.dashboard=false"
  - "--entryPoints.web.transport.respondingTimeouts.readTimeout=1800s"
  - "--entryPoints.web.transport.respondingTimeouts.writeTimeout=1800s"
  - "--entryPoints.websecure.transport.respondingTimeouts.readTimeout=1800s"
  - "--entryPoints.websecure.transport.respondingTimeouts.writeTimeout=1800s"
CHART_VALUES_EOF
}

build_machine_global_config() {
  cat <<MGC_EOF
cni: ${CNI}
disable-kube-proxy: true
disable:
- rke2-ingress-nginx
ingress-controller: traefik
etcd-expose-metrics: true
kube-scheduler-arg:
- bind-address=0.0.0.0
kube-controller-manager-arg:
- bind-address=0.0.0.0
MGC_EOF
}

build_registries_json() {
  # CRD uses map[hostname] -> config, NOT arrays.
  #   mirrors:  map[hostname] -> { endpoint: [...], rewrite: {...} }
  #   configs:  map[hostname] -> { authConfigSecretName, caBundle, ... }
  # Field names are singular: "endpoint" not "endpoints", "rewrite" not "rewrites"

  local registries=("docker.io" "quay.io" "ghcr.io" "gcr.io" "registry.k8s.io" "docker.elastic.co" "registry.gitlab.com" "docker-registry3.mariadb.com")

  # Build mirrors map
  local mirrors_json="{}"
  for upstream in "${registries[@]}"; do
    mirrors_json=$(echo "${mirrors_json}" | jq \
      --arg hostname "${upstream}" \
      --arg endpoint "https://${BOOTSTRAP_REGISTRY}" \
      --arg rewrite_from "^(.*)\$" \
      --arg rewrite_to "${upstream}/\$1" \
      '. + {($hostname): {endpoint: [$endpoint], rewrite: {($rewrite_from): $rewrite_to}}}')
  done

  # Build configs map
  local configs_json="{}"

  # Docker Hub auth config
  if [[ -n "${DOCKERHUB_SECRET_NAME}" ]]; then
    configs_json=$(echo "${configs_json}" | jq \
      --arg hostname "docker.io" \
      --arg secret "${DOCKERHUB_SECRET_NAME}" \
      '. + {($hostname): {authConfigSecretName: $secret}}')
  fi

  # Harbor CA config
  configs_json=$(echo "${configs_json}" | jq \
    --arg hostname "${HARBOR_FQDN}" \
    --arg ca "${CA_BUNDLE_B64}" \
    '. + {($hostname): {caBundle: $ca}}')

  # Bootstrap registry CA config (skip if same as Harbor)
  if [[ "${BOOTSTRAP_REGISTRY}" != "${HARBOR_FQDN}" ]]; then
    configs_json=$(echo "${configs_json}" | jq \
      --arg hostname "${BOOTSTRAP_REGISTRY}" \
      --arg ca "${CA_BUNDLE_B64}" \
      '. + {($hostname): {caBundle: $ca}}')
  fi

  jq -n --argjson mirrors "${mirrors_json}" --argjson configs "${configs_json}" \
    '{mirrors: $mirrors, configs: $configs}'
}

build_cluster_spec() {
  # Build YAML strings and convert to JSON for embedding
  local chart_values_yaml machine_global_config_yaml
  chart_values_yaml=$(build_chart_values)
  machine_global_config_yaml=$(build_machine_global_config)

  local chart_values_json mgc_json
  chart_values_json=$(echo "${chart_values_yaml}" | python3 -c "import sys,yaml,json; print(json.dumps(yaml.safe_load(sys.stdin.read())))")
  mgc_json=$(echo "${machine_global_config_yaml}" | python3 -c "import sys,yaml,json; print(json.dumps(yaml.safe_load(sys.stdin.read())))")

  # Registries
  local registries_json
  registries_json=$(build_registries_json)

  # Build the spec portion of the cluster payload
  # machineSelectorConfig cloud-provider-config must be the raw kubeconfig string
  jq -n \
    --arg k8sver "${K8S_VERSION}" \
    --arg credid "${CLOUD_CRED_ID}" \
    --arg cpname "${CLUSTER_NAME}-cp" \
    --arg genname "${CLUSTER_NAME}-general" \
    --arg compname "${CLUSTER_NAME}-compute" \
    --arg dbname "${CLUSTER_NAME}-database" \
    --argjson cpcount "${CP_COUNT}" \
    --argjson genmin "${GEN_MIN}" \
    --argjson genmax "${GEN_MAX}" \
    --argjson compmin "${COMP_MIN}" \
    --argjson compmax "${COMP_MAX}" \
    --argjson dbmin "${DB_MIN}" \
    --argjson dbmax "${DB_MAX}" \
    --arg compcpu "${COMP_CPU}" \
    --arg compmem "${COMP_MEM}Gi" \
    --arg compdisk "${COMP_DISK}Gi" \
    --argjson chartvalues "${chart_values_json}" \
    --argjson mgc "${mgc_json}" \
    --argjson registries "${registries_json}" \
    --arg cpkubeconfig "${CLOUD_PROVIDER_KUBECONFIG}" \
    '{
      kubernetesVersion: $k8sver,
      cloudCredentialSecretName: $credid,
      rkeConfig: {
        chartValues: $chartvalues,
        machineGlobalConfig: $mgc,
        machineSelectorConfig: [
          {
            config: {
              "cloud-provider-config": $cpkubeconfig,
              "cloud-provider-name": "harvester"
            }
          },
          {
            config: {"node-label": ["workload-type=general"]},
            machineLabelSelector: {matchLabels: {"rke.cattle.io/rke-machine-pool-name": "general"}}
          },
          {
            config: {"node-label": ["workload-type=compute"]},
            machineLabelSelector: {matchLabels: {"rke.cattle.io/rke-machine-pool-name": "compute"}}
          },
          {
            config: {"node-label": ["workload-type=database"]},
            machineLabelSelector: {matchLabels: {"rke.cattle.io/rke-machine-pool-name": "database"}}
          }
        ],
        registries: $registries,
        upgradeStrategy: {
          controlPlaneConcurrency: "1",
          workerConcurrency: "1"
        },
        etcd: {
          snapshotScheduleCron: "0 */6 * * *",
          snapshotRetention: 5
        },
        machinePools: [
          {
            name: "controlplane",
            controlPlaneRole: true,
            etcdRole: true,
            workerRole: false,
            quantity: $cpcount,
            drainBeforeDelete: true,
            machineConfigRef: {
              kind: "HarvesterConfig",
              name: $cpname
            },
            rollingUpdate: {
              maxUnavailable: 0,
              maxSurge: 1
            }
          },
          {
            name: "general",
            controlPlaneRole: false,
            etcdRole: false,
            workerRole: true,
            quantity: $genmin,
            drainBeforeDelete: true,
            labels: {"workload-type": "general"},
            machineDeploymentAnnotations: {
              "cluster.provisioning.cattle.io/autoscaler-min-size": ($genmin | tostring),
              "cluster.provisioning.cattle.io/autoscaler-max-size": ($genmax | tostring)
            },
            machineConfigRef: {
              kind: "HarvesterConfig",
              name: $genname
            },
            rollingUpdate: {
              maxUnavailable: 0,
              maxSurge: 1
            }
          },
          {
            name: "compute",
            controlPlaneRole: false,
            etcdRole: false,
            workerRole: true,
            quantity: $compmin,
            drainBeforeDelete: true,
            labels: {"workload-type": "compute"},
            machineDeploymentAnnotations: {
              "cluster.provisioning.cattle.io/autoscaler-min-size": ($compmin | tostring),
              "cluster.provisioning.cattle.io/autoscaler-max-size": ($compmax | tostring),
              "cluster.provisioning.cattle.io/autoscaler-resource-cpu": $compcpu,
              "cluster.provisioning.cattle.io/autoscaler-resource-memory": $compmem,
              "cluster.provisioning.cattle.io/autoscaler-resource-storage": $compdisk
            },
            machineConfigRef: {
              kind: "HarvesterConfig",
              name: $compname
            },
            rollingUpdate: {
              maxUnavailable: 0,
              maxSurge: 1
            }
          },
          {
            name: "database",
            controlPlaneRole: false,
            etcdRole: false,
            workerRole: true,
            quantity: $dbmin,
            drainBeforeDelete: true,
            labels: {"workload-type": "database"},
            machineDeploymentAnnotations: {
              "cluster.provisioning.cattle.io/autoscaler-min-size": ($dbmin | tostring),
              "cluster.provisioning.cattle.io/autoscaler-max-size": ($dbmax | tostring)
            },
            machineConfigRef: {
              kind: "HarvesterConfig",
              name: $dbname
            },
            rollingUpdate: {
              maxUnavailable: 0,
              maxSurge: 1
            }
          }
        ]
      }
    }'
}

create_cluster() {
  log_info "Creating provisioning cluster: ${CLUSTER_NAME}..."

  # Check if cluster already exists
  local existing
  existing=$(rancher_api GET "/v1/provisioning.cattle.io.clusters/fleet-default/${CLUSTER_NAME}" \
    | jq -r '.metadata.name // empty' 2>/dev/null || echo "")

  if [[ -n "${existing}" && "${existing}" != "null" ]]; then
    log_warn "Cluster ${CLUSTER_NAME} already exists -- use --update to modify"
    return 0
  fi

  local spec_json
  spec_json=$(build_cluster_spec)

  local payload
  payload=$(jq -n \
    --arg name "${CLUSTER_NAME}" \
    --argjson spec "${spec_json}" \
    '{
      apiVersion: "provisioning.cattle.io/v1",
      kind: "Cluster",
      metadata: {
        name: $name,
        namespace: "fleet-default",
        annotations: {
          "cluster.provisioning.cattle.io/autoscaler-scale-down-unneeded-time": "30m0s",
          "cluster.provisioning.cattle.io/autoscaler-scale-down-delay-after-add": "15m0s",
          "cluster.provisioning.cattle.io/autoscaler-scale-down-delay-after-delete": "30m0s",
          "cluster.provisioning.cattle.io/autoscaler-scale-down-utilization-threshold": "0.5"
        }
      },
      spec: $spec
    }')

  if [[ "${DRY_RUN}" == true ]]; then
    echo "${payload}" | jq .
    return 0
  fi

  local response
  response=$(rancher_api POST "/v1/provisioning.cattle.io.clusters" "${payload}")
  local created
  created=$(echo "${response}" | jq -r '.metadata.name // empty' 2>/dev/null || echo "")

  if [[ -z "${created}" ]]; then
    local msg
    msg=$(echo "${response}" | jq -r '.message // .Message // "unknown error"')
    die "Failed to create cluster: ${msg}"
  fi
  log_ok "Cluster ${CLUSTER_NAME} created -- provisioning will begin shortly"
}

# -----------------------------------------------------------------------------
# Step 4b: Update existing cluster
# -----------------------------------------------------------------------------
update_cluster() {
  log_info "Updating cluster: ${CLUSTER_NAME}..."

  # GET current cluster object
  local current
  current=$(rancher_api GET "/v1/provisioning.cattle.io.clusters/fleet-default/${CLUSTER_NAME}")

  local current_name
  current_name=$(echo "${current}" | jq -r '.metadata.name // empty' 2>/dev/null || echo "")
  if [[ -z "${current_name}" || "${current_name}" == "null" ]]; then
    die "Cluster ${CLUSTER_NAME} does not exist -- use deploy (no flags) to create it"
  fi

  # Show what's changing
  local current_k8s
  current_k8s=$(echo "${current}" | jq -r '.spec.kubernetesVersion // "unknown"')
  log_info "Current kubernetesVersion: ${current_k8s}"
  log_info "Desired kubernetesVersion: ${K8S_VERSION}"

  # Build desired spec
  local spec_json
  spec_json=$(build_cluster_spec)

  # Merge desired spec into current object, preserving metadata (resourceVersion, etc.)
  # Write jq filter to temp file to avoid bash parsing issues with parentheses
  local jq_filter
  jq_filter=$(mktemp)
  cat > "${jq_filter}" <<'JQ_EOF'
    .spec = (.spec * $desired_spec) |
    .spec.rkeConfig.machinePools = [
      .spec.rkeConfig.machinePools[] |
      if .name == "controlplane" then
        .quantity = ($desired_spec.rkeConfig.machinePools[] | select(.name == "controlplane") | .quantity)
      else . end
    ]
JQ_EOF
  local payload
  payload=$(echo "${current}" | jq --argjson desired_spec "${spec_json}" -f "${jq_filter}")
  rm -f "${jq_filter}"

  if [[ "${DRY_RUN}" == true ]]; then
    # Show diff summary
    echo "${payload}" | jq '{
      kubernetesVersion: .spec.kubernetesVersion,
      machinePools: [.spec.rkeConfig.machinePools[] | {name, quantity}]
    }'
    return 0
  fi

  local response
  response=$(rancher_api PUT "/v1/provisioning.cattle.io.clusters/fleet-default/${CLUSTER_NAME}" "${payload}")

  local updated
  updated=$(echo "${response}" | jq -r '.metadata.name // empty' 2>/dev/null || echo "")
  if [[ -z "${updated}" ]]; then
    local msg
    msg=$(echo "${response}" | jq -r '.message // .Message // "unknown error"')
    die "Failed to update cluster: ${msg}"
  fi

  if [[ "${current_k8s}" != "${K8S_VERSION}" ]]; then
    log_ok "Cluster ${CLUSTER_NAME} updated: ${current_k8s} -> ${K8S_VERSION}"
  else
    log_ok "Cluster ${CLUSTER_NAME} updated (no version change)"
  fi
}

# -----------------------------------------------------------------------------
# Step 5: Monitor provisioning
# -----------------------------------------------------------------------------
monitor_provisioning() {
  log_info "Monitoring cluster provisioning (Ctrl+C to stop watching)..."
  echo ""

  local max_wait=5400  # 90 minutes
  local elapsed=0
  local interval=30

  while [[ ${elapsed} -lt ${max_wait} ]]; do
    local response
    response=$(rancher_api GET "/v1/provisioning.cattle.io.clusters/fleet-default/${CLUSTER_NAME}")

    local status ready message
    status=$(echo "${response}" | jq -r '.status.conditions[] | select(.type == "Ready") | .status' 2>/dev/null || echo "Unknown")
    message=$(echo "${response}" | jq -r '.status.conditions[] | select(.type == "Ready") | .message // ""' 2>/dev/null || echo "")

    local machine_count
    machine_count=$(echo "${response}" | jq -r '.status.ready // 0' 2>/dev/null || echo "0")
    local desired
    desired=$((CP_COUNT + GEN_MIN + COMP_MIN + DB_MIN))

    local ts
    ts=$(date +%H:%M:%S)

    if [[ "${status}" == "True" ]]; then
      echo -e "${ts}  ${GREEN}READY${NC}  machines: ${machine_count}/${desired}"
      echo ""
      log_ok "Cluster ${CLUSTER_NAME} is fully provisioned!"
      return 0
    else
      echo -e "${ts}  ${YELLOW}Provisioning${NC}  machines: ${machine_count}/${desired}  ${message:0:80}"
    fi

    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  log_warn "Timed out waiting for cluster to become ready (${max_wait}s)"
  log_info "Check Rancher UI for current status"
}

# -----------------------------------------------------------------------------
# Delete mode
# -----------------------------------------------------------------------------
delete_cluster() {
  log_info "Deleting cluster and associated resources..."

  # Delete provisioning cluster
  log_info "Deleting provisioning cluster: ${CLUSTER_NAME}..."
  local response
  response=$(rancher_api DELETE "/v1/provisioning.cattle.io.clusters/fleet-default/${CLUSTER_NAME}")
  log_ok "Cluster delete initiated"

  # Wait for cluster to be fully removed
  log_info "Waiting for cluster deletion..."
  local wait=0
  while [[ ${wait} -lt 600 ]]; do
    local check
    check=$(rancher_api GET "/v1/provisioning.cattle.io.clusters/fleet-default/${CLUSTER_NAME}" \
      | jq -r '.metadata.name // empty' 2>/dev/null || echo "")
    if [[ -z "${check}" || "${check}" == "null" ]]; then
      log_ok "Cluster deleted"
      break
    fi
    sleep 10
    wait=$((wait + 10))
    echo -ne "  Waiting... ${wait}s\r"
  done

  # Delete HarvesterConfigs
  for pool in cp general compute database; do
    local name="${CLUSTER_NAME}-${pool}"
    log_info "Deleting HarvesterConfig: ${name}..."
    rancher_api DELETE "/v1/rke-machine-config.cattle.io.harvesterconfigs/fleet-default/${name}" >/dev/null 2>&1 || true
    log_ok "Deleted ${name}"
  done

  # Delete Docker Hub secret
  if [[ -n "${DOCKERHUB_USERNAME}" ]]; then
    local secret_name="${CLUSTER_NAME}-dockerhub-auth"
    log_info "Deleting Docker Hub secret: ${secret_name}..."
    rancher_api DELETE "/v1/secrets/fleet-default/${secret_name}" >/dev/null 2>&1 || true
    log_ok "Deleted ${secret_name}"
  fi

  # Delete cloud credential
  log_info "Deleting cloud credential: ${CLOUD_CRED_NAME}..."
  local cred_id
  cred_id=$(rancher_api GET "/v3/cloudCredentials" | jq -r \
    ".data[] | select(.name == \"${CLOUD_CRED_NAME}\") | .id" 2>/dev/null || echo "")
  if [[ -n "${cred_id}" ]]; then
    rancher_api DELETE "/v3/cloudCredentials/${cred_id}" >/dev/null 2>&1 || true
    log_ok "Deleted cloud credential"
  else
    log_info "Cloud credential not found -- already deleted?"
  fi

  echo ""
  log_ok "Cleanup complete"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  DRY_RUN=false
  DELETE_MODE=false
  UPDATE_MODE=false

  case "${1:-}" in
    --dry-run)  DRY_RUN=true ;;
    --delete)   DELETE_MODE=true ;;
    --update)   UPDATE_MODE=true ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--dry-run|--update|--delete|--help]"
      echo ""
      echo "  (no args)   Create cluster via Rancher API"
      echo "  --dry-run   Show JSON payloads without creating anything"
      echo "  --update    Update existing cluster (k8s version, chart values, registries)"
      echo "  --delete    Delete cluster and all associated resources"
      echo "  --help      Show this help"
      exit 0
      ;;
    "") ;;
    *)  die "Unknown option: $1" ;;
  esac

  echo ""
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  if [[ "${DRY_RUN}" == true ]]; then
    echo -e "${BOLD}${BLUE}  RKE2 Cluster — Rancher API Deploy (DRY RUN)${NC}"
  elif [[ "${UPDATE_MODE}" == true ]]; then
    echo -e "${BOLD}${BLUE}  RKE2 Cluster — Rancher API Update${NC}"
  elif [[ "${DELETE_MODE}" == true ]]; then
    echo -e "${BOLD}${BLUE}  RKE2 Cluster — Rancher API Delete${NC}"
  else
    echo -e "${BOLD}${BLUE}  RKE2 Cluster — Rancher API Deploy${NC}"
  fi
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo ""

  # Check prerequisites
  for cmd in curl jq python3; do
    command -v "${cmd}" &>/dev/null || die "Missing required command: ${cmd}"
  done

  # Load config
  load_config

  if [[ "${DELETE_MODE}" == true ]]; then
    delete_cluster
    exit 0
  fi

  if [[ "${UPDATE_MODE}" == true ]]; then
    # Update needs cloud credential ID and dockerhub secret name for spec
    create_cloud_credential
    create_dockerhub_secret
    update_cluster

    if [[ "${DRY_RUN}" == true ]]; then
      echo ""
      log_ok "Dry run complete -- no changes were applied"
    fi
    exit 0
  fi

  # Create resources in order
  create_cloud_credential
  create_dockerhub_secret
  create_all_machine_configs
  create_cluster

  if [[ "${DRY_RUN}" == true ]]; then
    echo ""
    log_ok "Dry run complete -- no resources were created"
    exit 0
  fi

  # Monitor
  echo ""
  echo -e "${BOLD}Resources created:${NC}"
  echo -e "  ${GREEN}+${NC} Cloud credential: ${CLOUD_CRED_ID}"
  echo -e "  ${GREEN}+${NC} HarvesterConfigs: ${CLUSTER_NAME}-{cp,general,compute,database}"
  echo -e "  ${GREEN}+${NC} Cluster: ${CLUSTER_NAME}"
  echo ""

  monitor_provisioning
}

main "$@"
