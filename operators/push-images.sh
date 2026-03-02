#!/usr/bin/env bash
# push-images.sh — Push pre-built OCI image tarballs to Harbor via crane
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
: "${HARBOR_PASSWORD:?HARBOR_PASSWORD is required}"
: "${IMAGES_DIR:?IMAGES_DIR is required}"

HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PROJECT="library"

# Verify crane is available
if ! command -v crane &>/dev/null; then
  echo "ERROR: crane is not installed. Install it from https://github.com/google/go-containerregistry/tree/main/cmd/crane" >&2
  exit 1
fi

# Build crane TLS flags
CRANE_TLS_FLAGS=()
TMPDIR_CLEANUP=""

if [[ -n "${HARBOR_CA_PEM:-}" ]]; then
  CA_TMPDIR="$(mktemp -d)"
  TMPDIR_CLEANUP="${CA_TMPDIR}"
  CA_FILE="${CA_TMPDIR}/harbor-ca.pem"
  echo "${HARBOR_CA_PEM}" > "${CA_FILE}"
  CRANE_TLS_FLAGS+=(--ca-cert "${CA_FILE}")
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

# Authenticate to Harbor
echo "Authenticating to ${HARBOR_FQDN} as ${HARBOR_USER}..."
crane auth login "${HARBOR_FQDN}" \
  --username "${HARBOR_USER}" \
  --password "${HARBOR_PASSWORD}" \
  "${CRANE_TLS_FLAGS[@]}"

# Count images
PUSHED=0
SKIPPED=0
FAILED=0

if ! compgen -G "${IMAGES_DIR}/*.tar.gz" >/dev/null 2>&1; then
  echo "WARNING: No *.tar.gz files found in ${IMAGES_DIR}" >&2
  exit 0
fi

for tarball in "${IMAGES_DIR}"/*.tar.gz; do
  filename="$(basename "${tarball}")"

  # Parse name and version from filename
  # Expected format: <name>-<version>-<arch>.tar.gz
  # e.g., node-labeler-v0.2.0-amd64.tar.gz
  # The version starts with 'v', so we split on '-v' to get name and the rest
  if [[ ! "${filename}" =~ ^(.+)-(v[0-9][0-9a-zA-Z._-]*)-([a-z0-9]+)\.tar\.gz$ ]]; then
    echo "WARNING: Skipping ${filename} — does not match naming convention <name>-<version>-<arch>.tar.gz" >&2
    continue
  fi

  IMAGE_NAME="${BASH_REMATCH[1]}"
  IMAGE_TAG="${BASH_REMATCH[2]}"
  FULL_REF="${HARBOR_FQDN}/${HARBOR_PROJECT}/${IMAGE_NAME}:${IMAGE_TAG}"

  # Idempotency check — skip if image already exists in Harbor
  if crane manifest "${FULL_REF}" "${CRANE_TLS_FLAGS[@]}" &>/dev/null; then
    echo "SKIP: ${FULL_REF} already exists"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  echo "PUSH: ${filename} -> ${FULL_REF}"

  # Extract OCI layout to temp dir and push
  IMG_TMPDIR="$(mktemp -d)"
  if tar -xzf "${tarball}" -C "${IMG_TMPDIR}" 2>/dev/null; then
    if crane push "${IMG_TMPDIR}" "${FULL_REF}" "${CRANE_TLS_FLAGS[@]}"; then
      PUSHED=$((PUSHED + 1))
    else
      echo "ERROR: Failed to push ${FULL_REF}" >&2
      FAILED=$((FAILED + 1))
    fi
  else
    echo "ERROR: Failed to extract ${tarball}" >&2
    FAILED=$((FAILED + 1))
  fi
  rm -rf "${IMG_TMPDIR}"
  IMG_TMPDIR=""
done

echo ""
echo "Image push complete: ${PUSHED} pushed, ${SKIPPED} skipped, ${FAILED} failed"

if [[ "${FAILED}" -gt 0 ]]; then
  exit 1
fi
