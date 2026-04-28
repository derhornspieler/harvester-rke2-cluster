# Runbook: Storage Network Setup — RKE2 Cluster Shutdown & Restart

**Purpose:** Safely stop both RKE2 downstream clusters (`rke2-test`, `rke2-prod`) so the Harvester admin can apply a storage network change, then bring them back to healthy operation.

**Scope:** This procedure assumes a **planned maintenance window** with explicit user authorization. Total estimated outage: **40-90 min** depending on storage network setup duration.

**Authorization:** This runbook performs production-impacting actions. Do not execute without:
- Explicit go-ahead from cluster owner (currently `dev.user@example.com`)
- Confirmed maintenance window with downstream consumers
- Posted advance notice (Slack `#platform-ops`, GitLab issue, calendar invite ≥ 24 h ahead)

---

## 0. Hard preconditions (verify ALL before starting)

Run each command. **Do not proceed if any check fails.**

### 0.1 Authenticated kubeconfigs are current

```bash
export HARVESTER_KUBECONFIG=/home/rocky/code/harvester-rke2-cluster/kubeconfig-harvester.yaml
export PROD_KC=/tmp/rke2-prod.kubeconfig
export TEST_KC=/tmp/rke2-test.kubeconfig

# Regenerate downstream kubeconfigs via Rancher v3 (token may have rotated):
RANCHER_URL=https://rancher.example.com
RANCHER_TOKEN=<read from deploy-terraform/rke2-prod.tfvars>

for cluster in rke2-prod rke2-test; do
  CID=$(curl -sk -H "Authorization: Bearer $RANCHER_TOKEN" \
    "$RANCHER_URL/v3/clusters?name=$cluster" | jq -r '.data[0].id')
  curl -sk -X POST -H "Authorization: Bearer $RANCHER_TOKEN" \
    "$RANCHER_URL/v3/clusters/${CID}?action=generateKubeconfig" \
    | jq -r '.config' > /tmp/${cluster}.kubeconfig
  kubectl --kubeconfig=/tmp/${cluster}.kubeconfig get nodes >/dev/null && echo "OK $cluster"
done
```

**Expected:** Both clusters print `OK`. Each `kubectl get nodes` should show all nodes Ready.

### 0.2 Etcd snapshots exist (or trigger manual)

```bash
# Check existing snapshots:
for cluster in rke2-prod rke2-test; do
  count=$(curl -sk -H "Authorization: Bearer $RANCHER_TOKEN" \
    "$RANCHER_URL/v1/rke.cattle.io.etcdsnapshots?labelSelector=cluster.x-k8s.io/cluster-name=$cluster" \
    | jq '.data | length')
  echo "$cluster: $count snapshots"
done
```

**If count is 0 for either cluster, take a manual snapshot:**

```bash
for cluster in rke2-prod rke2-test; do
  CID_V3=$(curl -sk -H "Authorization: Bearer $RANCHER_TOKEN" \
    "$RANCHER_URL/v3/clusters?name=$cluster" | jq -r '.data[0].id')
  curl -sk -X POST -H "Authorization: Bearer $RANCHER_TOKEN" \
    "$RANCHER_URL/v3/clusters/${CID_V3}?action=backupEtcd"
  echo "snapshot triggered for $cluster"
done

# Wait 2 min, then re-verify count >= 1 per cluster.
sleep 120
for cluster in rke2-prod rke2-test; do
  count=$(curl -sk -H "Authorization: Bearer $RANCHER_TOKEN" \
    "$RANCHER_URL/v1/rke.cattle.io.etcdsnapshots?labelSelector=cluster.x-k8s.io/cluster-name=$cluster" \
    | jq '.data | length')
  [ "$count" -ge 1 ] && echo "OK $cluster snapshots=$count" || \
    { echo "FAIL $cluster has 0 snapshots"; exit 1; }
done
```

**Stop here if either snapshot fails to materialize.** Cannot safely proceed without a recovery point.

### 0.3 Harvester VM backups (recommended, not strictly required)

```bash
# Check if a backup target is configured:
kubectl --kubeconfig=$HARVESTER_KUBECONFIG get setting backup-target -o jsonpath='{.value}' | head -1
# Expected: a non-empty JSON like {"type":"s3","endpoint":"...","bucketName":"..."}
# If empty, see "Setting up VM backups" appendix below before continuing.

# If backup target IS configured, take VM-level backups now:
for cluster in rke2-prod rke2-test; do
  for vm in $(kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n $cluster get vm -o name); do
    name=${vm##*/}
    cat <<EOF | kubectl --kubeconfig=$HARVESTER_KUBECONFIG create -f -
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineBackup
metadata:
  generateName: ${name}-pre-storage-net-
  namespace: $cluster
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: $name
  type: backup
EOF
  done
done

# Wait for all backups to reach phase=Complete (this can take 10-30 min):
while kubectl --kubeconfig=$HARVESTER_KUBECONFIG get vmbackup -A --no-headers \
  | awk '$5 != "Complete" && $5 != "" {print}' | grep -q .; do
  echo "  waiting on backups..."
  sleep 30
done
```

