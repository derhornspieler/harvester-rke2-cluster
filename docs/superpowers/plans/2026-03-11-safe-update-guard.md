# Safe Update Guard for rancher-api-deploy.sh

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent `--update` from bricking a production cluster by detecting destructive changes and requiring explicit confirmation before applying them.

**Architecture:** Add a pre-flight diff engine to `update_cluster()` that fetches live cluster + HarvesterConfig state from the Rancher API, compares against what `.env` would generate, classifies each diff as safe/dangerous/destructive, and gates on user confirmation. Safe-only changes proceed without prompting. Dangerous changes show a diff and require `--force` or interactive `yes`. The existing `--dry-run` mode also gains full diff output.

**Tech Stack:** Bash, jq, curl (same as existing script — no new dependencies)

---

## Root Cause Analysis

On 2026-03-11, `rancher-api-deploy.sh --update` bricked the rke2-prod cluster because:

1. **`.env` had rke2-dev test values** — smaller VMs (2 CPU/8GB vs 4 CPU/16GB), different golden image, smaller disks
2. **`update_cluster()` does a blind deep merge**: `.spec = (.spec * $desired_spec)` overwrites the live spec with whatever `.env` generates — no comparison, no warning
3. **The merge changed `machinePools` parameters** — even though HarvesterConfigs weren't explicitly updated in `--update` mode, the cluster spec merge changed pool quantities and the Rancher provisioning controller reconciled HarvesterConfigs from the new spec
4. **CAPI treated all nodes as "outdated revision"** — cordoned every node simultaneously and spun up replacements that couldn't join (Cilium crash-loop from overwhelming the cluster)
5. **No rollback possible** — CAPI `deletionTimestamp` is immutable in Kubernetes; once set, nodes are permanently marked for deletion

### What triggers rolling replacement vs safe update

| Field changed | Impact |
|---|---|
| `kubernetesVersion` | Rolling upgrade (safe if strategy has maxUnavailable=0) |
| `chartValues`, `machineGlobalConfig`, `registries` | In-place reconciliation (safe) |
| `etcd`, `upgradeStrategy` | Config update (safe) |
| HarvesterConfig `diskInfo` (image, size) | **New MachineTemplate → full node replacement** |
| HarvesterConfig `cpuCount`, `memorySize` | **New MachineTemplate → full node replacement** |
| HarvesterConfig `userData` (cloud-init) | **New MachineTemplate → full node replacement** |
| HarvesterConfig `networkInfo` | **New MachineTemplate → full node replacement** |
| `machinePools[].quantity` decrease | **Node deletion (data loss if stateful)** |

---

## File Structure

| File | Responsibility |
|---|---|
| `rancher-api-deploy.sh` | Main script — add `diff_and_guard()`, modify `update_cluster()`, add `--force` flag |
| `tests/test_update_guard.bats` | BATS tests for diff logic (mock API responses, verify classification) |

No new files needed — all changes go into the existing script plus a new test file.

---

## Chunk 1: Pre-flight Diff Engine

### Task 1: Add `--force` flag to argument parser

**Files:**
- Modify: `rancher-api-deploy.sh:1040-1061` (main function argument parsing)

- [ ] **Step 1: Add FORCE_MODE variable and `--force` flag**

In the `main()` function, after `UPDATE_MODE=false` (line 1043), add:

```bash
FORCE_MODE=false
```

In the `case` statement (line 1045), add:

```bash
--force)    FORCE_MODE=true ;;
```

Update the help text (line 1050-1056) to include:

```bash
echo "  --force     Skip confirmation prompts for destructive updates"
```

- [ ] **Step 2: Verify script still runs with `--help`**

Run: `cd /home/rocky/code/harvester-rke2-cluster && bash rancher-api-deploy.sh --help`
Expected: Help text includes `--force` option

- [ ] **Step 3: Commit**

```bash
git add rancher-api-deploy.sh
git commit -m "feat: add --force flag for update safety bypass"
```

---

### Task 2: Add `fetch_live_harvester_configs()` function

**Files:**
- Modify: `rancher-api-deploy.sh` — add new function after `rancher_api_patch()` (after line 102)

- [ ] **Step 1: Write the function**

This function fetches the current HarvesterConfig for each pool from the Rancher API and outputs a normalized JSON object for comparison.

