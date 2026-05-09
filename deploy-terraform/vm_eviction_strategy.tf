# =============================================================================
# VM Eviction Strategy Reconciler
# =============================================================================
# KubeVirt's auto-PodDisruptionBudget and virt-launcher-eviction-interceptor
# webhook only activate when a VMI's spec.evictionStrategy is set to the strict
# value `LiveMigrate`. Harvester's HarvesterConfig CRD and the
# docker-machine-driver-harvester both default new VMs to `LiveMigrateIfPossible`
# (permissive), which does NOT trigger those protections. When combined with
# Harvester's descheduler addon, this can cause mid-migration target-pod
# evictions that leave VMs in corrupted hotplug-volume state.
#
# Why the upstream default is permissive:
#   harvester/harvester#5496 (backport #5643, v1.2.2) intentionally changed
#   the default from `LiveMigrate` → `LiveMigrateIfPossible` to suppress
#   spurious "not migratable" warnings on VMs with PCI passthrough. That
#   rationale is sound for the default but inappropriate for migratable RKE2
#   nodes — hence the override.
#
# Tracking upstream: harvester/harvester#10427 — open feature request to
# expose `evictionStrategy` on `HarvesterConfig` so this reconciler can be
# removed once the field is plumbed through docker-machine-driver-harvester
# and the rancher2 Terraform provider.
#
# This file currently runs ONE reconciler:
#
#   1. null_resource.vm_eviction_strategy_initial
#      Fires once after cluster is Ready. Patches every VM in the cluster's
#      vm_namespace to evictionStrategy=LiveMigrate. Runs on every apply
#      (triggers include timestamp) so it catches VMs created during CAPI
#      rolling updates triggered by config drift.
#
# The continuous in-cluster CronJob reconciler (Harvester-host scope, targeting
# every RKE2 guest cluster namespace at `*/1` schedule) lives under
# `addons/vm-eviction-reconciler.yaml` as of 2026-05-03 — it is a Harvester-host
# concern, not a per-RKE2-cluster concern, so it does not belong in this TF
# workspace. Apply it once with:
#   kubectl --context=hvst-local apply -f addons/vm-eviction-reconciler.yaml
#
# When Harvester upstream adds evictionStrategy support to HarvesterConfig
# (harvester/harvester#10427, currently OPEN), both this file and the addon
# YAML can be removed entirely.
# =============================================================================

resource "null_resource" "vm_eviction_strategy_initial" {
  depends_on = [rancher2_cluster_v2.rke2]

  # Re-run on every apply — cheap, idempotent, catches any drift
  triggers = {
    cluster_id = rancher2_cluster_v2.rke2.id
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command     = <<-EOT
      set -euo pipefail

      RANCHER_URL="${var.rancher_url}"
      RANCHER_TOKEN="${var.rancher_token}"
      HARVESTER_CLUSTER_ID="${var.harvester_cluster_id}"
      VM_NAMESPACE="${var.vm_namespace}"
      BASE="$RANCHER_URL/k8s/clusters/$HARVESTER_CLUSTER_ID"

      echo "[vm_eviction_strategy] waiting for VMs to appear in $VM_NAMESPACE..."
      for i in $(seq 1 30); do
        vms=$(curl -sk -H "Authorization: Bearer $RANCHER_TOKEN" \
          "$BASE/apis/kubevirt.io/v1/namespaces/$VM_NAMESPACE/virtualmachines" \
          | jq -r '.items[]?.metadata.name' 2>/dev/null || true)
        [ -n "$vms" ] && break
        sleep 20
      done

      if [ -z "$vms" ]; then
        echo "[vm_eviction_strategy] no VMs appeared after 10 min — skipping"
        exit 0
      fi

      patched=0
      skipped=0
      for vm in $vms; do
        current=$(curl -sk -H "Authorization: Bearer $RANCHER_TOKEN" \
          "$BASE/apis/kubevirt.io/v1/namespaces/$VM_NAMESPACE/virtualmachines/$vm" \
          | jq -r '.spec.template.spec.evictionStrategy // "unset"')
        if [ "$current" = "LiveMigrate" ]; then
          skipped=$((skipped + 1))
          continue
        fi
        curl -sk -X PATCH -H "Authorization: Bearer $RANCHER_TOKEN" \
          -H "Content-Type: application/merge-patch+json" \
          -d '{"spec":{"template":{"spec":{"evictionStrategy":"LiveMigrate"}}}}' \
          "$BASE/apis/kubevirt.io/v1/namespaces/$VM_NAMESPACE/virtualmachines/$vm" \
          -o /dev/null -w "  patched $vm: %%{http_code}\n"
        patched=$((patched + 1))
      done
      echo "[vm_eviction_strategy] done: patched=$patched skipped=$skipped"
    EOT
    interpreter = ["/bin/bash", "-c"]
  }
}

# -----------------------------------------------------------------------------
# Continuous reconciler CronJob — moved out of this workspace 2026-05-03.
# -----------------------------------------------------------------------------
# Now lives in `addons/vm-eviction-reconciler.yaml` (Harvester-host scoped).
# If a previous `terraform apply` had `manage_vm_eviction_reconciler = true`
# and this workspace's state still tracks the SA / ClusterRole /
# ClusterRoleBinding / CronJob resources, run:
#
#   terraform state rm \
#     kubernetes_service_account.vm_eviction_reconciler \
#     kubernetes_cluster_role.vm_eviction_reconciler \
#     kubernetes_cluster_role_binding.vm_eviction_reconciler \
#     kubernetes_cron_job_v1.vm_eviction_reconciler
#
# before the next apply, otherwise Terraform will plan to delete the
# resources that the addon YAML now owns.