**If no backup target exists**, proceed only with explicit owner sign-off after explaining the etcd-snapshot-only fallback. Etcd recovers cluster control state but **does not restore VM disk content** if a VM disk corrupts during the storage network change.

### 0.4 No active operations in flight

```bash
# No CAPI Machine in Provisioning/Deleting state:
kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n fleet-default get machine -o json | \
  jq -r '.items[] | select(.status.phase != "Running") | "\(.metadata.name) phase=\(.status.phase)"'
# Expected: empty

# No active VirtualMachineInstanceMigration:
kubectl --kubeconfig=$HARVESTER_KUBECONFIG get vmim -A --no-headers | \
  awk '$3 != "Succeeded" && $3 != "Failed" {print}'
# Expected: empty

# No pending TF state lock:
ls deploy-terraform/.terraform.tfstate.lock.info 2>/dev/null && echo "STATE LOCKED" || echo "OK"
# Expected: OK
```

### 0.5 Document current state (for post-restart verification)

```bash
# Capture node lists, IPs, and Cilium L2 leases. Compare against this after restart.
mkdir -p /tmp/storage-net-shutdown-state
for c in prod test; do
  kubectl --kubeconfig=/tmp/rke2-${c}.kubeconfig get nodes -o wide \
    > /tmp/storage-net-shutdown-state/rke2-${c}-nodes-before.txt
  kubectl --kubeconfig=/tmp/rke2-${c}.kubeconfig -n kube-system get lease \
    cilium-l2announce-kube-system-rke2-traefik -o yaml \
    > /tmp/storage-net-shutdown-state/rke2-${c}-l2lease-before.yaml 2>/dev/null
  kubectl --kubeconfig=/tmp/rke2-${c}.kubeconfig get svc rke2-traefik -n kube-system -o yaml \
    > /tmp/storage-net-shutdown-state/rke2-${c}-traefik-svc-before.yaml
done
echo "state captured to /tmp/storage-net-shutdown-state/"
```

---

## 1. Pre-shutdown disable (T-30 min)

These reduce the chance of the cluster reacting to the shutdown.

### 1.1 Disable cluster-autoscaler in both clusters

```bash
for c in prod test; do
  kubectl --kubeconfig=/tmp/rke2-${c}.kubeconfig -n cluster-autoscaler \
    scale deploy/cluster-autoscaler --replicas=0
  kubectl --kubeconfig=/tmp/rke2-${c}.kubeconfig -n cluster-autoscaler \
    rollout status deploy/cluster-autoscaler --timeout=60s
done
```

**Verify:** `kubectl -n cluster-autoscaler get deploy` shows `0/0` ready in both clusters.

### 1.2 Disable Harvester descheduler

```bash
kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n kube-system patch addon descheduler \
  --type=merge -p '{"spec":{"enabled":false}}'
# Wait for descheduler pod to terminate:
while kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n kube-system \
  get pod -l app.kubernetes.io/name=descheduler --no-headers 2>/dev/null | grep -q .; do
  sleep 5
done
echo "descheduler stopped"
```

### 1.3 Suspend the VM eviction reconciler CronJob

```bash
kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n kube-system patch cronjob/vm-eviction-reconciler \
  --type=merge -p '{"spec":{"suspend":true}}'
# Confirm:
kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n kube-system get cronjob/vm-eviction-reconciler \
  -o jsonpath='{.spec.suspend}'; echo
# Expected: true
```

### 1.4 Take a final etcd snapshot (right before shutdown)

```bash
for cluster in rke2-prod rke2-test; do
  CID_V3=$(curl -sk -H "Authorization: Bearer $RANCHER_TOKEN" \
    "$RANCHER_URL/v3/clusters?name=$cluster" | jq -r '.data[0].id')
  curl -sk -X POST -H "Authorization: Bearer $RANCHER_TOKEN" \
    "$RANCHER_URL/v3/clusters/${CID_V3}?action=backupEtcd"
done
# Wait 2 min for snapshots to complete:
sleep 120
# Note the latest snapshot name for each cluster — used as restore target if needed:
for cluster in rke2-prod rke2-test; do
  curl -sk -H "Authorization: Bearer $RANCHER_TOKEN" \
    "$RANCHER_URL/v1/rke.cattle.io.etcdsnapshots?labelSelector=cluster.x-k8s.io/cluster-name=$cluster" \
    | jq -r '.data | sort_by(.metadata.creationTimestamp) | reverse | .[0] | "\(.metadata.name)  ct=\(.metadata.creationTimestamp)"'
done
```

