#!/usr/bin/env bash
# =============================================================================
# push-charts.sh — package and push Helm charts to Harbor OCI
# =============================================================================
# Pushes:
#   operators/storage-autoscaler/chart/   →  oci://${HARBOR_FQDN}/library
#   operators/cluster-autoscaler/chart/   →  oci://${HARBOR_FQDN}/kubernetes.github.io/autoscaler
#
# Idempotent: if a chart version already exists in Harbor, skips push.
#
# Env vars:
#   HARBOR_FQDN       required (e.g. harbor.example.com)
#   HARBOR_USER       optional (anonymous works for /library)
#   HARBOR_PASSWORD   optional
#   HARBOR_CA_PEM     optional — PEM cert text for private CA trust
# =============================================================================

set -euo pipefail

: "${HARBOR_FQDN:?HARBOR_FQDN must be set}"
: "${HARBOR_USER:=}"
: "${HARBOR_PASSWORD:=}"
: "${HARBOR_CA_PEM:=}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

# Trust private CA if provided (helm inherits system CAs)
if [ -n "${HARBOR_CA_PEM}" ]; then
  CA_FILE="${STAGE_DIR}/harbor-ca.pem"
  printf '%s\n' "${HARBOR_CA_PEM}" > "${CA_FILE}"
  export SSL_CERT_FILE="${CA_FILE}"
fi

# Login if creds provided (anonymous works for harbor /library pulls but push needs auth)
if [ -n "${HARBOR_USER}" ] && [ -n "${HARBOR_PASSWORD}" ]; then
  echo "Logging into Harbor as ${HARBOR_USER}..."
  echo "${HARBOR_PASSWORD}" | helm registry login "${HARBOR_FQDN}" \
    --username "${HARBOR_USER}" --password-stdin
fi

push_chart() {
  local chart_dir="$1"
  local oci_target="$2"

  local chart_name chart_version
  chart_name=$(awk '/^name:/ {print $2}' "${chart_dir}/Chart.yaml")
  chart_version=$(awk '/^version:/ {print $2}' "${chart_dir}/Chart.yaml" | tr -d '"')

  echo "----"
  echo "Chart: ${chart_name} ${chart_version}"
  echo "Target: ${oci_target}"

  # Idempotency check: does this chart+version already exist?
  if helm pull "${oci_target}/${chart_name}" --version "${chart_version}" \
       --destination "${STAGE_DIR}/pull-check" 2>/dev/null; then
    echo "  → already present, skipping push"
    return 0
  fi

  echo "  → packaging..."
  helm package "${chart_dir}" --destination "${STAGE_DIR}"

  echo "  → pushing to ${oci_target}..."
  helm push "${STAGE_DIR}/${chart_name}-${chart_version}.tgz" "${oci_target}"
}

push_chart "${SCRIPT_DIR}/storage-autoscaler/chart" \
  "oci://${HARBOR_FQDN}/library"

push_chart "${SCRIPT_DIR}/cluster-autoscaler/chart" \
  "oci://${HARBOR_FQDN}/kubernetes.github.io/autoscaler"

echo "----"
echo "All charts pushed successfully."
