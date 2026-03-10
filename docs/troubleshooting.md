# RKE2 Cluster Deployment — Troubleshooting & Diagnostics Guide

This guide covers common issues encountered during RKE2 cluster deployment on Harvester, diagnostic procedures, and remediation steps. It includes Mermaid decision trees for diagnosis and restoration procedures for failed deploys.

## Primary Deployment Tool

As of commit `eed0815`, **rancher-api-deploy.sh** is the primary cluster lifecycle tool. This guide documents both `rancher-api-deploy.sh` operations and Terraform reference material (preserved in `terraform/` subdirectory).

| Tool | When to Use |
|------|-----------|
| rancher-api-deploy.sh | Default for all new deployments, CI/CD, scripting |
| Terraform (terraform/) | Reference implementation, state-managed deployments (not actively developed) |

For `rancher-api-deploy.sh` failures, check stderr and try `--dry-run` to inspect generated payloads. Terraform issues refer to section 2 below.

## Table of Contents

1. [Deployment Failures](#1-deployment-failures)
2. [Terraform State Issues](#2-terraform-state-issues) (reference)
3. [Cluster Health Issues](#3-cluster-health-issues)
4. [Operator Deployment Issues](#4-operator-deployment-issues)
5. [Cleanup & Destroy Procedures](#5-cleanup--destroy-procedures)
6. [Diagnostic Cheat Sheet](#6-diagnostic-cheat-sheet)

---

## 1. Deployment Failures

### Symptom: Rancher shows "error applying plan" on bootstrap node

**Quick Check**
- [ ] SSH into bootstrap node and check `rancher-system-agent.service` status: `systemctl status rancher-system-agent`
- [ ] Check system agent logs: `journalctl -u rancher-system-agent -n 50`
- [ ] Verify bootstrap node can reach Rancher: `curl -k https://<RANCHER_URL>`
- [ ] Check containerd mirrors are working: `crictl pull <HARBOR_FQDN>/library/alpine:latest`

**Decision Tree**
```mermaid
flowchart TD
    A["Bootstrap node shows<br/>error applying plan"] --> B{"Check system-agent<br/>status"}
    B -->|Running| C{"Can reach<br/>Rancher URL?"}
    B -->|Failed/Stopped| D["Restart service:<br/>systemctl restart rancher-system-agent"]
    C -->|No| E["Network issue:<br/>Check DNS, firewall, TLS"]
    C -->|Yes| F{"containerd can pull<br/>from Harbor?"}
    F -->|No| G["Registry/Mirror issue:<br/>See section 1.2"]
    F -->|Yes| H["Check plan secret<br/>in Rancher API"]
    H -->|Secret missing| I["Recreate cloud credential"]
    H -->|Secret stale| J["Rancher token expired:<br/>Regenerate via prepare.sh"]
```

**Root Causes & Solutions**

1. **Network/DNS issue**
   - Bootstrap node cannot resolve Rancher FQDN or Harbor FQDN
   - Check `/etc/resolv.conf` on bootstrap node
   - Verify DNS records exist and resolve correctly
   - Test: `nslookup <RANCHER_FQDN>` and `nslookup <HARBOR_FQDN>`

2. **containerd mirrors misconfigured**
   - See section 1.2 (Bootstrap registry returns 404)

3. **Stale Rancher token**
   - Rancher API token in cloud credential has expired
   - Solution: Regenerate kubeconfigs via `prepare.sh`, update cloud credential secret in Rancher

4. **Plan secret missing**
   - Rancher plan secret was deleted or not created
   - Check Rancher API: `curl -sk https://<RANCHER_URL>/v3/secrets -H "Authorization: Bearer <TOKEN>"` | jq '.data[] | select(.name | contains("rke2"))'`
   - Solution: Re-run `terraform apply` to recreate the plan secret

**Escalation**
- If system-agent service is failing repeatedly: check kernel logs (`dmesg`), memory/disk pressure on bootstrap node
- If network unreachable: verify Harvester network configuration, VLAN setup, routing

---

### Symptom: "bootstrap registry returns 404" or "connection refused"

**Quick Check**
- [ ] Test registry connectivity: `curl -k https://<BOOTSTRAP_REGISTRY>/v2/`
- [ ] Check if registry is running on Harvester: SSH to airgap VM, run `docker ps | grep registry` or `docker ps | grep harbor`
- [ ] Verify bootstrap_registry FQDN is resolvable: `nslookup <BOOTSTRAP_REGISTRY>`
- [ ] Check firewall: `iptables -L -n | grep <PORT>`

**Root Causes & Solutions**

1. **Registry FQDN misconfigured (bare IP instead of FQDN)**
   - Issue: containerd mirror config uses IP address (e.g., `10.0.0.100`), but nginx virtual hosting requires Host header match
   - Symptom: `curl https://10.0.0.100/v2/` returns 404, but `curl -H "Host: harbor.example.com" https://10.0.0.100/v2/` works
   - Solution: Use FQDN in `terraform.tfvars`: `bootstrap_registry = "harbor.example.com"`
   - Ensure `/etc/hosts` or DNS maps `harbor.example.com` → IP address

2. **Registry TLS cert invalid**
   - Issue: Curl shows "certificate verify failed" or "self signed certificate"
   - Solution: Verify `private_ca_pem` in `terraform.tfvars` contains the correct CA certificate
   - Test: `curl -k --cacert <(echo "$PRIVATE_CA_PEM") https://<BOOTSTRAP_REGISTRY>/v2/`

3. **Registry not running or not reachable**
   - Solution: SSH to airgap VM hosting Harbor, verify it's running
   - Check Harbor container logs: `docker logs -f harbor-core` (or appropriate container)

4. **containerd mirror configuration invalid**
   - Issue: `registries.yaml` on node has wrong endpoint or auth
   - Solution: Check `/etc/rancher/rke2/registries.yaml` on cluster node
   - Verify mirror endpoint matches `bootstrap_registry`

**Resolution Steps**
```bash
# From bootstrap node or any node with containerd:
crictl info | grep -A 20 "config:"
# Or check the registries.yaml directly:
cat /etc/rancher/rke2/registries.yaml

# Test pull from Harbor
crictl pull <BOOTSTRAP_REGISTRY>/library/alpine:latest

# If TLS fails, verify cert:
openssl s_client -connect <BOOTSTRAP_REGISTRY>:443 -showcerts < /dev/null | openssl x509 -noout -text
```

---

### Symptom: "golden_image_name mismatch" — Terraform fails to find image

**Quick Check**
- [ ] List images on Harvester: `kubectl --kubeconfig=kubeconfig-harvester.yaml get images -A`
- [ ] Check what `terraform.tfvars` specifies: `grep golden_image_name terraform.tfvars`
- [ ] Compare against Terraform state: `terraform state show 'data.harvester_image.golden'` or `terraform state list | grep harvester_image`

**Decision Tree**
```mermaid
flowchart TD
    A["Terraform can't find<br/>golden_image_name"] --> B{"Image exists<br/>on Harvester?"}
    B -->|No| C["Build golden image:<br/>See golden-image/ builder"]
    B -->|Yes| D{"Name matches<br/>tfvars?"}
    D -->|No| E["Update terraform.tfvars<br/>golden_image_name field"]
    D -->|Yes| F{"State has old<br/>reference?"}
    F -->|Yes| G["Force refresh:<br/>terraform refresh"]
    F -->|No| H["Check Harvester<br/>namespace, may need full path"]
```

**Root Causes & Solutions**

1. **Golden image doesn't exist on Harvester**
   - Build the golden image using the builder: see `/golden-image/` directory
   - Verify it exists: `kubectl get images -A | grep <IMAGE_NAME>`

2. **golden_image_name in tfvars doesn't match Harvester**
   - Update `terraform.tfvars` to match the actual image name on Harvester
   - Example: `golden_image_name = "rke2-rocky9-golden-20260227"`

3. **Terraform state is stale**
   - Solution: Run `terraform refresh` to update state against actual infrastructure
   - If state lock prevents this: `terraform force-unlock <LOCK_ID>`

4. **Image is in wrong namespace**
   - Harvester images may be in namespace other than `default`
   - Check: `kubectl get images -A` to see all namespaces
   - Update tfvars if needed to include namespace prefix

**Resolution Steps**
```bash
# List all Harvester images
kubectl --kubeconfig=kubeconfig-harvester.yaml get images -A -o wide

# Describe the image to verify it exists
kubectl --kubeconfig=kubeconfig-harvester.yaml describe image <IMAGE_NAME> -n <NAMESPACE>

# Force Terraform to refresh state
terraform refresh

# Verify data source can find it
terraform console
> data.harvester_image.golden
> data.harvester_image.golden.id
```

---

### Symptom: "409 Conflict — cluster already exists" on terraform apply

**Quick Check**
- [ ] Check Rancher for orphaned cluster: `curl -sk https://<RANCHER_URL>/v3/clusters -H "Authorization: Bearer <TOKEN>" | jq '.data[] | select(.name | contains("<CLUSTER_NAME>"))'`
- [ ] Check CAPI resources: `kubectl --kubeconfig=kubeconfig-harvester.yaml get clusters -A`
- [ ] Check Rancher provisioning cluster: `kubectl --kubeconfig=kubeconfig-harvester.yaml get provisioningclusters -A`

**Root Causes & Solutions**

1. **Orphaned cluster from cancelled terraform apply**
   - Issue: `terraform apply` was cancelled or interrupted, leaving provisioning.cattle.io/clusters object in Rancher
   - Solution: Delete via Rancher API or kubectl
   - Steps:
     ```bash
     # Find orphaned cluster
     kubectl --kubeconfig=kubeconfig-harvester.yaml get clusters -A
     kubectl --kubeconfig=kubeconfig-harvester.yaml get provisioningclusters -A

     # Delete the provisioning cluster (this cascades to CAPI resources)
     kubectl --kubeconfig=kubeconfig-harvester.yaml delete provisioningcluster <CLUSTER_NAME> -n fleet-default

     # If stuck on finalizers, force delete
     kubectl --kubeconfig=kubeconfig-harvester.yaml patch provisioningcluster <CLUSTER_NAME> -n fleet-default -p '{"metadata":{"finalizers":[]}}' --type=merge
     ```

2. **CAPI resources have stale finalizers**
   - Issue: CAPI Machines, RKEControlPlanes, or HarvesterMachines have finalizers preventing deletion
   - Solution: Clear finalizers (use with caution — only after verifying resources are orphaned)
   - Steps:
     ```bash
     # List CAPI resources
     kubectl --kubeconfig=kubeconfig-harvester.yaml get rkecontrolplanes -A
     kubectl --kubeconfig=kubeconfig-harvester.yaml get machines -A
     kubectl --kubeconfig=kubeconfig-harvester.yaml get harvesteremachines -A

     # Clear finalizers (example)
     kubectl --kubeconfig=kubeconfig-harvester.yaml patch machine <MACHINE_NAME> -n <NS> -p '{"metadata":{"finalizers":[]}}' --type=merge
     ```

**Escalation**
- If deletion appears stuck: check Rancher UI for plan status, check system-agent logs on bootstrap node
- If unable to delete via API: use `terraform.sh destroy` which handles cleanup orchestration

---

### Symptom: "500 error — failed to get token: tokens.management.cattle.io not found"

**Quick Check**
- [ ] Check kubeconfig is valid: `kubectl --kubeconfig=kubeconfig-harvester.yaml auth can-i get clusters`
- [ ] Verify Rancher token (from kubeconfig): `cat kubeconfig-harvester.yaml | grep token | head -1`
- [ ] Check if Rancher local cluster API is accessible: `curl -sk https://<RANCHER_URL>/v3/clusters -H "Authorization: Bearer <TOKEN>"`

**Root Causes & Solutions**

1. **Rancher token expired or invalid**
   - Previous `terraform destroy` invalidated tokens in kubeconfig
   - Solution: Regenerate kubeconfigs via `prepare.sh`
   - Steps:
     ```bash
     cd cluster
     ./prepare.sh  # Re-authenticate to Rancher, generate new kubeconfigs
     ./terraform.sh init  # Reinitialize with new credentials
     ```

2. **Cloud credential secret deleted**
   - Issue: Rancher secret for cluster cloud credential was manually deleted
   - Solution: Recreate via Rancher API or let `terraform apply` recreate it
   - Check: `curl -sk https://<RANCHER_URL>/v3/namespaces/fleet-default/secrets -H "Authorization: Bearer <TOKEN>" | jq '.data[] | select(.name | contains("<CLUSTER_NAME>"))'`

**Escalation**
- If `prepare.sh` fails to authenticate: verify Rancher is reachable and credentials are correct
- If token keeps expiring: check Rancher token TTL settings

---

### Symptom: Duplicate MachineDeployments appear, VMs keep restarting

**Quick Check**
- [ ] Check machine deployments: `kubectl --kubeconfig=kubeconfig-harvester.yaml get machinedeployments -A`
- [ ] Check for duplicate pool names in Rancher cluster: `curl -sk https://<RANCHER_URL>/v1/provisioning.cattle.io.clusters/fleet-default/<CLUSTER_NAME> | jq '.spec.rkeConfig.machinePools[] | .name'`
- [ ] Check Terraform state for duplicates: `./terraform.sh state list | grep machine_pools`

**Root Causes & Solutions**

1. **Missing cloud_credential_secret_name on cluster resource**
   - Issue: The `rancher2_cluster_v2.rke2` resource in `cluster.tf` did not have `cloud_credential_secret_name` defined (critical fix in recent versions)
   - Symptom: Terraform creates machine pools, but Rancher cannot associate them with the cloud credential, causing duplicate provisioning attempts
   - Solution: Verify `cluster.tf` line 22 has: `cloud_credential_secret_name = rancher2_cloud_credential.harvester.id`
   - If missing, add it and re-apply: `./terraform.sh apply`
   - This tells Rancher which cloud credential to use for the entire cluster (not just per-pool)

2. **Stale/orphaned machine deployment from failed apply**
   - Issue: A previous `terraform apply` was cancelled, leaving machine deployment CRDs on Rancher
   - Symptom: `terraform plan` shows new pools, but Rancher has old pools still running
   - Solution: Delete orphaned deployments via Rancher API or kubectl, then re-apply
   - Steps:
     ```bash
     # List all machine deployments
     kubectl --kubeconfig=kubeconfig-harvester.yaml get machinedeployments -A

     # Delete orphaned ones (be careful — this will delete nodes)
     kubectl --kubeconfig=kubeconfig-harvester.yaml delete machinedeployment <NAME> -n <NS>

     # Re-apply to recreate with correct spec
     ./terraform.sh apply
     ```

**Escalation**
- If duplicates persist after adding cloud_credential_secret_name: manually force node reconciliation via Rancher UI or clear Terraform state and re-apply
- If VMs are restarting: check Harvester VM events (`kubectl --kubeconfig=kubeconfig-harvester.yaml describe vm <VM_NAME> -n <NS>`)

---

### Symptom: Rancher Steve API phantom objects after destroy

**Quick Check**
- [ ] Check for phantom resources: `curl -sk https://<RANCHER_URL>/v1/provisioning.cattle.io.clusters/fleet-default | jq '.metadata.deletionTimestamp'`
- [ ] Check HarvesterMachines: `curl -sk https://<RANCHER_URL>/v1/rke-machine.cattle.io.harvestermachines | jq '.data[] | select(.metadata.deletionTimestamp != null) | .metadata.name'`
- [ ] List orphaned CAPI Machines: `curl -sk https://<RANCHER_URL>/v1/cluster.x-k8s.io.machines | jq '.data[] | select(.metadata.deletionTimestamp != null) | .metadata.name'`

**Root Causes & Solutions**

1. **Stuck finalizers on HarvesterMachine objects**
   - Issue: HarvesterMachine objects have `deletionTimestamp` but finalizers prevent deletion
   - Symptom: After `destroy`, the Rancher API still reports machines exist (phantom objects)
   - Solution: Use `nuke-cluster.sh` which handles finalizer cleanup, or manually patch:
     ```bash
     curl -sk -X PATCH -H "Authorization: Bearer <TOKEN>" \
       -H "Content-Type: application/merge-patch+json" \
       "https://<RANCHER_URL>/v1/rke-machine.cattle.io.harvestermachines/fleet-default/<NAME>" \
       -d '{"metadata":{"finalizers":[]}}'
     ```

2. **Rancher API async cleanup lag**
   - Issue: Destroy completed but Rancher's object reconciliation hasn't caught up
   - Solution: Wait 1-2 minutes for cleanup propagation, or manually delete via API
   - This is expected behavior — Rancher's Steve API queries eventually return consistent data

3. **Disconnected Harvester cluster**
   - Issue: If Harvester cluster loses connectivity to Rancher, phantom objects can linger
   - Solution: Reconnect Harvester, then use `nuke-cluster.sh` to force cleanup

**Escalation**
- If phantom objects persist: use `nuke-cluster.sh` which bypasses normal deletion and force-deletes all resources
- If Rancher API is unreachable: check Rancher → Harvester network connectivity

---

### Symptom: Stuck finalizers during cluster deletion

**Quick Check**
- [ ] Check cluster deletion status: `curl -sk https://<RANCHER_URL>/v1/provisioning.cattle.io.clusters/fleet-default/<CLUSTER_NAME> -H "Authorization: Bearer <TOKEN>" | jq '.metadata | {name, deletionTimestamp, finalizers}'`
- [ ] Check how long it's been stuck: Look at `deletionTimestamp` and compare to current time

**Root Causes & Solutions**

1. **CAPI controller loops detecting drift**
   - Issue: CAPI's machine controller sees nodes as "unmatched" and keeps trying to reconcile during deletion
   - Symptom: `terraform destroy` hangs while trying to delete the cluster resource (max 5-10 minutes)
   - Solution: `terraform.sh destroy` calls `post_destroy_cleanup()` which patches out finalizers
   - If still stuck, manually clear:
     ```bash
     ./terraform.sh destroy -lock=false
     ```

2. **Harvester cluster provisioning stalled**
   - Issue: Machines cannot be deleted because Harvester API is slow or unavailable
   - Solution: Check Harvester health and retry destroy
     ```bash
     kubectl --kubeconfig=kubeconfig-harvester.yaml cluster-info
     ./terraform.sh destroy -auto-approve
     ```

3. **Network connectivity broken between Rancher and Harvester**
   - Issue: Rancher cannot communicate with Harvester to delete VMs
   - Solution: Restore connectivity, then use `nuke-cluster.sh` to force cleanup

**Escalation**
- If stuck > 10 minutes: use `nuke-cluster.sh -y` for irreversible cleanup
- If Harvester is offline: wait for it to come back online, then use `nuke-cluster.sh`

---

### Symptom: Compute pool not provisioning (0 min_count not triggering scale-from-zero)

**Quick Check**
- [ ] Verify compute pool exists: `./terraform.sh state list | grep compute`
- [ ] Check autoscaler annotations: `kubectl get machinepool compute -o yaml | grep autoscaler`
- [ ] Check if pods are actually requesting compute node affinity: `kubectl get pods -A -o json | jq '.items[] | select(.spec.nodeSelector["workload-type"]=="compute") | .metadata.name'`
- [ ] Check autoscaler logs: `kubectl logs -n cattle-system -l app.kubernetes.io/name=rancher-cluster-autoscaler -f`

**Root Causes & Solutions**

1. **No pods requesting compute affinity**
   - Issue: Compute pool has `compute_min_count = 0` (scale-from-zero), but no workloads are scheduled with `workload-type=compute` affinity
   - Solution: Deploy a pod with `nodeSelector: {"workload-type": "compute"}`:
     ```yaml
     apiVersion: v1
     kind: Pod
     metadata:
       name: compute-test
     spec:
       nodeSelector:
         workload-type: compute
       containers:
       - name: alpine
         image: alpine:latest
         command: ["sleep", "3600"]
     ```

2. **Autoscaler resource annotations missing or incorrect**
   - Issue: `cluster.tf` compute pool missing resource annotations for scale-from-zero
   - Symptom: Autoscaler sees `compute_min_count = 0` but doesn't know node capacity, so it won't scale up
   - Solution: Verify annotations in `cluster.tf` lines 119-122:
     ```hcl
     "cluster.provisioning.cattle.io/autoscaler-resource-cpu"     = var.compute_cpu
     "cluster.provisioning.cattle.io/autoscaler-resource-memory"  = "${var.compute_memory}Gi"
     "cluster.provisioning.cattle.io/autoscaler-resource-storage" = "${var.compute_disk_size}Gi"
     ```
   - If missing, add them and re-apply: `./terraform.sh apply`

3. **Autoscaler controller not running or unhealthy**
   - Issue: Rancher cluster autoscaler pod is in CrashLoopBackOff or not scheduled
   - Solution: Check pod status: `kubectl get pod -n cattle-system -l app.kubernetes.io/name=rancher-cluster-autoscaler`
   - Check logs: `kubectl logs -n cattle-system -l app.kubernetes.io/name=rancher-cluster-autoscaler`

**Escalation**
- If autoscaler is healthy and resource annotations exist, verify pod affinity is set correctly
- If scale-from-zero still doesn't work: manually add a compute node via Terraform (`compute_min_count = 1`), then let autoscaler scale it down when workload completes

---

## 2. Terraform State Issues

### Symptom: "Error locking state" or "lock already held"

**Quick Check**
- [ ] Check for stale Kubernetes lease: `kubectl --kubeconfig=kubeconfig-harvester.yaml get leases -n terraform-state`
- [ ] Identify lock holder: `kubectl --kubeconfig=kubeconfig-harvester.yaml describe lease tfstate-default-rke2-cluster -n terraform-state | grep -A 5 holderIdentity`
- [ ] Check if terraform process is running: `ps aux | grep terraform`

**Decision Tree**
```mermaid
flowchart TD
    A["Terraform lock error"] --> B{"terraform process<br/>still running?"}
    B -->|Yes| C["Wait for process<br/>to complete or kill"]
    B -->|No| D{"Is lock recent<br/>within 15 mins?"}
    D -->|Yes| E["Lease may still be valid<br/>Wait and retry"]
    D -->|No| F["Lock is stale<br/>Force unlock"]
    F --> G["Get lock ID:<br/>terraform plan -no-lock"]
    G --> H["terraform force-unlock<br/>LOCK_ID"]
```

**Root Causes & Solutions**

1. **Stale lock from interrupted terraform**
   - Issue: `terraform apply` or `terraform plan` was killed without cleanup
   - Solution: Use `terraform.sh` which auto-detects and clears stale locks
   - Manual solution:
     ```bash
     # Identify stale lock
     terraform plan -input=false 2>&1 | grep "Lock ID:"

     # Force unlock (replace with actual lock ID)
     terraform force-unlock -force <LOCK_ID>

     # Or delete the Kubernetes lease directly
     kubectl --kubeconfig=kubeconfig-harvester.yaml delete lease tfstate-default-rke2-cluster -n terraform-state
     ```

2. **Concurrent terraform processes**
   - Issue: Multiple `terraform apply` or `terraform plan` running simultaneously
   - Solution: Kill duplicate processes, ensure only one operator at a time
   - Check: `ps aux | grep terraform | grep -v grep`

**Prevention**
- Always use `terraform.sh apply` which handles locking robustly
- Never kill `terraform apply` mid-execution — let it complete or use `terraform.sh` which can recover

---

### Symptom: "errored.tfstate" file appears

**What This Means**
- Terraform creates `.terraform/errored.tfstate` when `terraform apply` fails partway through
- This is a checkpoint for recovery; Terraform can resume from this state

**How terraform.sh Handles It**
The `terraform.sh` script includes automatic recovery:
```bash
# From terraform.sh:
if [[ -f "$SCRIPT_DIR/.terraform/errored.tfstate" ]]; then
  log_warn "Found errored.tfstate from previous failed apply..."
  log_info "Copying to terraform.tfstate for recovery..."
  cp "$SCRIPT_DIR/.terraform/errored.tfstate" "$SCRIPT_DIR/terraform.tfstate"
fi
```

**Manual Recovery (if needed)**
```bash
# 1. Copy errored state to main state
cp .terraform/errored.tfstate terraform.tfstate

# 2. Unlock (if state lock held)
terraform force-unlock <LOCK_ID>

# 3. Plan to see what failed
terraform plan

# 4. Fix the issue (see relevant symptom section above)

# 5. Resume apply
terraform apply
```

---

### Symptom: "The root module does not declare a variable named X"

**Quick Check**
- [ ] Compare `terraform.tfvars` against `variables.tf`: `grep "^[a-z_]*[[:space:]]*=" terraform.tfvars | awk '{print $1}' | sort > /tmp/tfvars.txt && grep "^variable" variables.tf | awk '{print $2}' | tr -d '"' | sort > /tmp/vars.txt && comm -23 /tmp/tfvars.txt /tmp/vars.txt`

**Root Causes & Solutions**

1. **Stale variable in terraform.tfvars**
   - Issue: `terraform.tfvars` has variables that no longer exist in `variables.tf`
   - Example: Old deploy included `dockerhub_username` but it was removed
   - Solution: Remove stale lines from `terraform.tfvars`
   - Use `terraform.tfvars.example` as reference for current valid variables

2. **Variable renamed in variables.tf**
   - Example: `harbor_fqdn` was renamed to `bootstrap_registry_fqdn`
   - Solution: Rename the variable in `terraform.tfvars`

**Prevention**
- After updating `variables.tf`, validate: `terraform validate`
- Keep `terraform.tfvars.example` synchronized with actual variables

---

## 3. Cluster Health Issues

### Symptom: Worker nodes showing "uninitialized" taint

**Quick Check**

- [ ] Check node taints: `kubectl describe node <NODE_NAME> | grep Taints`
- [ ] Look for: `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule`
- [ ] Check Harvester cloud provider: `kubectl get daemonset -n kube-system harvester-cloud-provider`
- [ ] Check cloud provider logs: `kubectl logs -n kube-system -l app.kubernetes.io/name=harvester-cloud-provider --tail=50`

**What This Means**

- RKE2 bootstraps nodes with this taint until cloud provider initializes them
- Harvester cloud provider should remove taint once node is registered
- If taint persists, provider failed to initialize the node

**Root Causes & Solutions**

1. **Harvester cloud provider not deployed**
   - Check: `kubectl get daemonset -n kube-system harvester-cloud-provider`
   - If missing, RKE2 should deploy it automatically during bootstrap
   - Manual deploy: See RKE2 cloud provider documentation

2. **Cloud provider can't communicate with Harvester**
   - Check provider logs: `kubectl logs -n kube-system -l app.kubernetes.io/name=harvester-cloud-provider`
   - Verify kubeconfig in provider: `kubectl get secret -n kube-system harvester-kubeconfig -o yaml`
   - Solution: Ensure cloud credential is correct in Rancher

3. **Taint manually added or not removed**
   - Remove taint if cloud provider will not initialize:
     ```bash
     kubectl taint node <NODE_NAME> \
       node.cloudprovider.kubernetes.io/uninitialized:NoSchedule-
     ```

**Resolution Steps**

```bash
# 1. Check which nodes have uninitialized taint
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints[*]}{"\n"}{end}' | grep uninitialized

# 2. Check cloud provider status
kubectl get daemonset -n kube-system harvester-cloud-provider

# 3. Check cloud provider logs
kubectl logs -n kube-system -l app.kubernetes.io/name=harvester-cloud-provider -f

# 4. If provider logs show connection errors, verify Harvester kubeconfig
kubectl get secret -n kube-system harvester-kubeconfig -o yaml

# 5. Wait for provider to remove taint (can take 1-2 minutes)
watch 'kubectl describe node <NODE_NAME> | grep Taints'
```

---

### Symptom: cattle-cluster-agent cannot schedule on worker nodes

**Quick Check**

- [ ] Check cattle-cluster-agent pod: `kubectl get pods -n cattle-system -l app=cattle-cluster-agent`
- [ ] Check pod events: `kubectl describe pod -n cattle-system -l app=cattle-cluster-agent`
- [ ] Check node taints: `kubectl describe node <NODE_NAME> | grep Taints`
- [ ] Check node tolerations on pod: `kubectl get pod -n cattle-system -l app=cattle-cluster-agent -o jsonpath='{.items[0].spec.tolerations}'`

**What This Means**

- cattle-cluster-agent is Rancher's cluster controller, must run on at least one node
- If no toleration for control plane taints, agent can't schedule on CP-only cluster
- This causes Rancher to lose connectivity to the cluster

**Root Causes & Solutions**

1. **No worker nodes, control plane has NoSchedule taint**
   - Issue: Control plane nodes have `node-role.kubernetes.io/control-plane:NoSchedule`
   - cattle-cluster-agent has no toleration, can't schedule
   - Solution: Add toleration to cattle-cluster-agent deployment:
     ```bash
     kubectl patch deployment cattle-cluster-agent -n cattle-system --type merge -p \
       '{"spec":{"template":{"spec":{"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}}}'
     ```

2. **Control plane has uninitialized taint AND no worker nodes**
   - Solution: Remove uninitialized taint from control plane nodes:
     ```bash
     kubectl taint node <CP_NODE> node.cloudprovider.kubernetes.io/uninitialized:NoSchedule-
     ```

3. **cattle-cluster-agent pod in CrashLoopBackOff**
   - Check logs: `kubectl logs -n cattle-system -l app=cattle-cluster-agent`
   - Common causes: RBAC issue, service account missing, image pull error
   - Solution: Check events and logs to diagnose specific cause

**Prevention**

- RKE2 should automatically configure cattle-cluster-agent tolerations
- If deploying via Rancher with custom node pools, ensure at least one worker node OR add control plane toleration

---

### Symptom: Database pool nodes unable to initialize or stay in NotReady state

**Quick Check**

- [ ] Check database pool nodes: `kubectl get nodes -l workload-type=database -o wide`
- [ ] Check for uninitialized taints: `kubectl describe node -l workload-type=database | grep -A 2 Taints`
- [ ] Verify cloud provider removing taint: `kubectl logs -n kube-system -l app.kubernetes.io/name=harvester-cloud-provider | grep -i database`
- [ ] Check node-labeler has labeled them: `kubectl get nodes -l workload-type=database`

**Root Causes & Solutions**

1. **Database nodes stuck with uninitialized taint**
   - Issue: Harvester cloud provider hasn't initialized database nodes
   - Solution: Verify cloud provider is running and check logs for errors
   - Manual workaround (if cloud provider is working correctly):
     ```bash
     kubectl taint node -l workload-type=database \
       node.cloudprovider.kubernetes.io/uninitialized:NoSchedule-
     ```

2. **node-labeler hasn't reached database nodes**
   - Issue: Database nodes weren't labeled during provisioning
   - Solution: Force labeler to reconcile:
     ```bash
     kubectl rollout restart deployment node-labeler -n node-labeler

     # Wait for labels to appear
     watch 'kubectl get nodes -l workload-type=database'
     ```

3. **Database pool nodes not configured in machine_pools**
   - Issue: `cluster.tf` missing database pool configuration
   - Solution: Verify `cluster.tf` has database pool defined:
     ```hcl
     machine_pools {
       name      = "database"
       roles     = ["worker"]
       labels    = { "workload-type" = "database" }
       min_count = 4
       max_count = 10
     }
     ```
   - Re-apply: `terraform apply`

4. **Database nodes failing cloud-init or user data**
   - Issue: VM user-data script failed during boot
   - Solution: Check VM logs on Harvester:
     ```bash
     kubectl --kubeconfig=kubeconfig-harvester.yaml logs vm/<VM_NAME> -n <NAMESPACE>
     ```

**Resolution Steps**

```bash
# 1. Check database node status
kubectl get nodes -l workload-type=database -o wide

# 2. Check cloud provider logs
kubectl logs -n kube-system -l app.kubernetes.io/name=harvester-cloud-provider \
  --tail=100 | grep -i database

# 3. Check for uninitialized taint
kubectl describe nodes -l workload-type=database | grep -A 2 Taints

# 4. If nodes are properly initialized, verify workload can schedule
kubectl get pods -A | grep -i database || echo "No database workloads yet"

# 5. Wait for full reconciliation
watch 'kubectl get nodes -l workload-type=database'
```

**Escalation**

- If database nodes never reach Ready: check HarvesterMachine objects on Harvester
- Verify `cluster.tf` machine_pools defines database correctly
- Check Rancher UI for provisioning status on database pool

---

### Symptom: Worker nodes missing "workload-type" labels

**Quick Check**
- [ ] List nodes and labels: `kubectl get nodes --show-labels | grep workload-type`
- [ ] Check specific node: `kubectl get node <NODE_NAME> -o jsonpath='{.metadata.labels.workload-type}'`
- [ ] Verify node-labeler operator is running: `kubectl get pods -n node-labeler`
- [ ] Check node-labeler logs: `kubectl logs -n node-labeler -l app=node-labeler -f`

**Decision Tree**
```mermaid
flowchart TD
    A["Worker nodes missing<br/>workload-type labels"] --> B{"node-labeler<br/>pod running?"}
    B -->|No| C["node-labeler deployment<br/>failed to deploy"]
    B -->|Yes| D{"Check node-labeler<br/>logs for errors"}
    D -->|Pod running| E["Check Rancher<br/>machine labels"]
    E -->|Labels present in Rancher| F["Labels should propagate<br/>in ~30 seconds"]
    E -->|Labels missing in Rancher| G["Set labels in<br/>machine_pools in cluster.tf"]
```

**Root Causes & Solutions**

1. **node-labeler operator not deployed**
   - Issue: `deploy_operators = false` in `terraform.tfvars` or operator deployment failed
   - Solution: Set `deploy_operators = true`, ensure `harbor_admin_password` is configured
   - Re-run: `terraform apply -target=null_resource.deploy_node_labeler`

2. **node-labeler image not pushed to Harbor**
   - Issue: `operator_image_push` failed or was skipped
   - Solution: Re-run: `terraform apply -target=null_resource.operator_image_push`
   - Check logs: `terraform show` for error details

3. **Rancher machine config missing labels**
   - Issue: `machine_pools` in `cluster.tf` don't define labels (only general/compute/database pools do)
   - Solution: Verify `cluster.tf` has labels in each pool, e.g.:
     ```hcl
     labels = {
       "workload-type" = "general"
     }
     ```
   - Re-run: `terraform apply`

4. **node-labeler RBAC permissions insufficient**
   - Issue: Operator can't update node labels
   - Solution: Verify RBAC manifests exist: `operators/manifests/node-labeler/rbac.yaml`
   - Check: `kubectl get clusterrole,clusterrolebinding -n node-labeler`

**Resolution Steps**
```bash
# 1. Verify operator is running
kubectl get pods -n node-labeler -o wide

# 2. Check pod logs
kubectl logs -n node-labeler -l app=node-labeler --tail=100

# 3. Check RBAC
kubectl get clusterrolebinding | grep node-labeler

# 4. If RBAC missing, reapply manifests
kubectl apply -f operators/manifests/node-labeler/rbac.yaml

# 5. Check if labels exist in Rancher machineconfigs
kubectl --kubeconfig=kubeconfig-harvester.yaml get machineconfigs -A -o yaml | grep -A 10 "workload-type"

# 6. Wait for node-labeler to reconcile (check logs)
kubectl logs -n node-labeler -l app=node-labeler -f

# 7. Verify labels appear on nodes
kubectl get nodes --show-labels
```

---

### Symptom: Harvester cloud provider log spam — "no matched IPPool with requirement"

**Quick Check**
- [ ] Check Harvester cloud provider logs: `kubectl logs -n kube-system -l app.kubernetes.io/name=harvester-cloud-provider | head -50`
- [ ] Verify Cilium LB IP pool exists: `kubectl get ciliiumloadbalancerippool -A`
- [ ] Check pool range: `kubectl get ciliiumloadbalancerippool -o jsonpath='{.items[0].spec}'`

**What This Means**
- Harvester cloud provider tries to reconcile LoadBalancer service IPs with Cilium
- This is **cosmetic** — Cilium handles LB IP assignment independently
- Error is logged but doesn't prevent service from getting IP

**Root Causes & Solutions**

1. **This is expected behavior**
   - Harvester cloud provider was designed for cloud environments with different LB semantics
   - Cilium L2 advertisement handles LB IPs, Harvester provider sees no matching pool
   - **No action needed** — service will get IP via Cilium

2. **To suppress logs** (optional)
   - Edit Harvester cloud provider deployment: `kubectl edit deployment -n kube-system harvester-cloud-provider`
   - Add `--log-level=warning` to reduce INFO/DEBUG spam
   - Or patch deployment via Rancher UI

**Prevention**
- This is a known non-issue in the current architecture
- Document in deployment notes if using external monitoring

---

### Symptom: Traefik LoadBalancer service stuck in "Pending"

**Quick Check**
- [ ] Check service status: `kubectl get svc -n traefik`
- [ ] Describe service: `kubectl describe svc traefik -n traefik`
- [ ] Check Cilium LB pool: `kubectl get ciliiumloadbalancerippool -A -o yaml`
- [ ] Verify `traefik_lb_ip` is in pool range: Check `cluster.tf` variables

**Decision Tree**
```mermaid
flowchart TD
    A["Traefik service<br/>stuck Pending"] --> B{"Check Cilium<br/>LB pool range"}
    B -->|traefik_lb_ip NOT in range| C["Update CiliumLoadBalancerIPPool<br/>or adjust traefik_lb_ip"]
    B -->|traefik_lb_ip IN range| D{"Cilium BGP<br/>enabled?"}
    D -->|No, using L2| E["Check node with<br/>LoadBalancer IP"]
    D -->|Yes| F["Check BGP config<br/>and peer connectivity"]
    E -->|Not assigned| G["Cilium daemon logs<br/>on that node"]
```

**Root Causes & Solutions**

1. **traefik_lb_ip is outside Cilium LB pool range**
   - Issue: `cluster.tf` has:
     ```hcl
     traefik_lb_ip      = "192.168.48.2"
     cilium_lb_pool_start = "192.168.48.50"   # ← Problem! doesn't include 192.168.48.2
     cilium_lb_pool_stop  = "192.168.48.100"
     ```
   - Solution: Update `cilium_lb_pool_start` to include `traefik_lb_ip`:
     ```hcl
     cilium_lb_pool_start = "192.168.48.2"
     cilium_lb_pool_stop  = "192.168.48.20"
     ```
   - Re-apply: `terraform apply`

2. **CiliumLoadBalancerIPPool patch needed after cluster creation**
   - If pool was initialized with wrong range, patch it:
     ```bash
     kubectl patch ciliiumloadbalancerippool -n kube-system --type merge -p \
       '{"spec":{"cidrs":[{"cidr":"192.168.48.2/32"}]}}'
     ```

3. **Cilium LB feature disabled**
   - Check: `kubectl get daemonset -n kube-system cilium -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -i loadbalancer`
   - If feature is disabled, enable via Rancher cluster config or re-deploy with Cilium enabled

**Resolution Steps**
```bash
# 1. Check current pool
kubectl get ciliiumloadbalancerippool -A -o yaml

# 2. Check service IP assignment
kubectl get svc traefik -n traefik -o wide

# 3. Identify which node has the IP (if assigned)
kubectl get endpoints traefik -n traefik -o wide

# 4. If pool range is wrong, patch it
kubectl patch ciliiumloadbalancerippool <POOL_NAME> --type merge -p \
  '{"spec":{"cidrs":[{"cidr":"192.168.48.2/20"}]}}'

# 5. Verify service gets IP
kubectl get svc traefik -n traefik -w
```

---

## 4. Operator Deployment Issues

### Symptom: "image push fails" — crane or registry errors

**Quick Check**
- [ ] Verify Harbor is running: `curl -k https://<HARBOR_FQDN>/api/v2.0/health`
- [ ] Check operator images exist locally: `ls operators/images/`
- [ ] Verify Harbor credentials: `echo $HARBOR_PASSWORD | docker login -u admin --password-stdin <HARBOR_FQDN>`
- [ ] Check namespace exists in Harbor: Harbor web UI → Projects → Check if `operators` project exists

**Decision Tree**
```mermaid
flowchart TD
    A["Image push fails"] --> B{"Harbor API<br/>responding?"}
    B -->|No| C["Harbor not running<br/>or network issue"]
    B -->|Yes| D{"Credentials<br/>valid?"}
    D -->|No| E["Check HARBOR_PASSWORD<br/>and HARBOR_USER"]
    D -->|Yes| F{"Project/namespace<br/>exists in Harbor?"}
    F -->|No| G["Create harbor project<br/>via web UI or API"]
    F -->|Yes| H{"OCI image tarball<br/>exists?"]
    H -->|No| I["Build operators<br/>in operators/"]
    H -->|Yes| J["Run push-images.sh<br/>with debug: sh -x"]
```

**Root Causes & Solutions**

1. **Harbor is not running**
   - Solution: SSH to airgap VM, verify Harbor container is running
   - Check: `docker ps | grep harbor`
   - Restart: `cd /opt/harbor && docker-compose up -d`

2. **crane authentication failed**
   - Issue: `crane push` fails with "unauthorized"
   - Solution: Verify `HARBOR_PASSWORD` and `HARBOR_USER` are correct
   - Check: `echo $HARBOR_PASSWORD | crane auth login -u admin --password-stdin <HARBOR_FQDN>`

3. **OCI layout extraction failed**
   - Issue: `crane push` can't read OCI image tarball
   - Solution: Verify tarball exists and is not corrupted
   - Check: `tar -tzf operators/images/node-labeler-v0.2.0.tar.gz | head`

4. **Harbor project doesn't exist**
   - Issue: `crane push` gets 404 on `<HARBOR_FQDN>/operators/node-labeler`
   - Solution: Create project in Harbor:
     ```bash
     # Via API
     curl -sk -u admin:<PASSWORD> -X POST \
       https://<HARBOR_FQDN>/api/v2.0/projects \
       -H "Content-Type: application/json" \
       -d '{"project_name":"operators"}'
     ```

**Resolution Steps**
```bash
# 1. Debug push script with verbose output
bash -x operators/push-images.sh 2>&1 | head -100

# 2. Test Harbor connectivity
curl -k https://<HARBOR_FQDN>/api/v2.0/health | jq .

# 3. Test authentication
echo $HARBOR_PASSWORD | crane auth login -u admin --password-stdin <HARBOR_FQDN>

# 4. Verify images exist
ls -lh operators/images/

# 5. Manually push one image to debug
cd operators/images
crane push node-labeler-v0.2.0.tar.gz <HARBOR_FQDN>/operators/node-labeler:v0.2.0 \
  -u admin -p $HARBOR_PASSWORD

# 6. Check Harbor web UI for pushed image
# Navigate to: https://<HARBOR_FQDN> → Projects → operators
```

---

### Symptom: "Operators in ImagePullBackOff"

**Quick Check**
- [ ] Check pod status: `kubectl get pods -n node-labeler -o wide` (or storage-autoscaler)
- [ ] Describe pod: `kubectl describe pod <POD_NAME> -n node-labeler`
- [ ] Check image availability in Harbor: `curl -k https://<HARBOR_FQDN>/api/v2.0/projects`
- [ ] Verify registry mirror config: `kubectl get nodes -o jsonpath='{.items[0].status.images[*].names}' | tr ' ' '\n' | grep harbor`

**Root Causes & Solutions**

1. **Image not pushed to Harbor**
   - Issue: `operator_image_push` resource didn't execute or failed
   - Solution: Verify push completed, re-run if needed
   - Check: `terraform state show null_resource.operator_image_push | grep -i error`
   - Re-run: `terraform apply -target=null_resource.operator_image_push`

2. **Harbor registry mirror not configured on nodes**
   - Issue: Nodes can't reach Harbor or don't have mirror configured
   - Solution: Verify containerd mirrors are configured
   - Check on cluster node: `cat /etc/rancher/rke2/registries.yaml | grep -A 5 "<HARBOR_FQDN>"`
   - This should be auto-configured by cluster.tf during provisioning

3. **TLS certificate issue**
   - Issue: Node can't verify Harbor TLS certificate
   - Solution: Verify `private_ca_pem` in `terraform.tfvars` is correct
   - Check: `openssl s_client -connect <HARBOR_FQDN>:443 -showcerts < /dev/null | openssl x509 -text -noout`
   - Ensure node has CA cert: `kubectl get secret -n kube-system <CA_SECRET> -o jsonpath='{.data.ca\.crt}' | base64 -d`

4. **Image tag mismatch in deployment**
   - Issue: Deployment specifies wrong tag (e.g., `latest` instead of `v0.2.0`)
   - Solution: Verify `.rendered/node-labeler-deployment.yaml` has correct image tag
   - Check: `kubectl get deployment -n node-labeler -o jsonpath='{.items[0].spec.template.spec.containers[0].image}'`

**Resolution Steps**
```bash
# 1. Check pod status and events
kubectl describe pod -n node-labeler -l app=node-labeler

# 2. Verify image exists in Harbor
curl -k -u admin:<PASSWORD> https://<HARBOR_FQDN>/api/v2.0/repositories/operators

# 3. Check containerd mirror config on a node
kubectl debug node/<NODE_NAME> -it --image=busybox
# Inside debug container:
cat /host/etc/rancher/rke2/registries.yaml

# 4. Test image pull from node
crictl pull <HARBOR_FQDN>/operators/node-labeler:v0.2.0

# 5. If pull fails, check TLS
crictl pull --creds admin:<PASSWORD> <HARBOR_FQDN>/operators/node-labeler:v0.2.0

# 6. Force pod restart to retry
kubectl rollout restart deployment node-labeler -n node-labeler
```

---

## 5. Cleanup & Destroy Procedures

### SOP: Dirty Destroy (Cancelled Terraform)

**Purpose**: Recover from failed `terraform apply` or `terraform destroy` by cleaning up orphaned resources step-by-step.

**Prerequisites**
- Access to Harvester cluster via kubeconfig
- Access to Rancher API
- Terraform state available (even if errored)

**Estimated Time**: 10–15 minutes

**Risk Level**: High — deletes resources

**When to Use This**
- `terraform destroy` was cancelled mid-execution
- `terraform apply` left partial resources
- Cluster is in unusable state and manual cleanup is needed

**Steps**

1. **Assess current state**
   ```bash
   # List RKE2 cluster in Rancher
   kubectl --kubeconfig=kubeconfig-harvester.yaml get clusters -A
   kubectl --kubeconfig=kubeconfig-harvester.yaml get provisioningclusters -A

   # List VMs and PVCs on Harvester
   kubectl --kubeconfig=kubeconfig-harvester.yaml get vms -A
   kubectl --kubeconfig=kubeconfig-harvester.yaml get pvcs -A

   # List CAPI resources
   kubectl --kubeconfig=kubeconfig-harvester.yaml get machines,rkecontrolplanes -A
   ```

2. **Delete provisioning cluster** (cascades to CAPI)
   ```bash
   kubectl --kubeconfig=kubeconfig-harvester.yaml delete provisioningcluster <CLUSTER_NAME> -n fleet-default --wait=true

   # This takes 5–10 minutes. Monitor deletion:
   watch kubectl --kubeconfig=kubeconfig-harvester.yaml get provisioningcluster <CLUSTER_NAME> -n fleet-default
   ```

3. **Force delete if stuck on finalizers**
   ```bash
   # Clear provisioning cluster finalizers
   kubectl --kubeconfig=kubeconfig-harvester.yaml patch provisioningcluster <CLUSTER_NAME> -n fleet-default \
     -p '{"metadata":{"finalizers":[]}}' --type=merge

   # Clear CAPI machine finalizers
   kubectl --kubeconfig=kubeconfig-harvester.yaml get machines -A -o name | while read m; do
     kubectl --kubeconfig=kubeconfig-harvester.yaml patch "$m" -p '{"metadata":{"finalizers":[]}}' --type=merge
   done

   # Clear RKE control plane finalizers
   kubectl --kubeconfig=kubeconfig-harvester.yaml get rkecontrolplanes -A -o name | while read r; do
     kubectl --kubeconfig=kubeconfig-harvester.yaml patch "$r" -p '{"metadata":{"finalizers":[]}}' --type=merge
   done
   ```

4. **Delete orphaned VMs and PVCs**
   ```bash
   # List VMs created for the cluster
   kubectl --kubeconfig=kubeconfig-harvester.yaml get vms -A | grep <CLUSTER_NAME>

   # Delete VMs (this will delete associated PVCs)
   kubectl --kubeconfig=kubeconfig-harvester.yaml delete vm <VM_NAME> -n <NAMESPACE>

   # Wait for PVCs to be reclaimed
   watch kubectl --kubeconfig=kubeconfig-harvester.yaml get pvcs -A | grep <CLUSTER_NAME>
   ```

5. **Clean up Fleet bundles** (if created)
   ```bash
   # List bundles in Rancher local cluster
   kubectl get bundles -A | grep <CLUSTER_NAME>

   # Delete
   kubectl delete bundle <BUNDLE_NAME> -n <NAMESPACE>
   ```

6. **Validate cleanup**
   ```bash
   # Verify no resources remain
   kubectl --kubeconfig=kubeconfig-harvester.yaml get vms,pvcs,machines,rkecontrolplanes -A | grep <CLUSTER_NAME> || echo "All cleaned up"
   ```

**Rollback**: This is a destructive operation. Ensure you have backups if needed.

---

### SOP: Full Clean Destroy (terraform.sh destroy)

**Purpose**: Complete cleanup of RKE2 cluster and all provisioned resources using the terraform.sh orchestration script.

**Prerequisites**
- Terraform state available
- `terraform.sh` script accessible
- Harvester kubeconfig available

**Estimated Time**: 15–20 minutes

**Risk Level**: High — deletes all cluster infrastructure

**Steps**

1. **Verify state before destroy**
   ```bash
   terraform plan -destroy
   # Review resources that will be deleted
   ```

2. **Run terraform destroy via terraform.sh**
   ```bash
   ./terraform.sh destroy
   ```
   The script will:
   - Pull latest secrets from Kubernetes
   - Clear stale state locks
   - Run `terraform destroy -auto-approve`
   - Clean up Kubernetes state backend secret

3. **Monitor deletion**
   ```bash
   # In separate terminal, watch resources disappear
   watch 'kubectl --kubeconfig=kubeconfig-harvester.yaml get vms,pvcs,provisioningclusters -A'
   ```

4. **Verify cleanup**
   ```bash
   # All cluster-related resources should be gone
   kubectl --kubeconfig=kubeconfig-harvester.yaml get vms,pvcs,provisioningclusters -A | grep <CLUSTER_NAME> || echo "Clean"

   # Check Rancher cluster view — should show deletion in progress
   ```

5. **Post-destroy cleanup** (if needed)
   ```bash
   # Remove local files (optional)
   rm -f terraform.tfstate* .terraform/errored.tfstate kubeconfig-rke2*

   # Clear terraform state backend secret (optional)
   kubectl --kubeconfig=kubeconfig-harvester.yaml delete secret tfstate-default-rke2-cluster -n terraform-state
   ```

**Verification Checklist**
- [ ] No VMs remain on Harvester
- [ ] No PVCs remain
- [ ] No provisioning cluster in Rancher
- [ ] No CAPI resources (machines, rkecontrolplanes)
- [ ] terraform state shows no resources

**Rollback**: Destroy is final. Restore from backups if resources were deleted unintentionally.

---

### SOP: Force Unlock Terraform State

**Purpose**: Clear stale Terraform state lock when lock process has died or hung.

**When to Use**
- `terraform plan` or `terraform apply` fails with "Error acquiring the state lock"
- Lock age is > 30 minutes (stale)
- No terraform process is running

**Estimated Time**: 2–3 minutes

**Risk Level**: Medium — modifies lock state, but safe if no process is running

**Steps**

1. **Identify stale lock**
   ```bash
   # Attempt plan to see lock details
   terraform plan -input=false 2>&1 | grep -A 3 "Error acquiring the state lock"
   # Output will show: Lock ID: <UUID>
   ```

2. **Verify no terraform process is running**
   ```bash
   ps aux | grep terraform | grep -v grep
   # Should return empty
   ```

3. **Force unlock**
   ```bash
   # Using terraform command (recommended)
   terraform force-unlock <LOCK_ID>

   # Or, delete the Kubernetes lease directly
   kubectl --kubeconfig=kubeconfig-harvester.yaml delete lease tfstate-default-rke2-cluster -n terraform-state
   ```

4. **Verify lock is cleared**
   ```bash
   terraform plan -input=false -no-color
   # Should succeed (though may show "No changes" or actual changes)
   ```

**Escalation**: If lock persists after force-unlock, check Kubernetes lease directly or restart K8s API server.

---

## 6. Diagnostic Cheat Sheet

This section provides quick commands for diagnosing common issues without full context reading.

### Rancher API Queries

```bash
# Set variables for reuse
RANCHER_URL="https://rancher.example.com"
RANCHER_TOKEN="token-xxxxx:xxxxxxxxxxxx"

# List all clusters
curl -sk \
  -H "Authorization: Bearer $RANCHER_TOKEN" \
  "$RANCHER_URL/v3/clusters" | jq '.data[] | {name, id, state}'

# Get specific cluster status
curl -sk \
  -H "Authorization: Bearer $RANCHER_TOKEN" \
  "$RANCHER_URL/v3/clusters/<CLUSTER_ID>" | jq '.state, .conditions'

# List cloud credentials
curl -sk \
  -H "Authorization: Bearer $RANCHER_TOKEN" \
  "$RANCHER_URL/v3/cloudcredentials" | jq '.data[] | {name, provider}'

# Get machine (node) status
curl -sk \
  -H "Authorization: Bearer $RANCHER_TOKEN" \
  "$RANCHER_URL/v3/machines" | jq '.data[] | {name, state, nodePoolId}'

# List plan secrets for a cluster
curl -sk \
  -H "Authorization: Bearer $RANCHER_TOKEN" \
  "$RANCHER_URL/v3/namespaces/fleet-default/secrets" | \
  jq '.data[] | select(.name | contains("<CLUSTER_NAME>")) | {name, type}'
```

### Harvester Queries

```bash
# Set kubeconfig
export KUBECONFIG="./kubeconfig-harvester.yaml"

# List all images
kubectl get images -A

# Describe specific image
kubectl describe image <IMAGE_NAME> -n <NAMESPACE>

# List all VMs
kubectl get vms -A -o wide

# Describe VM (check creation errors)
kubectl describe vm <VM_NAME> -n <NAMESPACE>

# List all PVCs
kubectl get pvcs -A -o wide

# List provisioning clusters
kubectl get provisioningclusters -A

# Watch provisioning progress
kubectl get provisioningclusters -A -w

# Get cluster events
kubectl get events -n <CLUSTER_NAMESPACE> --sort-by='.lastTimestamp'

# Check cloud credential status
kubectl get secrets -A | grep cloud-credential
```

### RKE2 Cluster Queries

```bash
# Set kubeconfig for RKE2 cluster
export KUBECONFIG="./kubeconfig-rke2.yaml"  # From Rancher

# Get cluster nodes and health
kubectl get nodes -o wide
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'

# Check all pod status across cluster
kubectl get pods -A | grep -E "(CrashLoop|ImagePullBackOff|Pending)"

# Get Cilium status
kubectl get pods -n kube-system -l k8s-app=cilium

# Check Cilium agent logs (on specific node)
kubectl logs -n kube-system -l k8s-app=cilium -f --tail=100

# Check Traefik LoadBalancer IP assignment
kubectl get svc -n traefik
kubectl describe svc traefik -n traefik

# Check Cilium LoadBalancer IP pool
kubectl get ciliiumloadbalancerippool -A -o yaml

# Get operator pod status
kubectl get pods -n node-labeler
kubectl get pods -n storage-autoscaler
kubectl logs -n node-labeler -l app=node-labeler -f

# Check node labels
kubectl get nodes --show-labels | grep workload-type
```

### Terraform State Queries

```bash
# List all resources in state
terraform state list

# Show specific resource
terraform state show 'rancher2_cluster_v2.rke2'

# Show data source
terraform state show 'data.harvester_image.golden'

# Get cluster output values
terraform output

# Show state in JSON
terraform show -json | jq '.values.outputs'

# Check for lock
terraform plan -input=false 2>&1 | grep -i "lock\|acquired"
```

### Debug Containers on Nodes

```bash
# Launch ephemeral debug pod on specific node
kubectl debug node/<NODE_NAME> -it --image=busybox

# Inside debug container, access host filesystem at /host
cat /host/etc/rancher/rke2/registries.yaml
cat /host/etc/resolv.conf
ip route show -c  # Check routing

# Check kernel logs
dmesg

# Exit debug container
exit
```

### Troubleshoot Connectivity Issues

```bash
# Test DNS from bootstrap node
nslookup <FQDN>
dig <FQDN>

# Test HTTP/HTTPS to Rancher
curl -v https://<RANCHER_URL>/

# Test HTTP/HTTPS to Harbor
curl -k https://<HARBOR_FQDN>/v2/

# Test containerd pull
crictl pull <IMAGE_URL>

# Check firewall rules
iptables -L -n | grep <PORT>
```

---

## Additional Resources

- **RKE2 Documentation**: https://docs.rke2.io
- **Rancher Documentation**: https://rancher.com/docs
- **Harvester Documentation**: https://docs.harvesterhci.io
- **Terraform Rancher Provider**: https://registry.terraform.io/providers/rancher/rancher2
- **Kubernetes Troubleshooting**: https://kubernetes.io/docs/tasks/debug-application-cluster/

---

## Document Info

- **Last Updated**: 2026-03-04
- **Applicable To**: RKE2 cluster deployment on Harvester via Terraform
- **Scope**: Cluster provisioning, networking, operators, state management, cleanup, Rancher API issues