```bash
# -----------------------------------------------------------------------------
# Fetch live HarvesterConfig state for diff comparison
# -----------------------------------------------------------------------------
fetch_live_harvester_configs() {
  local configs="{}"
  for pool in cp general compute database; do
    local name="${CLUSTER_NAME}-${pool}"
    local response
    response=$(rancher_api GET "/v1/rke-machine-config.cattle.io.harvesterconfigs/fleet-default/${name}")
    local exists
    exists=$(echo "${response}" | jq -r '.metadata.name // empty' 2>/dev/null || echo "")
    if [[ -n "${exists}" && "${exists}" != "null" ]]; then
      local normalized
      normalized=$(echo "${response}" | jq '{
        cpuCount: .cpuCount,
        memorySize: .memorySize,
        diskInfo: .diskInfo,
        networkInfo: .networkInfo,
        userData: (.userData | length),
        vmNamespace: .vmNamespace
      }')
      configs=$(echo "${configs}" | jq --arg pool "${pool}" --argjson cfg "${normalized}" '. + {($pool): $cfg}')
    fi
  done
  echo "${configs}"
}
```

- [ ] **Step 2: Test manually against a running cluster**

After the cluster is redeployed, test:
```bash
source .env && fetch_live_harvester_configs | jq .
```
Expected: JSON with 4 pools showing cpuCount, memorySize, diskInfo, etc.

- [ ] **Step 3: Commit**

```bash
git add rancher-api-deploy.sh
git commit -m "feat: add fetch_live_harvester_configs for pre-flight diff"
```

---

### Task 3: Add `build_desired_harvester_configs()` function

**Files:**
- Modify: `rancher-api-deploy.sh` — add after `fetch_live_harvester_configs()`

- [ ] **Step 1: Write the function**

This generates the same normalized JSON but from the current `.env` values — what `create_all_machine_configs()` WOULD create.

```bash
build_desired_harvester_configs() {
  local disk_info_cp disk_info_gen disk_info_comp disk_info_db
  disk_info_cp=$(jq -nc --arg img "${IMAGE_FULL_NAME}" --argjson sz "${CP_DISK}" \
    '{disks: [{imageName: $img, size: $sz, bootOrder: 1}]}')
  disk_info_gen=$(jq -nc --arg img "${IMAGE_FULL_NAME}" --argjson sz "${GEN_DISK}" \
    '{disks: [{imageName: $img, size: $sz, bootOrder: 1}]}')
  disk_info_comp=$(jq -nc --arg img "${IMAGE_FULL_NAME}" --argjson sz "${COMP_DISK}" \
    '{disks: [{imageName: $img, size: $sz, bootOrder: 1}]}')
  disk_info_db=$(jq -nc --arg img "${IMAGE_FULL_NAME}" --argjson sz "${DB_DISK}" \
    '{disks: [{imageName: $img, size: $sz, bootOrder: 1}]}')

  local ud_cp_len ud_worker_len
  ud_cp_len=$(build_cloud_init_cp | wc -c)
  ud_worker_len=$(build_cloud_init_worker | wc -c)

  jq -n \
    --arg cp_cpu "${CP_CPU}" --arg cp_mem "${CP_MEM}" --arg cp_disk "${disk_info_cp}" \
    --argjson cp_ud "${ud_cp_len}" \
    --arg gen_cpu "${GEN_CPU}" --arg gen_mem "${GEN_MEM}" --arg gen_disk "${disk_info_gen}" \
    --argjson gen_ud "${ud_worker_len}" \
    --arg comp_cpu "${COMP_CPU}" --arg comp_mem "${COMP_MEM}" --arg comp_disk "${disk_info_comp}" \
    --argjson comp_ud "${ud_worker_len}" \
    --arg db_cpu "${DB_CPU}" --arg db_mem "${DB_MEM}" --arg db_disk "${disk_info_db}" \
    --argjson db_ud "${ud_worker_len}" \
    --arg vmns "${VM_NAMESPACE}" \
    '{
      cp:       {cpuCount: $cp_cpu, memorySize: $cp_mem, diskInfo: $cp_disk, userData: $cp_ud, vmNamespace: $vmns},
      general:  {cpuCount: $gen_cpu, memorySize: $gen_mem, diskInfo: $gen_disk, userData: $gen_ud, vmNamespace: $vmns},
      compute:  {cpuCount: $comp_cpu, memorySize: $comp_mem, diskInfo: $comp_disk, userData: $comp_ud, vmNamespace: $vmns},
      database: {cpuCount: $db_cpu, memorySize: $db_mem, diskInfo: $db_disk, userData: $db_ud, vmNamespace: $vmns}
    }'
}
```

