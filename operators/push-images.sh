#!/usr/bin/env bash
# push-images.sh — Push custom operator images to Harbor via crane
#
# Pushes pre-built OCI tarballs from IMAGES_DIR to Harbor's library project.
# Used for custom operators (node-labeler, storage-autoscaler) that are built
# locally and shipped as tar.gz archives. DB operators (CNPG, MariaDB, Redis)
# use upstream image references directly and are rewritten via registries.yaml.
#
# Required environment variables:
#   HARBOR_FQDN      Harbor registry hostname (e.g., harbor.example.com)
#   HARBOR_PASSWORD   Harbor admin password
#   IMAGES_DIR        Directory containing *.tar.gz OCI image tarballs
#
# Optional environment variables:
#   HARBOR_USER       Harbor username (default: admin)
#   HARBOR_CA_PEM     PEM-encoded CA certificate for TLS trust
#
# Naming convention for tarballs:
#   <name>-<version>-<arch>.tar.gz
#   e.g., node-labeler-v0.2.0-amd64.tar.gz -> harbor.example.com/library/node-labeler:v0.2.0
set -euo pipefail

: "${HARBOR_FQDN:?HARBOR_FQDN is required}"
: "${IMAGES_DIR:?IMAGES_DIR is required}"
# HARBOR_PASSWORD is optional — when empty, the script runs in anonymous mode
# (works for Harbor projects configured for anonymous read/write, e.g. /library).
HARBOR_PASSWORD="${HARBOR_PASSWORD:-}"

HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PROJECT="library"

# Verify crane is available
if ! command -v crane &>/dev/null; then
  echo "ERROR: crane is not installed. Install it from https://github.com/google/go-containerregistry/tree/main/cmd/crane" >&2
  exit 1
fi

# Build crane TLS flags
# crane v0.21+ does not support --ca-cert; use SSL_CERT_FILE for custom CA trust
CRANE_TLS_FLAGS=()
TMPDIR_CLEANUP=""

if [[ -n "${HARBOR_CA_PEM:-}" ]]; then
  CA_TMPDIR="$(mktemp -d)"
  TMPDIR_CLEANUP="${CA_TMPDIR}"
  CA_FILE="${CA_TMPDIR}/harbor-ca.pem"
  echo "${HARBOR_CA_PEM}" > "${CA_FILE}"
  # Append system CAs so crane trusts both Harbor CA and public roots
  if [[ -f /etc/pki/tls/certs/ca-bundle.crt ]]; then
    cat /etc/pki/tls/certs/ca-bundle.crt >> "${CA_FILE}"
  elif [[ -f /etc/ssl/certs/ca-certificates.crt ]]; then
    cat /etc/ssl/certs/ca-certificates.crt >> "${CA_FILE}"
  fi
  export SSL_CERT_FILE="${CA_FILE}"
else
  echo "WARNING: No HARBOR_CA_PEM provided — using --insecure for TLS" >&2
  CRANE_TLS_FLAGS+=(--insecure)
fi

cleanup() {
  if [[ -n "${TMPDIR_CLEANUP}" && -d "${TMPDIR_CLEANUP}" ]]; then
    rm -rf "${TMPDIR_CLEANUP}"
  fi
  # Clean up any image extraction temp dirs
  if [[ -n "${IMG_TMPDIR:-}" && -d "${IMG_TMPDIR:-}" ]]; then
    rm -rf "${IMG_TMPDIR}"
  fi
}
trap cleanup EXIT

# Authenticate to Harbor (skipped when HARBOR_PASSWORD is empty — assumes the
# target Harbor project allows anonymous read/push, which is how
# harbor.example.com /library/ is configured. The idempotency check below
# uses `crane manifest` which works anonymously on public projects.)
if [[ -n "${HARBOR_PASSWORD}" ]]; then
  echo "Authenticating to ${HARBOR_FQDN} as ${HARBOR_USER}..."
  crane auth login "${HARBOR_FQDN}" \
    --username "${HARBOR_USER}" \
    --password "${HARBOR_PASSWORD}" \
    "${CRANE_TLS_FLAGS[@]}"
else
  echo "HARBOR_PASSWORD empty — skipping auth login (anonymous mode for public /library)"
fi

# ---------------------------------------------------------------------------
# push_local_images — Push pre-built OCI tarballs from IMAGES_DIR
# ---------------------------------------------------------------------------
push_local_images() {
  local pushed=0 skipped=0 failed=0

  if ! compgen -G "${IMAGES_DIR}/*.tar.gz" >/dev/null 2>&1; then
    echo "WARNING: No *.tar.gz files found in ${IMAGES_DIR}" >&2
    return 0
  fi

  for tarball in "${IMAGES_DIR}"/*.tar.gz; do
    local filename
    filename="$(basename "${tarball}")"

    # Parse name and version from filename
    # Expected format: <name>-<version>-<arch>.tar.gz
    # e.g., node-labeler-v0.2.0-amd64.tar.gz
    # The version starts with 'v', so we split on '-v' to get name and the rest
    if [[ ! "${filename}" =~ ^(.+)-(v[0-9][0-9a-zA-Z._-]*)-([a-z0-9]+)\.tar\.gz$ ]]; then
      echo "WARNING: Skipping ${filename} — does not match naming convention <name>-<version>-<arch>.tar.gz" >&2
      continue
    fi

    local image_name="${BASH_REMATCH[1]}"
    local image_tag="${BASH_REMATCH[2]}"
    local full_ref="${HARBOR_FQDN}/${HARBOR_PROJECT}/${image_name}:${image_tag}"

    # Idempotency check — skip if image already exists in Harbor
    if crane manifest "${full_ref}" "${CRANE_TLS_FLAGS[@]}" &>/dev/null; then
      echo "SKIP: ${full_ref} already exists"
      skipped=$((skipped + 1))
      continue
    fi

    echo "PUSH: ${filename} -> ${full_ref}"

    # Extract OCI layout to temp dir and push
    IMG_TMPDIR="$(mktemp -d)"
    if tar -xzf "${tarball}" -C "${IMG_TMPDIR}" 2>/dev/null; then
      if crane push "${IMG_TMPDIR}" "${full_ref}" "${CRANE_TLS_FLAGS[@]}"; then
        pushed=$((pushed + 1))
      else
        echo "ERROR: Failed to push ${full_ref}" >&2
        failed=$((failed + 1))
      fi
    else
      echo "ERROR: Failed to extract ${tarball}" >&2
      failed=$((failed + 1))
    fi
    rm -rf "${IMG_TMPDIR}"
    IMG_TMPDIR=""
  done

  echo ""
  echo "Local images: ${pushed} pushed, ${skipped} skipped, ${failed} failed"
  if [[ "${failed}" -gt 0 ]]; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
push_local_images