**Record both names.** They are the recovery points.

---

## 2. Shutdown (T-0)

**Both clusters in parallel — they're independent.**

### 2.1 Cordon and drain workers

```bash
for c in prod test; do
  for n in $(kubectl --kubeconfig=/tmp/rke2-${c}.kubeconfig get nodes \
    -l '!node-role.kubernetes.io/control-plane' -o name); do
    kubectl --kubeconfig=/tmp/rke2-${c}.kubeconfig drain "$n" \
      --ignore-daemonsets --delete-emptydir-data --force \
      --timeout=120s --skip-wait-for-delete-timeout=60 || true
  done
done
```

Some pods may not drain (DaemonSets, system). That's fine — VMs are about to halt.

### 2.2 Halt worker VMs (all pools EXCEPT controlplane)

```bash
for c in rke2-prod rke2-test; do
  echo "--- halting $c workers ---"
  for vm in $(kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n $c get vm -o json | \
    jq -r '.items[] | select(.metadata.labels["harvesterhci.io/machineSetName"] | endswith("-controlplane") | not) | .metadata.name'); do
    kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n $c patch vm $vm \
      --type=merge -p '{"spec":{"runStrategy":"Halted"}}'
  done
done
```

### 2.3 Wait for worker VMIs to terminate

```bash
for c in rke2-prod rke2-test; do
  echo "--- waiting on $c worker VMIs ---"
  while kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n $c get vmi -o json | \
    jq -e '.items[] | select(.metadata.labels["harvesterhci.io/machineSetName"] | endswith("-controlplane") | not)' >/dev/null 2>&1; do
    echo "  worker VMI still terminating in $c..."
    sleep 15
  done
done
```

### 2.4 Halt control plane VMs

```bash
for c in rke2-prod rke2-test; do
  echo "--- halting $c CPs ---"
  for vm in $(kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n $c get vm -o json | \
    jq -r '.items[] | select(.metadata.labels["harvesterhci.io/machineSetName"] | endswith("-controlplane")) | .metadata.name'); do
    kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n $c patch vm $vm \
      --type=merge -p '{"spec":{"runStrategy":"Halted"}}'
  done
done
```

### 2.5 Wait for ALL VMIs to be gone

```bash
for c in rke2-prod rke2-test; do
  while [ $(kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n $c get vmi --no-headers 2>/dev/null | wc -l) -ne 0 ]; do
    echo "$c: VMIs still terminating..."
    sleep 15
  done
  echo "$c: all VMIs gone"
done
```

**Verification gate:** Both `rke2-prod` and `rke2-test` namespaces report 0 VMIs. Confirm with:

```bash
kubectl --kubeconfig=$HARVESTER_KUBECONFIG get vmi -A | grep -E 'rke2-(test|prod)'
# Expected: empty
```

**Hand off to Harvester admin to apply storage network change.**

---

## 3. Storage network change (Harvester admin)

This step is performed by whoever owns the Harvester underlay, following https://docs.harvesterhci.io/v1.7/advanced/storagenetwork/. Out of scope for this runbook except for the gate:

**Wait until Harvester admin confirms** all of these:
- `kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n longhorn-system get setting storage-network -o jsonpath='{.value}'` returns the new VLAN setting
- All Longhorn manager and instance-manager pods on Harvester are Ready and on the new network
- No errors in `kubectl -n longhorn-system logs -l app=longhorn-manager --tail=50`

**Do not proceed until that gate passes.**

---

## 4. Startup (T+storage-network-duration)

**Order matters: control planes first, one cluster at a time.**

### 4.1 Start rke2-prod control planes

```bash
for vm in $(kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n rke2-prod get vm -o json | \
  jq -r '.items[] | select(.metadata.labels["harvesterhci.io/machineSetName"] | endswith("-controlplane")) | .metadata.name'); do
  kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n rke2-prod patch vm $vm \
    --type=merge -p '{"spec":{"runStrategy":"Always"}}'
done
```

### 4.2 Wait for rke2-prod etcd quorum (≥2 CPs Ready)

