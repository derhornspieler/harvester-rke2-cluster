# =============================================================================
# Per-pool KubeVirt MigrationPolicy
# =============================================================================
# Creates one MigrationPolicy CRD on the Harvester cluster per RKE2 node pool,
# matched by the `harvesterhci.io/machineSetName` label the docker-machine
# driver sets on each VMI. Controls whether live migrations for that pool may
# fall back to post-copy mode.
#
# Pre-copy (default, allowPostCopy = false): source keeps running until RAM
# pages finish copying. Safe — source still holds state if anything goes
# wrong. Can fail to converge on VMs with high page-dirty rate (busy Postgres,
# heavy write workloads), because pages dirty faster than they copy.
#
# Post-copy (allowPostCopy = true): target resumes execution before RAM is
# fully copied; remaining pages are fetched on-demand from source. Converges
# reliably on busy VMs. Risk: if source crashes/loses network mid post-copy,
# the VM is unrecoverable — whatever wasn't persisted to PVC is lost.
#
# Defaults chosen for safety:
#   cp       : false (etcd leader loss too costly to risk)
#   general  : false (mixed workloads)
#   compute  : false (mixed workloads)
#   database : true  (Postgres commits to WAL on its PVC; in-memory loss
#                    is acceptable. This pool is where pre-copy most often
#                    fails to converge.)
# =============================================================================

locals {
  migration_policies = {
    cp = {
      enabled      = var.cp_allow_post_copy
      machine_pool = "controlplane"
      policy_name  = "${var.cluster_name}-cp-migration-policy"
    }
    general = {
      enabled      = var.general_allow_post_copy
      machine_pool = "general"
      policy_name  = "${var.cluster_name}-general-migration-policy"
    }
    compute = {
      enabled      = var.compute_allow_post_copy
      machine_pool = "compute"
      policy_name  = "${var.cluster_name}-compute-migration-policy"
    }
    database = {
      enabled      = var.database_allow_post_copy
      machine_pool = "database"
      policy_name  = "${var.cluster_name}-database-migration-policy"
    }
  }

  # Shape B-2 pools — same MigrationPolicy structure, gated on the same
  # feature flag as the pools themselves.
  migration_policies_shape_b2 = var.enable_dedicated_ingress_pool ? {
    lb = {
      enabled      = var.lb_allow_post_copy
      machine_pool = "lb"
      policy_name  = "${var.cluster_name}-lb-migration-policy"
    }
    ingress = {
      enabled      = var.ingress_allow_post_copy
      machine_pool = "ingress"
      policy_name  = "${var.cluster_name}-ingress-migration-policy"
    }
  } : {}

  migration_policies_all = merge(local.migration_policies, local.migration_policies_shape_b2)
}

resource "kubernetes_manifest" "migration_policy" {
  for_each = local.migration_policies_all

  provider = kubernetes.harvester

  manifest = {
    apiVersion = "migrations.kubevirt.io/v1alpha1"
    kind       = "MigrationPolicy"
    metadata = {
      name = each.value.policy_name
      labels = {
        "rke.cattle.io/cluster-name"   = var.cluster_name
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    spec = {
      selectors = {
        virtualMachineInstanceSelector = {
          "harvesterhci.io/machineSetName" = "${var.vm_namespace}-${var.cluster_name}-${each.value.machine_pool}"
        }
      }
      allowPostCopy           = each.value.enabled
      allowAutoConverge       = true
      completionTimeoutPerGiB = 200
    }
  }
}