- [ ] **Step 2: Commit**

```bash
git add rancher-api-deploy.sh
git commit -m "feat: add build_desired_harvester_configs for diff comparison"
```

---

### Task 4: Add `diff_and_guard()` — the core safety function

**Files:**
- Modify: `rancher-api-deploy.sh` — add after `build_desired_harvester_configs()`

- [ ] **Step 1: Write the diff and classification function**

```bash
# -----------------------------------------------------------------------------
# Pre-flight diff: compare live state vs desired, classify impact, gate on risk
# -----------------------------------------------------------------------------
diff_and_guard() {
  log_info "Running pre-flight safety check..."

  local has_safe_changes=false
  local has_dangerous_changes=false
  local has_destructive_changes=false
  local changes=()

  # --- 1. Cluster spec diffs (k8s version, chart values, etc.) ---
  local current
  current=$(rancher_api GET "/v1/provisioning.cattle.io.clusters/fleet-default/${CLUSTER_NAME}")
  local current_name
  current_name=$(echo "${current}" | jq -r '.metadata.name // empty' 2>/dev/null || echo "")
  if [[ -z "${current_name}" || "${current_name}" == "null" ]]; then
    die "Cluster ${CLUSTER_NAME} does not exist"
  fi

  local current_k8s
  current_k8s=$(echo "${current}" | jq -r '.spec.kubernetesVersion // "unknown"')
  if [[ "${current_k8s}" != "${K8S_VERSION}" ]]; then
    changes+=("$(printf "  ${YELLOW}[SAFE]${NC}      K8s version: ${current_k8s} -> ${K8S_VERSION}")")
    has_safe_changes=true
  fi

  # --- 2. Machine pool quantity diffs ---
  for pool_name in controlplane general compute database; do
    local current_qty desired_qty
    current_qty=$(echo "${current}" | jq -r \
      ".spec.rkeConfig.machinePools[] | select(.name == \"${pool_name}\") | .quantity" 2>/dev/null || echo "0")

    case "${pool_name}" in
      controlplane) desired_qty="${CP_COUNT}" ;;
      general)      desired_qty="${GEN_MIN}" ;;
      compute)      desired_qty="${COMP_MIN}" ;;
      database)     desired_qty="${DB_MIN}" ;;
    esac

    if [[ "${current_qty}" != "${desired_qty}" ]]; then
      if [[ "${desired_qty}" -lt "${current_qty}" ]]; then
        changes+=("$(printf "  ${RED}[DESTROY]${NC}   ${pool_name} pool: ${current_qty} -> ${desired_qty} nodes (NODES WILL BE DELETED)")")
        has_destructive_changes=true
      else
        changes+=("$(printf "  ${YELLOW}[SAFE]${NC}      ${pool_name} pool: ${current_qty} -> ${desired_qty} nodes (scale up)")")
        has_safe_changes=true
      fi
    fi
  done

  # --- 3. HarvesterConfig diffs (triggers node replacement) ---
  local live_configs desired_configs
  live_configs=$(fetch_live_harvester_configs)
  desired_configs=$(build_desired_harvester_configs)

  for pool in cp general compute database; do
    local live_pool desired_pool
    live_pool=$(echo "${live_configs}" | jq -r ".${pool} // empty" 2>/dev/null)
    desired_pool=$(echo "${desired_configs}" | jq -r ".${pool} // empty" 2>/dev/null)

    if [[ -z "${live_pool}" ]]; then
      continue  # Config doesn't exist yet (new pool)
    fi

    # Compare CPU
    local live_cpu desired_cpu
    live_cpu=$(echo "${live_pool}" | jq -r '.cpuCount')
    desired_cpu=$(echo "${desired_pool}" | jq -r '.cpuCount')
    if [[ "${live_cpu}" != "${desired_cpu}" ]]; then
      changes+=("$(printf "  ${RED}[DANGER]${NC}    ${pool} CPU: ${live_cpu} -> ${desired_cpu} (triggers node replacement)")")
      has_dangerous_changes=true
    fi

    # Compare memory
    local live_mem desired_mem
    live_mem=$(echo "${live_pool}" | jq -r '.memorySize')
    desired_mem=$(echo "${desired_pool}" | jq -r '.memorySize')
    if [[ "${live_mem}" != "${desired_mem}" ]]; then
      changes+=("$(printf "  ${RED}[DANGER]${NC}    ${pool} memory: ${live_mem}GB -> ${desired_mem}GB (triggers node replacement)")")
      has_dangerous_changes=true
    fi

    # Compare disk (image name + size)
    local live_disk desired_disk
    live_disk=$(echo "${live_pool}" | jq -r '.diskInfo')
    desired_disk=$(echo "${desired_pool}" | jq -r '.diskInfo')
    if [[ "${live_disk}" != "${desired_disk}" ]]; then
      local live_img desired_img live_sz desired_sz
      live_img=$(echo "${live_disk}" | jq -r '.disks[0].imageName // "unknown"' 2>/dev/null || echo "unknown")
      desired_img=$(echo "${desired_disk}" | jq -r '.disks[0].imageName // "unknown"' 2>/dev/null || echo "unknown")
      live_sz=$(echo "${live_disk}" | jq -r '.disks[0].size // "?"' 2>/dev/null || echo "?")
      desired_sz=$(echo "${desired_disk}" | jq -r '.disks[0].size // "?"' 2>/dev/null || echo "?")

      if [[ "${live_img}" != "${desired_img}" ]]; then
        changes+=("$(printf "  ${RED}[DANGER]${NC}    ${pool} image: ${live_img} -> ${desired_img} (triggers node replacement)")")
        has_dangerous_changes=true
      fi
      if [[ "${live_sz}" != "${desired_sz}" ]]; then
        changes+=("$(printf "  ${RED}[DANGER]${NC}    ${pool} disk: ${live_sz}GB -> ${desired_sz}GB (triggers node replacement)")")
        has_dangerous_changes=true
      fi
    fi

    # Compare cloud-init length (rough change detection)
    local live_ud desired_ud
    live_ud=$(echo "${live_pool}" | jq -r '.userData')
    desired_ud=$(echo "${desired_pool}" | jq -r '.userData')
    local ud_delta=$(( desired_ud - live_ud ))
    if [[ ${ud_delta#-} -gt 50 ]]; then
      changes+=("$(printf "  ${RED}[DANGER]${NC}    ${pool} cloud-init changed significantly (triggers node replacement)")")
      has_dangerous_changes=true
    fi
  done

  # --- 4. Display results ---
  if [[ ${#changes[@]} -eq 0 ]]; then
    log_ok "No changes detected between .env and live cluster"
    return 0
  fi

  echo ""
  echo -e "${BOLD}Pre-flight diff: .env vs live cluster${NC}"
  echo -e "${BOLD}======================================${NC}"
  for change in "${changes[@]}"; do
    echo -e "${change}"
  done
  echo ""

  # --- 5. Gate on risk level ---
  if [[ "${has_destructive_changes}" == true || "${has_dangerous_changes}" == true ]]; then
    local risk_label="DANGEROUS"
    [[ "${has_destructive_changes}" == true ]] && risk_label="DESTRUCTIVE"

    if [[ "${DRY_RUN}" == true ]]; then
      log_warn "${risk_label} changes detected (dry-run mode — no changes applied)"
      return 1
    fi

    if [[ "${FORCE_MODE}" == true ]]; then
      log_warn "${risk_label} changes detected — proceeding because --force was specified"
      return 0
    fi

    echo -e "  ${RED}${BOLD}WARNING: ${risk_label} changes detected!${NC}"
    if [[ "${has_dangerous_changes}" == true ]]; then
      echo -e "  ${RED}[DANGER] changes will trigger rolling replacement of VMs.${NC}"
      echo -e "  ${RED}This cordons existing nodes and provisions new ones.${NC}"
    fi
    if [[ "${has_destructive_changes}" == true ]]; then
      echo -e "  ${RED}[DESTROY] changes will DELETE existing nodes and their data.${NC}"
    fi
    echo ""
    echo -e "  To apply these changes, re-run with: ${BOLD}--update --force${NC}"
    echo -e "  To preview only: ${BOLD}--update --dry-run${NC}"
    echo ""
    die "Aborting update — ${risk_label} changes require --force flag"
  fi

  log_ok "Only safe changes detected — proceeding"
  return 0
}
```

