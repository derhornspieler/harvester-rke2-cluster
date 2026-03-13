# Deployment Method Separation Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development
> (if subagents available) or superpowers:executing-plans to implement this plan.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize the repository into `deploy-api/` and `deploy-terraform/`
directories, default operator deployment to OFF, and parameterize the Fleet repo's
cluster-autoscaler scale-down values.

**Architecture:** Two self-contained deployment method directories (`deploy-api/`,
`deploy-terraform/`) with shared resources at root (`operators/`, `prepare.sh`,
`nuke-cluster.sh`). Each method's config file lives inside its own directory.
All scripts use `REPO_ROOT` for cross-directory references.

**Tech Stack:** Bash, Terraform (HCL), GitHub Actions YAML, envsubst (Fleet repo)

**Spec:** `docs/superpowers/specs/2026-03-13-deployment-method-separation-design.md`

---

## Chunk 1: Directory Creation and File Moves

### Task 1: Create directory structure and move Terraform files

**Files:**
- Create: `deploy-api/` (directory)
- Create: `deploy-terraform/` (directory)
- Move: `terraform/*.tf` → `deploy-terraform/*.tf`
- Move: `terraform/terraform.sh` → `deploy-terraform/terraform.sh`
- Move: `terraform/terraform.tfvars.example` → `deploy-terraform/terraform.tfvars.example`
- Move: `terraform/.terraform.lock.hcl` → `deploy-terraform/.terraform.lock.hcl`

- [ ] **Step 1: Create the two deployment directories**

```bash
mkdir -p deploy-api deploy-terraform
```