```bash
while [ $(kubectl --kubeconfig=$PROD_KC get nodes \
  -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null \
  | grep -c " Ready ") -lt 2 ]; do
  echo "waiting for rke2-prod etcd quorum (≥2 CPs Ready)..."
  sleep 20
done
echo "rke2-prod etcd quorum recovered"
```

**If this loop exceeds 15 minutes,** etcd has not recovered cleanly. See section 6 (Recovery).

### 4.3 Start rke2-prod workers

```bash
for vm in $(kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n rke2-prod get vm -o json | \
  jq -r '.items[] | select(.metadata.labels["harvesterhci.io/machineSetName"] | endswith("-controlplane") | not) | .metadata.name'); do
  kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n rke2-prod patch vm $vm \
    --type=merge -p '{"spec":{"runStrategy":"Always"}}'
done
```

### 4.4 Wait for rke2-prod fully Ready

```bash
while [ $(kubectl --kubeconfig=$PROD_KC get nodes --no-headers \
  | grep -c " Ready ") -lt 17 ]; do
  echo "rke2-prod nodes Ready: $(kubectl --kubeconfig=$PROD_KC get nodes --no-headers | grep -c ' Ready ')/17"
  sleep 30
done

# Cilium agents:
while [ $(kubectl --kubeconfig=$PROD_KC -n kube-system get pod -l k8s-app=cilium --no-headers \
  | awk '$2 ~ /1\/1/' | wc -l) -lt 17 ]; do
  echo "cilium agents Ready: ..."
  sleep 15
done

# VIP:
for i in 1 2 3 4 5; do
  if timeout 4 bash -c 'exec 3<>/dev/tcp/192.168.48.2/443 && exec 3<&-' 2>/dev/null; then
    echo "rke2-prod VIP responsive ($i/5)"
  else
    echo "rke2-prod VIP DOWN — investigate"
  fi
  sleep 2
done
```

### 4.5 Repeat 4.1–4.4 for rke2-test (target: 10 nodes, VIP `192.168.48.3`)

---

## 5. Post-startup re-enable

### 5.1 Re-enable VM eviction reconciler

```bash
kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n kube-system patch cronjob/vm-eviction-reconciler \
  --type=merge -p '{"spec":{"suspend":false}}'
# Wait for next 1-min fire:
sleep 75
kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n kube-system get jobs \
  -l app.kubernetes.io/name=vm-eviction-reconciler --sort-by=.metadata.creationTimestamp | tail -3
# Expected: latest job in Complete state, logs show patched=N skipped=M failed=0
```

### 5.2 Re-enable Harvester descheduler

```bash
kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n kube-system patch addon descheduler \
  --type=merge -p '{"spec":{"enabled":true}}'
sleep 30
kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n kube-system get pod \
  -l app.kubernetes.io/name=descheduler
# Expected: 1 pod, 1/1 Running
```

### 5.3 Re-enable cluster-autoscaler in each cluster

```bash
for c in prod test; do
  kubectl --kubeconfig=/tmp/rke2-${c}.kubeconfig -n cluster-autoscaler \
    scale deploy/cluster-autoscaler --replicas=1
done
```

### 5.4 Compare current state to pre-shutdown snapshot

```bash
for c in prod test; do
  diff /tmp/storage-net-shutdown-state/rke2-${c}-nodes-before.txt \
    <(kubectl --kubeconfig=/tmp/rke2-${c}.kubeconfig get nodes -o wide) \
    | head -20
done
```

**Acceptable differences:** AGE column (newer), STATUS=Ready (was Ready), maybe IPs if DHCP rotated. Anything else investigate.

### 5.5 Run validation suite

```bash
# Burst test from dev VM, 200 conns:
for vip in 192.168.48.2 192.168.48.3; do
  ok=0; fail=0
  for i in $(seq 1 200); do
    if timeout 3 bash -c "exec 3<>/dev/tcp/$vip/443 && exec 3<&-" 2>/dev/null; then
      ok=$((ok+1)); else fail=$((fail+1));
    fi
  done
  echo "VIP $vip: ok=$ok fail=$fail (target: 200/0)"
done
```

**Pass criteria:** 200/200 on both VIPs.

---

## 6. Recovery procedures

### 6.1 If etcd quorum doesn't return after 15 min