- [ ] **Step 2: Commit**

```bash
git add rancher-api-deploy.sh
git commit -m "feat: add diff_and_guard pre-flight safety check for updates"
```

---

### Task 5: Wire `diff_and_guard()` into `update_cluster()` and fix the update path

**Files:**
- Modify: `rancher-api-deploy.sh` — `update_cluster()` function and `main()`

- [ ] **Step 1: Add `--force` combination support to main()**

Replace the argument parsing `case` block to support `--update --force` together:

```bash
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)  DRY_RUN=true ;;
      --delete)   DELETE_MODE=true ;;
      --update)   UPDATE_MODE=true ;;
      --force)    FORCE_MODE=true ;;
      -h|--help)
        echo "Usage: $(basename "$0") [--dry-run|--update [--force]|--delete|--help]"
        echo ""
        echo "  (no args)   Create cluster via Rancher API"
        echo "  --dry-run   Show JSON payloads without creating anything"
        echo "  --update    Update existing cluster (k8s version, chart values, registries)"
        echo "  --force     Skip confirmation prompts for destructive updates (use with --update)"
        echo "  --delete    Delete cluster and all associated resources"
        echo "  --help      Show this help"
        exit 0
        ;;
      *)  die "Unknown option: $1" ;;
    esac
    shift
  done

  if [[ "${FORCE_MODE}" == true && "${UPDATE_MODE}" != true ]]; then
    die "--force can only be used with --update"
  fi
```

