#!/usr/bin/env bash
# Validate that all Terraform attributes listed in terraform-provider-fields.yml
# exist in the provider schema. Requires: terraform, yq, jq.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIELDS_FILE="${SCRIPT_DIR}/terraform-provider-fields.yml"
TF_DIR="${SCRIPT_DIR}/../../deploy-terraform"

if ! command -v yq &>/dev/null; then
  echo "ERROR: yq is required but not installed" >&2
  exit 1
fi

if ! command -v terraform &>/dev/null; then
  echo "ERROR: terraform is required but not installed" >&2
  exit 1
fi

echo "Initializing Terraform (local backend override for CI)..."
WORK_DIR=$(mktemp -d)
cp -r "${TF_DIR}"/* "${WORK_DIR}/"
# Override backend to local so providers schema works without K8s cluster
cat > "${WORK_DIR}/backend_override.tf" <<'TFOVERRIDE'
terraform {
  backend "local" {}
}
TFOVERRIDE
if ! terraform -chdir="${WORK_DIR}" init -reconfigure -input=false -no-color; then
  echo "ERROR: terraform init failed" >&2
  rm -rf "${WORK_DIR}"
  exit 1
fi

echo "Extracting provider schema..."
SCHEMA_FILE=$(mktemp)
if ! terraform -chdir="${WORK_DIR}" providers schema -json > "${SCHEMA_FILE}" 2>&1; then
  echo "ERROR: terraform providers schema failed:" >&2
  cat "${SCHEMA_FILE}" >&2
  rm -f "${SCHEMA_FILE}"
  exit 1
fi

if [ ! -s "${SCHEMA_FILE}" ]; then
  echo "ERROR: terraform providers schema returned empty output" >&2
  rm -f "${SCHEMA_FILE}"
  exit 1
fi

ERRORS=0
CHECKED=0

# Check each resource type defined in the fields file
for resource in $(yq -r '.resources | keys[]' "${FIELDS_FILE}"); do
  echo ""
  echo "Checking resource: ${resource}"

  # Find the resource schema in terraform providers schema output
  RESOURCE_SCHEMA=$(jq < "${SCHEMA_FILE}" -r \
    ".provider_schemas[].resource_schemas[\"${resource}\"].block" 2>/dev/null || echo "")

  if [ -z "${RESOURCE_SCHEMA}" ] || [ "${RESOURCE_SCHEMA}" = "null" ]; then
    echo "  ERROR: Resource '${resource}' not found in provider schema"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Check each top-level attribute exists
  for attr in $(yq -r ".resources.\"${resource}\".attributes[]" "${FIELDS_FILE}" 2>/dev/null); do
    CHECKED=$((CHECKED + 1))
    # Extract the top-level attribute name (before any dots)
    top_attr="${attr%%.*}"

    # Check in attributes and block_types
    EXISTS=$(echo "${RESOURCE_SCHEMA}" | jq -r \
      "(.attributes[\"${top_attr}\"] // .block_types[\"${top_attr}\"] // null) | type" 2>/dev/null || echo "null")

    if [ "${EXISTS}" = "null" ]; then
      echo "  MISSING: ${attr} (top-level '${top_attr}' not in schema)"
      ERRORS=$((ERRORS + 1))
    else
      echo "  OK: ${attr}"
    fi
  done
done

echo ""
echo "Checked ${CHECKED} attributes, ${ERRORS} errors"

if [ "${ERRORS}" -gt 0 ]; then
  echo "FAIL: ${ERRORS} attribute(s) not found in provider schema"
  exit 1
fi

rm -f "${SCHEMA_FILE}"
rm -rf "${WORK_DIR}"
echo "PASS: All attributes found in provider schema"
