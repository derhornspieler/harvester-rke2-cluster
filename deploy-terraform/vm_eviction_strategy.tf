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
# A second continuous in-cluster CronJob reconciler (on Harvester kube-system,
# targeting both rke2-test and rke2-prod VM namespaces) is commented out below.
# Its primary value was hardening against the Harvester descheduler addon;
# with the descheduler disabled it is redundant. Re-enable alongside any
# descheduler reintroduction, or replace both with a Kyverno mutating webhook
# (tracked in project_kyverno_and_livemigrate_research.md).
#
# When Harvester upstream adds evictionStrategy support to HarvesterConfig,
# this file can be removed entirely.
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
# Continuous reconciler CronJob (Harvester-side)
# -----------------------------------------------------------------------------
# Re-enabled 2026-04-26 alongside Harvester descheduler reintroduction.
# Decision: docs/superpowers/specs/2026-04-26-vm-eviction-enforcement-decision.md
# Schedule is */1 (1 min) to keep the worst-case race window between an
# autoscaler-born VM landing with `LiveMigrateIfPossible` and the descheduler
# considering it for eviction <= ~60 s. Owned by exactly ONE TF workspace
# (manage_vm_eviction_reconciler=true in rke2-test.tfvars; false everywhere
# else) — the resources are shared across both downstream cluster namespaces.
# -----------------------------------------------------------------------------

resource "kubernetes_service_account" "vm_eviction_reconciler" {
  count = var.manage_vm_eviction_reconciler ? 1 : 0

  provider = kubernetes.harvester

  metadata {
    name      = "vm-eviction-reconciler"
    namespace = "kube-system"
  }
}

resource "kubernetes_cluster_role" "vm_eviction_reconciler" {
  count = var.manage_vm_eviction_reconciler ? 1 : 0

  provider = kubernetes.harvester

  metadata {
    name = "vm-eviction-reconciler"
  }

  rule {
    api_groups = ["kubevirt.io"]
    resources  = ["virtualmachines"]
    verbs      = ["get", "list", "patch"]
  }
  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding" "vm_eviction_reconciler" {
  count = var.manage_vm_eviction_reconciler ? 1 : 0

  provider = kubernetes.harvester

  metadata {
    name = "vm-eviction-reconciler"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.vm_eviction_reconciler[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.vm_eviction_reconciler[0].metadata[0].name
    namespace = kubernetes_service_account.vm_eviction_reconciler[0].metadata[0].namespace
  }
}

resource "kubernetes_cron_job_v1" "vm_eviction_reconciler" {
  count = var.manage_vm_eviction_reconciler ? 1 : 0

  provider = kubernetes.harvester

  metadata {
    name      = "vm-eviction-reconciler"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name"       = "vm-eviction-reconciler"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    schedule                      = "*/1 * * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 30

    job_template {
      metadata {}
      spec {
        backoff_limit = 2
        template {
          metadata {
            labels = {
              "app.kubernetes.io/name" = "vm-eviction-reconciler"
            }
          }
          spec {
            service_account_name = kubernetes_service_account.vm_eviction_reconciler[0].metadata[0].name
            restart_policy       = "OnFailure"

            container {
              name = "reconciler"
              # alpine/k8s — community Alpine + kubectl + helm + sh.
              # NOT Bitnami (project policy). Pulled through Harbor proxy-cache
              # (anonymous library project, no auth required at pull time).
              image             = "${var.harbor_fqdn}/docker.io/alpine/k8s:1.34.0"
              image_pull_policy = "IfNotPresent"
              command           = ["/bin/sh", "-c"]
              args = [
                <<-EOT
                  set -u
                  PATCHED=0
                  SKIPPED=0
                  FAILED=0
                  for NS in rke2-test rke2-prod; do
                    kubectl get ns "$NS" >/dev/null 2>&1 || continue
                    for VM in $(kubectl -n "$NS" get vm -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
                      CUR=$(kubectl -n "$NS" get vm "$VM" -o jsonpath='{.spec.template.spec.evictionStrategy}' 2>/dev/null || echo "unset")
                      if [ "$CUR" = "LiveMigrate" ]; then
                        SKIPPED=$((SKIPPED + 1))
                        continue
                      fi
                      if kubectl -n "$NS" patch vm "$VM" --type=merge \
                          -p '{"spec":{"template":{"spec":{"evictionStrategy":"LiveMigrate"}}}}' >/dev/null 2>&1; then
                        PATCHED=$((PATCHED + 1))
                        echo "patched $NS/$VM (was $CUR)"
                      else
                        FAILED=$((FAILED + 1))
                        echo "FAILED to patch $NS/$VM (was $CUR)"
                      fi
                    done
                  done
                  echo "reconcile done: patched=$PATCHED skipped=$SKIPPED failed=$FAILED"
                  # Always exit 0 — backoff_limit handles genuine engine outages.
                  # A single transient patch failure should not cascade Job restarts.
                  exit 0
                EOT
              ]
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_cluster_role_binding.vm_eviction_reconciler,
  ]
}