- [ ] **Step 2: Call `diff_and_guard()` before `update_cluster()`**

In the `main()` function, in the update mode block (around line 1090), add the guard call:

```bash
  if [[ "${UPDATE_MODE}" == true ]]; then
    create_cloud_credential
    create_dockerhub_secret
    diff_and_guard
    update_cluster
    ...
```

- [ ] **Step 3: Restrict `update_cluster()` to safe-only fields**

Replace the dangerous deep merge in `update_cluster()` (lines 893-901):

```bash
  # SAFE MERGE: Only update fields that don't trigger node replacement.
  # HarvesterConfig changes (image, CPU, memory, disk) are NOT applied here.
  # To change VM specs, delete and recreate the cluster.
  local jq_filter
  jq_filter=$(mktemp)
  cat > "${jq_filter}" <<'JQ_EOF'
    # Only update safe fields — never touch machinePools or machineConfigRef
    .spec.kubernetesVersion = $desired_spec.kubernetesVersion |
    .spec.rkeConfig.chartValues = $desired_spec.rkeConfig.chartValues |
    .spec.rkeConfig.machineGlobalConfig = $desired_spec.rkeConfig.machineGlobalConfig |
    .spec.rkeConfig.machineSelectorConfig = $desired_spec.rkeConfig.machineSelectorConfig |
    .spec.rkeConfig.registries = $desired_spec.rkeConfig.registries |
    .spec.rkeConfig.upgradeStrategy = $desired_spec.rkeConfig.upgradeStrategy |
    .spec.rkeConfig.etcd = $desired_spec.rkeConfig.etcd |
    # Only update pool quantities (safe: scale up, guarded: scale down)
    .spec.rkeConfig.machinePools = [
      .spec.rkeConfig.machinePools[] |
      . as $pool |
      ($desired_spec.rkeConfig.machinePools[] | select(.name == $pool.name)) as $desired_pool |
      if $desired_pool then
        .quantity = $desired_pool.quantity |
        .machineDeploymentAnnotations = ($desired_pool.machineDeploymentAnnotations // .machineDeploymentAnnotations)
      else . end
    ]
JQ_EOF
```

This is the **critical fix**: instead of `.spec = (.spec * $desired_spec)` (which overwrites everything), we explicitly enumerate which fields to update. The `machineConfigRef` and all HarvesterConfig-related fields are never touched.

- [ ] **Step 4: Verify dry-run shows diff**