```bash
# List all CP VMs status:
kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n rke2-prod get vmi -l \
  harvesterhci.io/machineSetName=rke2-prod-rke2-prod-controlplane

# If at least 1 CP is Running but cluster isn't Ready, restore from snapshot:
SNAPSHOT_NAME=<the name recorded in step 1.4 for this cluster>
SPEC=$(curl -sk -H "Authorization: Bearer $RANCHER_TOKEN" \
  "$RANCHER_URL/v1/provisioning.cattle.io.clusters/fleet-default/rke2-prod")
PATCHED=$(echo "$SPEC" | jq --arg n "$SNAPSHOT_NAME" \
  '.spec.rkeConfig.etcdSnapshotRestore = {"name":$n,"generation":1,"restoreRKEConfig":"all"}')
curl -sk -X PUT -H "Authorization: Bearer $RANCHER_TOKEN" -H "Content-Type: application/json" \
  --data "$PATCHED" "$RANCHER_URL/v1/provisioning.cattle.io.clusters/fleet-default/rke2-prod"
# Wait 15 min for restore to complete; re-check kubectl get nodes.
```

Reference: `memory/feedback_etcd_snapshot_restore.md`.

### 6.2 If a VM fails to boot (kernel panic, disk corruption)

If VM backups were taken (step 0.3), restore from VirtualMachineRestore:

```bash
# Find the backup:
kubectl --kubeconfig=$HARVESTER_KUBECONFIG -n rke2-prod get vmbackup
# Trigger restore:
cat <<EOF | kubectl --kubeconfig=$HARVESTER_KUBECONFIG create -f -
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineRestore
metadata:
  generateName: <vm-name>-restore-
  namespace: rke2-prod
spec:
  target:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: <vm-name>
  virtualMachineBackupName: <vmbackup-name>
EOF
```

If no VM backup exists: the CAPI controller will eventually replace the failed Machine with a fresh VM. Etcd state on a failed CP is recoverable from the snapshot taken in step 1.4.

### 6.3 If Cilium L2 lease never re-elects

```bash
# Force lease deletion to trigger re-election:
kubectl --kubeconfig=$PROD_KC -n kube-system delete lease cilium-l2announce-kube-system-rke2-traefik
sleep 30
kubectl --kubeconfig=$PROD_KC -n kube-system get lease cilium-l2announce-kube-system-rke2-traefik
# Expected: holderIdentity = a workload-type=lb node
```

### 6.4 Abort & rollback

If the storage network change is failing on the Harvester side and cannot be completed in the maintenance window:

1. Harvester admin reverts the storage network change.
2. Restart cluster VMs per section 4 — etcd will resume from where it left off (last shutdown was clean, so no snapshot restore needed).
3. Re-enable everything per section 5.
4. Schedule a new attempt with longer window or after troubleshooting.

---

## Appendix A: Setting up VM backups (one-time, before maintenance)

If `kubectl get setting backup-target` returns empty, set up an S3 or NFS backup target before this maintenance window. Skipping this means a corrupt VM disk during the storage network change is not recoverable except by full cluster rebuild.

```yaml
apiVersion: harvesterhci.io/v1beta1
kind: Setting
metadata:
  name: backup-target
value: |
  {
    "type":"s3",
    "endpoint":"https://s3.example.com",
    "bucketName":"harvester-backups",
    "accessKeyId":"<from Vault>",
    "secretAccessKey":"<from Vault>",
    "bucketRegion":"us-east-1"
  }
```

After applying, `kubectl get backupTarget` should show `Ready: True`.

---

## Appendix B: Communication template

**24 hours before:**

> Subject: Maintenance window — Harvester storage network change, 2026-MM-DD HH:MM-HH:MM UTC
>
> Hi all — we'll be performing a planned outage on **rke2-prod** and **rke2-test** to apply a storage network configuration on the Harvester underlay.
>
> - Window: 2026-MM-DD HH:MM-HH:MM UTC (~60-90 min)
> - Impact: Both clusters fully offline. All workloads on rke2-prod (gitlab, harbor, vault, etc.) unreachable for the duration.
> - Recovery: VMs auto-restart in order; service VIPs come back ~15 min after Harvester admin completes the change.
> - Recovery point: etcd snapshot at HH:MM (this morning) — last 60 min of state changes are protected.
>
> Reach me on Slack `#platform-ops` if any concerns.

**At start:**

> Starting cluster shutdown now per runbook `docs/runbooks/storage-network-cluster-shutdown.md`. ETA back: HH:MM UTC.

**At each gate:**

> ✓ Both clusters halted. Handing off to Harvester admin for storage network change.

> ✓ Storage network change complete. Starting cluster restart now.

> ✓ All clusters Ready, validation passed. Maintenance complete.

---

## Document history

| Date | Author | Note |
|------|--------|------|
| 2026-04-26 | infra & platform | Initial draft |