- [ ] **Step 2: Move Terraform files to deploy-terraform/**

```bash
git mv terraform/cloud_credential.tf deploy-terraform/
git mv terraform/cluster.tf deploy-terraform/
git mv terraform/efi.tf deploy-terraform/
git mv terraform/image.tf deploy-terraform/
git mv terraform/machine_config.tf deploy-terraform/
git mv terraform/operators.tf deploy-terraform/
git mv terraform/outputs.tf deploy-terraform/
git mv terraform/providers.tf deploy-terraform/
git mv terraform/variables.tf deploy-terraform/
git mv terraform/versions.tf deploy-terraform/
git mv terraform/terraform.sh deploy-terraform/
git mv terraform/terraform.tfvars.example deploy-terraform/
git mv terraform/.terraform.lock.hcl deploy-terraform/
```

- [ ] **Step 3: Move destroy-cluster.sh to deploy-terraform/**

```bash
git mv destroy-cluster.sh deploy-terraform/
```

- [ ] **Step 4: Remove the now-empty terraform/ directory**

```bash
rmdir terraform 2>/dev/null || true
```

- [ ] **Step 5: Verify the move**

```bash
ls deploy-terraform/
# Expected: cloud_credential.tf cluster.tf efi.tf image.tf machine_config.tf
#           operators.tf outputs.tf providers.tf variables.tf versions.tf
#           terraform.sh terraform.tfvars.example .terraform.lock.hcl
#           destroy-cluster.sh
```

- [ ] **Step 6: Commit the file moves**

```bash
git add deploy-terraform/
git commit -m "refactor: move Terraform files to deploy-terraform/

Separate Terraform deployment method into its own directory as part of
the deployment method separation initiative.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Task 2: Move Rancher API files to deploy-api/

**Files:**
- Move: `rancher-api-deploy.sh` → `deploy-api/rancher-api-deploy.sh`
- Move: `.env.example` → `deploy-api/.env.example`

- [ ] **Step 1: Move rancher-api-deploy.sh and .env.example**

```bash
git mv rancher-api-deploy.sh deploy-api/
git mv .env.example deploy-api/
```

- [ ] **Step 2: Verify the move**

```bash
ls deploy-api/
# Expected: rancher-api-deploy.sh .env.example
```

- [ ] **Step 3: Commit**

```bash
git add deploy-api/
git commit -m "refactor: move Rancher API files to deploy-api/

Separate Rancher API deployment method into its own directory.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Chunk 2: Update Script Paths

### Task 3: Update deploy-api/rancher-api-deploy.sh paths

**Files:**
- Modify: `deploy-api/rancher-api-deploy.sh:44-60` (config loading section)

The script currently sources `.env` from `${SCRIPT_DIR}/.env` (line 45).
Since the script is now in `deploy-api/`, `SCRIPT_DIR` already resolves
to `deploy-api/` — so `.env` sourcing works as-is. But credential file
paths in `.env.example` reference `./private-ca.pem` etc. which are
relative to where the user runs the script from, not `SCRIPT_DIR`.

- [ ] **Step 1: Add REPO_ROOT to rancher-api-deploy.sh**

After the existing `SCRIPT_DIR` line, add a `REPO_ROOT` variable.
Find the line:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

Add below it:

```bash
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
```

- [ ] **Step 2: Update rancher-api-deploy.sh to resolve credential paths via REPO_ROOT**

In the `load_config()` function, after sourcing `.env`, resolve credential file
paths relative to `REPO_ROOT` if they are relative paths. This ensures paths like
`../private-ca.pem` in `.env` resolve correctly regardless of the user's working
directory. Add after the `source "${env_file}"` line:

```bash
# Resolve relative credential paths against REPO_ROOT
[[ "${PRIVATE_CA_PEM_FILE}" != /* ]] && PRIVATE_CA_PEM_FILE="${REPO_ROOT}/${PRIVATE_CA_PEM_FILE#../}"
[[ "${CLOUD_PROVIDER_KUBECONFIG_FILE}" != /* ]] && CLOUD_PROVIDER_KUBECONFIG_FILE="${REPO_ROOT}/${CLOUD_PROVIDER_KUBECONFIG_FILE#../}"
[[ "${CLOUD_CRED_KUBECONFIG_FILE}" != /* ]] && CLOUD_CRED_KUBECONFIG_FILE="${REPO_ROOT}/${CLOUD_CRED_KUBECONFIG_FILE#../}"
```

- [ ] **Step 3: Update .env.example credential paths**

In `deploy-api/.env.example`, update the default credential file paths to reference
files at the project root (one level up from deploy-api/):

```bash
PRIVATE_CA_PEM_FILE="../private-ca.pem"
CLOUD_PROVIDER_KUBECONFIG_FILE="../harvester-cloud-provider-kubeconfig"
CLOUD_CRED_KUBECONFIG_FILE="../kubeconfig-harvester-cloud-cred.yaml"
```

- [ ] **Step 4: Run ShellCheck to verify no new warnings**

```bash
shellcheck deploy-api/rancher-api-deploy.sh
# Expected: no new warnings (existing warnings are acceptable)
```

- [ ] **Step 5: Commit**

```bash
git add deploy-api/rancher-api-deploy.sh deploy-api/.env.example
git commit -m "refactor: update credential file paths for deploy-api/ layout

Add REPO_ROOT for resolving credential file paths relative to project
root. Credential files remain at root; .env.example updated accordingly.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Task 4: Update deploy-terraform/terraform.sh paths

**Files:**
- Modify: `deploy-terraform/terraform.sh:18` (SCRIPT_DIR)
- Modify: `deploy-terraform/terraform.sh` (all references to `../operators/`, kubeconfig paths)

The script uses `SCRIPT_DIR` extensively. Since it moved from `terraform/` to
`deploy-terraform/`, the relative position to root is the same (one level up).
References to `operators/` and kubeconfigs need `REPO_ROOT`.

- [ ] **Step 1: Add REPO_ROOT after SCRIPT_DIR (line 18)**

After:
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

Add:
```bash
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
```

- [ ] **Step 2: Update HARVESTER_KUBECONFIG reference**

Search for `HARVESTER_KUBECONFIG` or `kubeconfig-harvester.yaml` in terraform.sh.
The variable is set around line 19. Update to use `REPO_ROOT`:

```bash
HARVESTER_KUBECONFIG="${REPO_ROOT}/kubeconfig-harvester.yaml"
```

- [ ] **Step 3: Update any other root-relative file references**

Search terraform.sh for references to files at root that use
`${SCRIPT_DIR}/../` or relative paths without REPO_ROOT. Common ones:
- `SECRET_FILENAMES` array (credential file paths) — update to use `${REPO_ROOT}/`
- `.kubeconfig-rke2-operators` — update to `${REPO_ROOT}/.kubeconfig-rke2-operators`
- Any `kubeconfig-*.yaml` references — update to `${REPO_ROOT}/kubeconfig-*.yaml`

- [ ] **Step 4: Verify terraform.tfvars references work as-is**

The `_get_tfvar_value` and `_get_tfvar_heredoc` functions read from
`terraform.tfvars` in the current directory. Since `terraform.sh` runs
from `deploy-terraform/` and `terraform.tfvars` is now generated there,
these should work as-is. Verify by checking that the `awk` commands
reference the file without a path prefix, using the current directory.

- [ ] **Step 4: Run ShellCheck**

```bash
shellcheck deploy-terraform/terraform.sh
```

- [ ] **Step 5: Commit**

```bash
git add deploy-terraform/terraform.sh
git commit -m "fix: update terraform.sh paths for deploy-terraform/ layout

Add REPO_ROOT for cross-directory references to kubeconfigs and
operators at project root.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Task 5: Update deploy-terraform/operators.tf paths

**Files:**
- Modify: `deploy-terraform/operators.tf` (all `operators/` path references)

All references to `operators/` paths (templates, manifests, images,
push-images.sh) need to become `../operators/` since the .tf files
moved one directory deeper.

- [ ] **Step 1: Update all operators/ references to ../operators/**

The `.tf` files previously lived in `terraform/` (one level deep) and referenced
`operators/` as a sibling via `"${path.module}/../operators/"` or just `"operators/"`.
Now they live in `deploy-terraform/` — same depth. Search `operators.tf` for every
occurrence of `operators/` (including `${path.module}` prefixed) and ensure they
resolve to `../operators/` from the new location.

Use `grep -n 'operators/' deploy-terraform/operators.tf` to find all occurrences
(expect ~16 hits). For each, ensure the path resolves correctly. Common patterns:
- `"${path.module}/../operators/"` — already correct (path.module = deploy-terraform)
- `"operators/"` without path.module — change to `"../operators/"`

- [ ] **Step 2: Run terraform fmt**

```bash
cd deploy-terraform && terraform fmt && cd ..
```

- [ ] **Step 3: Run terraform validate (no backend)**

```bash
cd deploy-terraform && terraform init -backend=false && terraform validate && cd ..
```

- [ ] **Step 4: Commit**

```bash
git add deploy-terraform/operators.tf
git commit -m "fix: update operator paths in operators.tf for new directory layout

All operator references now use ../operators/ since .tf files moved
from terraform/ to deploy-terraform/.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Task 6: Update deploy-terraform/destroy-cluster.sh

**Files:**
- Modify: `deploy-terraform/destroy-cluster.sh:14`

The script uses `${SCRIPT_DIR}/terraform.sh` which already works because
both files are now in the same directory. Verify no changes needed.

- [ ] **Step 1: Verify destroy-cluster.sh works with new layout**

Read the script — it uses `${SCRIPT_DIR}/terraform.sh` (line 14).
Since both moved to `deploy-terraform/`, this should work as-is.

```bash
head -15 deploy-terraform/destroy-cluster.sh
# Verify: exec "${SCRIPT_DIR}/terraform.sh" destroy "$@"
```

- [ ] **Step 2: No changes needed — skip commit**

### Task 7: Update prepare.sh for new config locations

**Files:**
- Modify: `prepare.sh:351-352` (tfvars paths)
- Modify: `prepare.sh:376-377` (env paths)
- Modify: `prepare.sh:407-415` (summary file list)
- Modify: `prepare.sh:420-436` (next steps text)
- Modify: `prepare.sh:462-471` (refresh summary paths)
- Modify: `prepare.sh:484-494` (refresh mode config detection)
- Modify: `prepare.sh:571-577` (refresh tfvars update)
- Modify: `prepare.sh:581-588` (refresh env update)
- Modify: `prepare.sh:660` (refresh mode detection)

- [ ] **Step 1: Update generate_tfvars() paths**

Change line 351:
```bash
local source="${SCRIPT_DIR}/terraform/terraform.tfvars.example"
```
To:
```bash
local source="${SCRIPT_DIR}/deploy-terraform/terraform.tfvars.example"
```

Change line 352:
```bash
local output="${SCRIPT_DIR}/terraform.tfvars"
```
To:
```bash
local output="${SCRIPT_DIR}/deploy-terraform/terraform.tfvars"
```

- [ ] **Step 2: Update generate_env() paths**

Change line 376:
```bash
local source="${SCRIPT_DIR}/.env.example"
```
To:
```bash
local source="${SCRIPT_DIR}/deploy-api/.env.example"
```

Change line 377:
```bash
local output="${SCRIPT_DIR}/.env"
```
To:
```bash
local output="${SCRIPT_DIR}/deploy-api/.env"
```

- [ ] **Step 3: Update print_summary() file list and next steps**

Update lines 408-409 to check the new locations:
```bash
  for f in kubeconfig-harvester.yaml kubeconfig-harvester-cloud-cred.yaml \
           harvester-cloud-provider-kubeconfig deploy-api/.env deploy-terraform/terraform.tfvars; do
```

Update lines 420-436 next steps text:
```bash
  echo -e "  ${BOLD}In deploy-api/.env (for rancher-api-deploy.sh):${NC}"
  # ... (keep existing manual edit list)
  echo -e "  ${BOLD}In deploy-terraform/terraform.tfvars (for Terraform, if used):${NC}"
  # ...
  echo -e "${BOLD}Next steps:${NC}"
  echo "  Option A (recommended): ./deploy-api/rancher-api-deploy.sh --dry-run"
  echo "  Option B (Terraform):   cd deploy-terraform && terraform init && terraform plan"
```

- [ ] **Step 4: Update refresh_credentials() config detection**

Update lines 484-494 to look for configs in new locations:
```bash
  if [[ -f "${SCRIPT_DIR}/deploy-api/.env" ]]; then
    log_info "Reading existing settings from deploy-api/.env..."
    source "${SCRIPT_DIR}/deploy-api/.env"
  elif [[ -f "${SCRIPT_DIR}/deploy-terraform/terraform.tfvars" ]]; then
    log_info "Reading existing settings from deploy-terraform/terraform.tfvars (no .env found)..."
```

- [ ] **Step 5: Update refresh credential file updates**

Update lines 571-577 (tfvars in-place update):
```bash
  if [[ -f "${SCRIPT_DIR}/deploy-terraform/terraform.tfvars" ]]; then
    log_info "Updating credentials in deploy-terraform/terraform.tfvars..."
    sed -i \
      -e "s|rancher_token.*=.*|rancher_token = \"${API_TOKEN}\"|" \
      -e "s|harvester_cloud_credential_name.*=.*|harvester_cloud_credential_name = \"${cloud_cred_name}\"|" \
      "${SCRIPT_DIR}/deploy-terraform/terraform.tfvars"
```

Update lines 581-588 (.env in-place update):
```bash
  if [[ -f "${SCRIPT_DIR}/deploy-api/.env" ]]; then
    log_info "Updating credentials in deploy-api/.env..."
    sed -i \
      -e "s|^RANCHER_TOKEN=.*|RANCHER_TOKEN=\"${API_TOKEN}\"|" \
      -e "s|^CLOUD_CRED_NAME=.*|CLOUD_CRED_NAME=\"${cloud_cred_name}\"|" \
      "${SCRIPT_DIR}/deploy-api/.env"
```

- [ ] **Step 6: Update refresh mode detection (line 660)**

```bash
    if [[ -f "${SCRIPT_DIR}/deploy-api/.env" || -f "${SCRIPT_DIR}/deploy-terraform/terraform.tfvars" ]]; then
```

- [ ] **Step 7: Update print_refresh_summary()**

Update lines 462-463 to check new paths:
```bash
  if [[ -f "${SCRIPT_DIR}/deploy-terraform/terraform.tfvars" ]]; then
    echo -e "  ${GREEN}+${NC} deploy-terraform/terraform.tfvars  (rancher_token, harvester_cloud_credential_name)"
  fi
  if [[ -f "${SCRIPT_DIR}/deploy-api/.env" ]]; then
    echo -e "  ${GREEN}+${NC} deploy-api/.env              (RANCHER_TOKEN, CLOUD_CRED_NAME)"
  fi
```

Update next steps:
```bash
  echo "  Option A (recommended): ./deploy-api/rancher-api-deploy.sh --dry-run"
  echo "  Option B (Terraform):   cd deploy-terraform && terraform init && terraform plan"
```

- [ ] **Step 8: Add old config detection with migration warning**

At the start of `full_setup()` (after line 600), add:

```bash
  # Warn if old-location config files exist
  if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    log_warn "Found .env at old location (project root)."
    log_warn "Config now lives in deploy-api/.env — please re-run prepare.sh."
  fi
  if [[ -f "${SCRIPT_DIR}/terraform.tfvars" ]]; then
    log_warn "Found terraform.tfvars at old location (project root)."
    log_warn "Config now lives in deploy-terraform/terraform.tfvars — please re-run prepare.sh."
  fi
```

- [ ] **Step 9: Run ShellCheck**

```bash
shellcheck prepare.sh
```

- [ ] **Step 10: Commit**

```bash
git add prepare.sh
git commit -m "refactor: update prepare.sh for deploy-api/ and deploy-terraform/ layout

Config files now written to method-specific directories:
- .env → deploy-api/.env
- terraform.tfvars → deploy-terraform/terraform.tfvars

Includes migration warning for old-location config files.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Task 8: Update nuke-cluster.sh

**Files:**
- Modify: `nuke-cluster.sh:109,114`

- [ ] **Step 1: Update .env source path**

Change line 109:
```bash
if [[ ! -f "${SCRIPT_DIR}/.env" ]]; then
```
To:
```bash
if [[ ! -f "${SCRIPT_DIR}/deploy-api/.env" ]]; then
```

Change line 114:
```bash
source "${SCRIPT_DIR}/.env"
```
To:
```bash
source "${SCRIPT_DIR}/deploy-api/.env"
```

- [ ] **Step 2: Run ShellCheck**

```bash
shellcheck nuke-cluster.sh
```

- [ ] **Step 3: Commit**

```bash
git add nuke-cluster.sh
git commit -m "fix: update nuke-cluster.sh to read .env from deploy-api/

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Chunk 3: Create deploy-api/destroy-cluster.sh and Update .gitignore

### Task 9: Create deploy-api/destroy-cluster.sh

**Files:**
- Create: `deploy-api/destroy-cluster.sh`

- [ ] **Step 1: Write the destroy wrapper script**

```bash
#!/usr/bin/env bash
# destroy-cluster.sh — Delete the RKE2 cluster via Rancher API
#
# This is a convenience wrapper around rancher-api-deploy.sh --delete.
#
# Usage:
#   ./destroy-cluster.sh              # Interactive (prompts for confirmation)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/rancher-api-deploy.sh" --delete "$@"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x deploy-api/destroy-cluster.sh
```

- [ ] **Step 3: Run ShellCheck**

```bash
shellcheck deploy-api/destroy-cluster.sh
```

- [ ] **Step 4: Commit**

```bash
git add deploy-api/destroy-cluster.sh
git commit -m "feat: add destroy-cluster.sh wrapper for Rancher API method

Provides parity with deploy-terraform/destroy-cluster.sh.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Task 10: Update .gitignore for new paths

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Update .gitignore**

Add new path entries and keep backwards-compatible root entries:

```gitignore
# Terraform state and providers
.terraform/
deploy-terraform/.terraform/
.terraform.lock.hcl
*.tfstate*
*.tfplan
tfplan*
terraform.tfvars
deploy-terraform/terraform.tfvars

# Shell script environment config
.env
deploy-api/.env
private-ca.pem
```

The root-level entries (`.env`, `terraform.tfvars`) can remain for safety
in case someone creates config at the old location.

- [ ] **Step 2: Verify no secrets will be committed**

```bash
git status
# Verify: no .env, terraform.tfvars, kubeconfig, or credential files staged
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: update .gitignore for deploy-api/ and deploy-terraform/ layout

Add gitignore entries for config files in new method-specific directories.
Keep root-level entries for backwards compatibility.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Chunk 4: Default Operator Deployment to OFF

### Task 11: Change deploy_operators default to false in Terraform

**Files:**
- Modify: `deploy-terraform/variables.tf:399`
- Modify: `deploy-terraform/variables.tf:405,411,423`

- [ ] **Step 1: Change deploy_operators default**

In `deploy-terraform/variables.tf`, change line 399:
```hcl
  default     = true
```
To:
```hcl
  default     = false
```

- [ ] **Step 2: Change deploy_cluster_autoscaler default**

Line 405:
```hcl
  default     = true
```
To:
```hcl
  default     = false
```

- [ ] **Step 3: Change deploy_cnpg default**

Line 411:
```hcl
  default     = true
```
To:
```hcl
  default     = false
```

- [ ] **Step 4: Change deploy_redis_operator default**

Line 423:
```hcl
  default     = true
```
To:
```hcl
  default     = false
```

- [ ] **Step 5: Run terraform validate**

```bash
cd deploy-terraform && terraform init -backend=false && terraform validate && cd ..
```

- [ ] **Step 6: Commit**

```bash
git add deploy-terraform/variables.tf
git commit -m "refactor: default operator deployment to OFF in Terraform

Production uses Fleet GitOps for operator lifecycle. Built-in operator
deployment is now opt-in via deploy_operators = true in terraform.tfvars.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Task 12: Add DEPLOY_OPERATORS=false to deploy-api/.env.example

**Files:**
- Modify: `deploy-api/.env.example`

- [ ] **Step 1: Add operator deployment variables**

Add the following section to `deploy-api/.env.example` (after the existing
node pool configuration section):

```bash
# =============================================================================
# Operator Deployment (opt-in — production uses Fleet GitOps)
# =============================================================================
# Set to true to deploy operators as part of cluster creation.
# When false (default), only the cluster is created — operators are managed
# externally (e.g., via Fleet GitOps in harvester-rke2-svcs).
DEPLOY_OPERATORS=false

# Cluster autoscaler version (must match Kubernetes minor version)
CLUSTER_AUTOSCALER_VERSION="v1.34.3"

# Scale-down behavior (conservative defaults)
AUTOSCALER_SCALE_DOWN_UNNEEDED_TIME="30m0s"
AUTOSCALER_SCALE_DOWN_DELAY_AFTER_ADD="15m0s"
AUTOSCALER_SCALE_DOWN_DELAY_AFTER_DELETE="30m0s"
AUTOSCALER_SCALE_DOWN_UTILIZATION_THRESHOLD="0.5"
```

- [ ] **Step 2: Commit**

```bash
git add deploy-api/.env.example
git commit -m "feat: add operator deployment config to .env.example (default OFF)

Adds DEPLOY_OPERATORS toggle and cluster-autoscaler scale-down params.
Default is OFF since production uses Fleet GitOps for operator lifecycle.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

**Note — Deferred:** The actual operator deployment logic for
`rancher-api-deploy.sh` (deploying cluster-autoscaler and storage-autoscaler
when `DEPLOY_OPERATORS=true`) is **deferred to a follow-up task**. This plan
adds the `.env` configuration variables and toggle, but the shell code that
reads them and deploys operators will be implemented separately. The
acceptance criteria for `DEPLOY_OPERATORS=true` actually deploying operators
is not met by this plan — only the config scaffolding is in place.

Database operators (CNPG, MariaDB, Redis) are Fleet-only and will not be
deployed by `deploy-api/` even when the operator deployment code is added.

---

## Chunk 5: CI Pipeline Updates

### Task 13: Update GitHub Actions CI for new directory layout

**Files:**
- Modify: `.github/workflows/ci.yml:61,78-82,99-103,192`

- [ ] **Step 1: Update terraform-fmt**

The `terraform fmt -check -recursive -diff` (line 61) runs from repo root
and finds `.tf` anywhere. This still works. No change needed.

- [ ] **Step 2: Update terraform-validate working directory**

Lines 78-82 currently run `terraform init` and `terraform validate` from
repo root. Add `working-directory`:

```yaml
      - name: Initialize (no backend)
        working-directory: deploy-terraform
        run: terraform init -backend=false

      - name: Validate configuration
        working-directory: deploy-terraform
        run: terraform validate
```

- [ ] **Step 3: Update tflint working directory**

Lines 99-103 currently run tflint from root. Add `working-directory`:

```yaml
      - name: Initialize TFLint
        working-directory: deploy-terraform
        run: tflint --init

      - name: Run TFLint
        working-directory: deploy-terraform
        run: tflint --format compact
```

- [ ] **Step 4: Update checkov directory**

Line 192 currently scans `.` for terraform. Update:

```yaml
          directory: deploy-terraform
```

- [ ] **Step 5: Verify shellcheck still finds all scripts**

The shellcheck job (lines 116-134) uses `find . -name '*.sh'` which will
automatically find scripts in `deploy-api/` and `deploy-terraform/`.
No change needed.

- [ ] **Step 6: Move .tflint.hcl to deploy-terraform/**

TFLint reads its config from the working directory. Since we changed
`working-directory` to `deploy-terraform`, the config file needs to move:

```bash
git mv .tflint.hcl deploy-terraform/
```

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/ci.yml deploy-terraform/.tflint.hcl
git commit -m "fix: update CI pipeline for deploy-terraform/ directory layout

Terraform validate, tflint, and checkov now run from deploy-terraform/.
ShellCheck auto-discovers scripts in new directories.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

- [ ] **Step 8: Verify CI passes (push to branch and check)**

```bash
git push origin HEAD
# Monitor: https://github.com/derhornspieler/harvester-rke2-cluster/actions
# Expected: all 8 jobs pass
```

---

## Chunk 6: Fleet Repo Changes (harvester-rke2-svcs)

### Task 14: Parameterize cluster-autoscaler scale-down values in Fleet repo

**Files (all in /home/rocky/data/harvester-rke2-svcs):**
- Modify: `fleet-gitops/.env.rke2-prod:126` (add after IMAGE_CLUSTER_AUTOSCALER)
- Modify: `fleet-gitops/.env.example:235` (add after IMAGE_CLUSTER_AUTOSCALER)
- Modify: `fleet-gitops/scripts/lib/env-defaults.sh:206` (add to ENVSUBST_VARS)
- Modify: `fleet-gitops/00-operators/cluster-autoscaler/manifests/deployment.yaml:63-66`

- [ ] **Step 1: Add autoscaler variables to .env.rke2-prod**

After line 126 (`IMAGE_CLUSTER_AUTOSCALER=...`), add:

```bash
# Cluster autoscaler scale-down behavior (conservative defaults)
AUTOSCALER_SCALE_DOWN_DELAY_AFTER_ADD=15m0s
AUTOSCALER_SCALE_DOWN_DELAY_AFTER_DELETE=30m0s
AUTOSCALER_SCALE_DOWN_UNNEEDED_TIME=30m0s
AUTOSCALER_SCALE_DOWN_UTILIZATION_THRESHOLD=0.5
```

- [ ] **Step 2: Add autoscaler variables to .env.example**

After line 235 (`IMAGE_CLUSTER_AUTOSCALER=...`), add the same 4 variables
with the same conservative defaults.

- [ ] **Step 3: Add variables to ENVSUBST_VARS allowlist**

In `fleet-gitops/scripts/lib/env-defaults.sh`, add the 4 new variables
to the `ENVSUBST_VARS` string (around line 206, near the IMAGE_* vars):

```bash
${AUTOSCALER_SCALE_DOWN_DELAY_AFTER_ADD} ${AUTOSCALER_SCALE_DOWN_DELAY_AFTER_DELETE} \
${AUTOSCALER_SCALE_DOWN_UNNEEDED_TIME} ${AUTOSCALER_SCALE_DOWN_UTILIZATION_THRESHOLD} \
```

- [ ] **Step 4: Update deployment.yaml to use variables**

In `fleet-gitops/00-operators/cluster-autoscaler/manifests/deployment.yaml`,
replace lines 63-66:

```yaml
            - --scale-down-delay-after-add=10m
            - --scale-down-delay-after-delete=1m
            - --scale-down-unneeded-time=10m
            - --scale-down-utilization-threshold=0.5
```

With:

```yaml
            - --scale-down-delay-after-add=${AUTOSCALER_SCALE_DOWN_DELAY_AFTER_ADD}
            - --scale-down-delay-after-delete=${AUTOSCALER_SCALE_DOWN_DELAY_AFTER_DELETE}
            - --scale-down-unneeded-time=${AUTOSCALER_SCALE_DOWN_UNNEEDED_TIME}
            - --scale-down-utilization-threshold=${AUTOSCALER_SCALE_DOWN_UTILIZATION_THRESHOLD}
```

- [ ] **Step 5: Verify rendering works**

```bash
cd /home/rocky/data/harvester-rke2-svcs/fleet-gitops
source .env.rke2-prod
source scripts/lib/env-defaults.sh
# Check that variables are in ENVSUBST_VARS:
echo "${ENVSUBST_VARS}" | tr ' ' '\n' | grep AUTOSCALER
# Expected: 4 lines with ${AUTOSCALER_SCALE_DOWN_*}
```

- [ ] **Step 6: Commit to harvester-rke2-svcs repo**

```bash
cd /home/rocky/data/harvester-rke2-svcs
git add fleet-gitops/.env.rke2-prod \
        fleet-gitops/.env.example \
        fleet-gitops/scripts/lib/env-defaults.sh \
        fleet-gitops/00-operators/cluster-autoscaler/manifests/deployment.yaml
git commit -m "refactor: parameterize cluster-autoscaler scale-down values

Replace hardcoded scale-down args with envsubst variables.
Align to conservative defaults matching harvester-rke2-cluster repo:
- scale-down-delay-after-add: 10m → 15m0s
- scale-down-delay-after-delete: 1m → 30m0s
- scale-down-unneeded-time: 10m → 30m0s
- scale-down-utilization-threshold: 0.5 (unchanged)

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Chunk 7: Documentation and Security Verification

### Task 15: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/operations.md`

Dispatch the **tech-doc-keeper** agent with the following context:

> The repository has been reorganized. Two deployment methods are now in separate
> directories: `deploy-api/` (Rancher API) and `deploy-terraform/` (Terraform).
> Shared resources remain at root: `operators/`, `prepare.sh`, `nuke-cluster.sh`.
> Operator deployment defaults to OFF in both methods (production uses Fleet GitOps).
> The spec is at `docs/superpowers/specs/2026-03-13-deployment-method-separation-design.md`.
>
> Update:
> 1. `README.md` — new directory structure, updated quickstart for both methods
> 2. `docs/architecture.md` — reflect two deployment paths
> 3. `docs/operations.md` — updated script paths, operator deployment opt-in
> 4. Wiki pages if they reference old paths

- [ ] **Step 1: Dispatch tech-doc-keeper agent**
- [ ] **Step 2: Review documentation changes**
- [ ] **Step 3: Commit documentation updates**

### Task 16: Security audit

Dispatch the **security-sentinel** agent with the following context:

> The repository has been reorganized into `deploy-api/` and `deploy-terraform/`.
> Verify:
> 1. `.gitignore` covers `deploy-api/.env`, `deploy-terraform/terraform.tfvars`,
>    `deploy-terraform/.terraform/`, and all credential files
> 2. No secrets (API tokens, passwords, kubeconfigs) are tracked in git after the move
> 3. The new `deploy-api/destroy-cluster.sh` handles credentials safely
> 4. `deploy-api/.env.example` does not contain real credentials
> 5. The Fleet repo change (envsubst for autoscaler params) doesn't expose secrets
> 6. Run `git status` and `git diff --cached` to verify nothing sensitive is staged

- [ ] **Step 1: Dispatch security-sentinel agent**
- [ ] **Step 2: Address any findings**
- [ ] **Step 3: Final commit if security fixes needed**

### Task 17: Final verification and cleanup

- [ ] **Step 1: Run full CI lint suite locally**

```bash
# ShellCheck
find . -name '*.sh' -not -path './.terraform/*' -not -path './.git/*' \
  -not -path './.claude/*' | xargs shellcheck --severity=warning

# Terraform
cd deploy-terraform && terraform fmt -check && terraform init -backend=false \
  && terraform validate && cd ..

# yamllint
yamllint -c .yamllint.yml $(find . -type f \( -name '*.yaml' -o -name '*.yml' \) \
  -not -name '*.tftpl' -not -path './.terraform/*' -not -path './.git/*' \
  -not -path './.claude/*' | sort)
```

- [ ] **Step 2: Verify old terraform/ directory is gone**

```bash
test ! -d terraform && echo "OK: terraform/ removed" || echo "FAIL: terraform/ still exists"
```

- [ ] **Step 3: Verify directory structure matches spec**

```bash
echo "=== deploy-api/ ===" && ls -la deploy-api/
echo "=== deploy-terraform/ ===" && ls -la deploy-terraform/
echo "=== operators/ ===" && ls -d operators/*/
echo "=== root scripts ===" && ls prepare.sh nuke-cluster.sh
```

- [ ] **Step 4: Delete old root .terraform/ if present**

```bash
rm -rf .terraform/
```

- [ ] **Step 5: Final commit (cleanup, if needed)**

```bash
git status
# Review any remaining changes. Only stage specific files:
# git add <specific-files>
# git commit -m "chore: clean up old terraform/ artifacts after reorganization
#
# Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

Do NOT use `git add -A` — review and stage files individually to avoid
committing secrets or unintended files.