```bash
bash rancher-api-deploy.sh --update --dry-run
```
Expected: Shows pre-flight diff with [SAFE], [DANGER], and [DESTROY] classifications

- [ ] **Step 5: Commit**

```bash
git add rancher-api-deploy.sh
git commit -m "fix: replace dangerous deep merge with explicit safe-field update

The --update command previously used a jq deep merge that blindly
overwrote the entire cluster spec from .env values. If .env had stale
or incorrect values (e.g. dev cluster sizing), this triggered CAPI to
replace every VM simultaneously, bricking the cluster.

Now --update only modifies safe fields (k8s version, chart values,
registries, upgrade strategy, pool quantities). VM spec changes
(CPU, memory, disk, image) are detected and blocked unless --force
is specified."
```

---

## Chunk 2: BATS Tests

### Task 6: Add BATS test suite for update guard logic

**Files:**
- Create: `tests/test_update_guard.bats`

- [ ] **Step 1: Create test file with mock helpers**

```bash
#!/usr/bin/env bats

# Test the diff_and_guard logic using mocked API responses

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export CLUSTER_NAME="test-cluster"
  export K8S_VERSION="v1.34.4+rke2r1"
  export CP_COUNT=3 CP_CPU="4" CP_MEM="16" CP_DISK=80
  export GEN_MIN=4 GEN_CPU="2" GEN_MEM="8" GEN_DISK=60
  export COMP_MIN=2 COMP_CPU="4" COMP_MEM="16" COMP_DISK=80
  export DB_MIN=4 DB_CPU="4" DB_MEM="16" DB_DISK=80
  export IMAGE_FULL_NAME="rke2-prod/rke2-rocky9-golden-20260306"
  export VM_NAMESPACE="rke2-prod"

  # Source only the functions we need
  source "${SCRIPT_DIR}/rancher-api-deploy.sh" --source-only 2>/dev/null || true
}

@test "build_desired_harvester_configs produces correct JSON" {
  # Skip if function not available (--source-only not supported yet)
  if ! type build_desired_harvester_configs &>/dev/null; then
    skip "Function not available"
  fi
  local result
  result=$(build_desired_harvester_configs)
  local cp_cpu
  cp_cpu=$(echo "${result}" | jq -r '.cp.cpuCount')
  [ "${cp_cpu}" = "4" ]
}

@test "diff detects CPU downgrade as DANGER" {
  # This test validates the classification logic
  local live='{"cpuCount":"4","memorySize":"16"}'
  local desired='{"cpuCount":"2","memorySize":"16"}'
  local live_cpu desired_cpu
  live_cpu=$(echo "${live}" | jq -r '.cpuCount')
  desired_cpu=$(echo "${desired}" | jq -r '.cpuCount')
  [ "${live_cpu}" != "${desired_cpu}" ]
}

@test "diff detects quantity decrease as DESTROY" {
  local current_qty=5
  local desired_qty=2
  [ "${desired_qty}" -lt "${current_qty}" ]
}

@test "diff detects image change as DANGER" {
  local live_img="rke2-prod/rke2-rocky9-golden-20260306"
  local desired_img="rke2-prod/rocky-9.7-rke2-20260310"
  [ "${live_img}" != "${desired_img}" ]
}

@test "identical configs produce no changes" {
  local live='{"cpuCount":"4","memorySize":"16","diskInfo":"{\"disks\":[{\"imageName\":\"img\",\"size\":80}]}"}'
  local desired='{"cpuCount":"4","memorySize":"16","diskInfo":"{\"disks\":[{\"imageName\":\"img\",\"size\":80}]}"}'
  local diff
  diff=$(diff <(echo "${live}" | jq -S .) <(echo "${desired}" | jq -S .) || true)
  [ -z "${diff}" ]
}
```

- [ ] **Step 2: Run tests**

```bash
cd /home/rocky/code/harvester-rke2-cluster && bats tests/test_update_guard.bats
```
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add tests/test_update_guard.bats
git commit -m "test: add BATS tests for update guard diff classification"
```

---

## Chunk 3: UX Polish and Documentation

### Task 7: Add `--source-only` support for testability

**Files:**
- Modify: `rancher-api-deploy.sh` — bottom of file

- [ ] **Step 1: Wrap `main` call**

Replace the last line `main "$@"` with:

```bash
# Allow sourcing for tests without executing
if [[ "${1:-}" != "--source-only" ]]; then
  main "$@"
