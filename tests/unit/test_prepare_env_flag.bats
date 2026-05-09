#!/usr/bin/env bats
# Tests for --env flag in prepare.sh

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../prepare.sh"
  TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMPDIR_TEST}"
}

@test "--help mentions --env flag" {
  run bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--env"* ]]
}

@test "--env with missing file exits non-zero with clear error" {
  run bash "${SCRIPT}" --env "${TMPDIR_TEST}/missing.env"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not found"* ]]
  [[ "${output}" == *"missing.env"* ]]
}

@test "--env requires an argument" {
  run bash "${SCRIPT}" --env
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"requires a file path"* ]]
}

@test "--env helper resolves CLUSTER_NAME and VM_NAMESPACE for output naming" {
  # We test the resolve_env_target() helper indirectly by sourcing it.
  # When given an env file with CLUSTER_NAME=cname and VM_NAMESPACE=ns,
  # the suffixed output paths should embed cname.
  cat > "${TMPDIR_TEST}/test.env" <<STUB
RANCHER_URL="https://example.invalid"
RANCHER_TOKEN="token-xxxxx"
CLUSTER_NAME="cname"
VM_NAMESPACE="ns"
HARVESTER_CLUSTER_ID="c-xxxxx"
CLOUD_CRED_NAME="cname-harvester"
STUB
  # Source resolve_env_target from prepare.sh into a controlled scope
  ENV_FILE="${TMPDIR_TEST}/test.env"
  source <(sed -n '/^resolve_env_target()/,/^}/p' "${SCRIPT}")
  resolve_env_target
  [[ "${TARGET_CLUSTER}" == "cname" ]]
  [[ "${TARGET_VM_NAMESPACE}" == "ns" ]]
  [[ "${CLOUD_PROVIDER_KUBECONFIG_OUT}" == *"harvester-cloud-provider-kubeconfig-cname" ]]
  [[ "${CLOUD_CRED_KUBECONFIG_OUT}" == *"kubeconfig-harvester-cloud-cred-cname.yaml" ]]
}

@test "default (no --env) uses unsuffixed filenames" {
  source <(sed -n '/^resolve_env_target()/,/^}/p' "${SCRIPT}")
  unset ENV_FILE
  resolve_env_target
  [[ "${CLOUD_PROVIDER_KUBECONFIG_OUT}" == *"/harvester-cloud-provider-kubeconfig" ]]
  [[ "${CLOUD_PROVIDER_KUBECONFIG_OUT}" != *"-cname"* ]]
  [[ "${CLOUD_CRED_KUBECONFIG_OUT}" == *"/kubeconfig-harvester-cloud-cred.yaml" ]]
}

@test "migrate_unsuffixed_files renames when unsuffixed exists and suffixed missing" {
  SCRIPT_DIR="${TMPDIR_TEST}"
  TARGET_CLUSTER="cname"
  ENV_FILE="${TMPDIR_TEST}/.env.cname"
  CLOUD_PROVIDER_KUBECONFIG_OUT="${TMPDIR_TEST}/harvester-cloud-provider-kubeconfig-cname"
  CLOUD_CRED_KUBECONFIG_OUT="${TMPDIR_TEST}/kubeconfig-harvester-cloud-cred-cname.yaml"
  echo "old-cpkc" > "${TMPDIR_TEST}/harvester-cloud-provider-kubeconfig"
  echo "old-cckc" > "${TMPDIR_TEST}/kubeconfig-harvester-cloud-cred.yaml"

  # Source helpers + auto-confirm
  source <(sed -n '/^log_/,/^}/p; /^die()/,/^}/p; /^migrate_unsuffixed_files()/,/^}/p' "${BATS_TEST_DIRNAME}/../../prepare.sh")
  confirm_overwrite() { return 0; }
  export -f confirm_overwrite

  run migrate_unsuffixed_files
  [ "${status}" -eq 0 ]
  [ -f "${CLOUD_PROVIDER_KUBECONFIG_OUT}" ]
  [ -f "${CLOUD_CRED_KUBECONFIG_OUT}" ]
  [ ! -f "${TMPDIR_TEST}/harvester-cloud-provider-kubeconfig" ]
}

@test "update_env_pointers rewrites file pointers and token in place" {
  cat > "${TMPDIR_TEST}/dst.env" <<STUB
RANCHER_URL="https://example.invalid"
RANCHER_TOKEN="token-OLD"
CLUSTER_NAME="cname"
VM_NAMESPACE="ns"
CLOUD_PROVIDER_KUBECONFIG_FILE="./old-cpkc"
CLOUD_CRED_KUBECONFIG_FILE="./old-cckc"
STUB
  ENV_FILE="${TMPDIR_TEST}/dst.env"
  ENV_OUT="${ENV_FILE}"
  CLOUD_PROVIDER_KUBECONFIG_OUT="/abs/harvester-cloud-provider-kubeconfig-cname"
  CLOUD_CRED_KUBECONFIG_OUT="/abs/kubeconfig-harvester-cloud-cred-cname.yaml"
  RANCHER_TOKEN="token-NEW"
  source <(sed -n '/^update_env_pointers()/,/^}/p' "${BATS_TEST_DIRNAME}/../../prepare.sh")
  source <(sed -n '/^log_ok()/,/^}/p; /^log_warn()/,/^}/p' "${BATS_TEST_DIRNAME}/../../prepare.sh")
  run update_env_pointers
  [ "${status}" -eq 0 ]
  grep -q 'CLOUD_PROVIDER_KUBECONFIG_FILE="./harvester-cloud-provider-kubeconfig-cname"' "${ENV_FILE}"
  grep -q 'CLOUD_CRED_KUBECONFIG_FILE="./kubeconfig-harvester-cloud-cred-cname.yaml"' "${ENV_FILE}"
  grep -q 'RANCHER_TOKEN="token-NEW"' "${ENV_FILE}"
  ! grep -q 'token-OLD' "${ENV_FILE}"
}