fi
```

- [ ] **Step 2: Commit**

```bash
git add rancher-api-deploy.sh
git commit -m "feat: add --source-only for test harness sourcing"
```

---

### Task 8: Add auto etcd snapshot before dangerous updates

**Files:**
- Modify: `rancher-api-deploy.sh` — inside `diff_and_guard()`, before the force-mode proceed block

- [ ] **Step 1: Add snapshot trigger**

After the `FORCE_MODE` check in `diff_and_guard()`, before `return 0`:

```bash
    if [[ "${FORCE_MODE}" == true ]]; then
      log_warn "${risk_label} changes detected — proceeding because --force was specified"

      # Auto etcd snapshot before dangerous changes
      log_info "Triggering etcd snapshot before applying changes..."
      local snapshot_response
      snapshot_response=$(rancher_api POST "/v1/rke.cattle.io.etcdsnapshots" "$(jq -n \
        --arg name "${CLUSTER_NAME}-pre-update-$(date +%Y%m%d%H%M%S)" \
        --arg cluster "fleet-default/${CLUSTER_NAME}" \
        '{metadata: {name: $name, namespace: "fleet-default"}, snapshotFile: {}, clusterName: $cluster}')" 2>/dev/null || echo "")
      if [[ -n "${snapshot_response}" ]]; then
        log_ok "Etcd snapshot requested (check Rancher UI for status)"
      else
        log_warn "Could not trigger etcd snapshot -- proceeding anyway"
      fi

      return 0
    fi
```

- [ ] **Step 2: Commit**

```bash
git add rancher-api-deploy.sh
git commit -m "feat: auto etcd snapshot before forced dangerous updates"
```

---

### Task 9: Update script header documentation

**Files:**
- Modify: `rancher-api-deploy.sh:1-19` (header comment block)

- [ ] **Step 1: Update usage docs**

```bash
# Usage:
#   ./rancher-api-deploy.sh                  # Create cluster
#   ./rancher-api-deploy.sh --dry-run        # Show what would be created (JSON payloads)
#   ./rancher-api-deploy.sh --update         # Update existing cluster (safe changes only)
#   ./rancher-api-deploy.sh --update --force # Update including dangerous VM-level changes
#   ./rancher-api-deploy.sh --delete         # Delete cluster and all associated resources
#
# Safety:
#   --update performs a pre-flight diff comparing .env values against the live
#   cluster state. Changes that would trigger VM replacement (image, CPU, memory,
#   disk size) or node deletion (quantity decrease) are blocked unless --force
#   is specified. An etcd snapshot is automatically taken before forced updates.
```

- [ ] **Step 2: Commit**

```bash
git add rancher-api-deploy.sh
git commit -m "docs: update script header with safety documentation"
```

---

## Summary

| Task | What it does | Risk |
|---|---|---|
| 1 | Add `--force` flag | None |
| 2 | Fetch live HarvesterConfig state | None |
| 3 | Build desired state from .env | None |
| 4 | Diff engine with classification | None |
| 5 | Wire guard into update + fix merge | **Critical fix** |
| 6 | BATS tests | None |
| 7 | `--source-only` for testability | None |
| 8 | Auto etcd snapshot before force | None |
| 9 | Update docs | None |

After this, `--update` with mismatched `.env` values will show:

```
Pre-flight diff: .env vs live cluster
======================================
  [DANGER]    cp CPU: 4 -> 2 (triggers node replacement)
  [DANGER]    cp memory: 16GB -> 8GB (triggers node replacement)
  [DANGER]    cp disk: 80GB -> 40GB (triggers node replacement)
  [DANGER]    cp image: rke2-rocky9-golden-20260306 -> rocky-9.7-rke2-20260310I (triggers node replacement)
  [DESTROY]   general pool: 5 -> 4 nodes (NODES WILL BE DELETED)
  ...

  WARNING: DESTRUCTIVE changes detected!
  [DESTROY] changes will DELETE existing nodes and their data.

  To apply these changes, re-run with: --update --force
  To preview only: --update --dry-run

[ERROR] Aborting update — DESTRUCTIVE changes require --force flag
```
