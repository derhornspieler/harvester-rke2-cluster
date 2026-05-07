# -----------------------------------------------------------------------------
# Rancher Connection
# -----------------------------------------------------------------------------

variable "rancher_url" {
  description = "Rancher API URL (e.g. https://rancher.example.com)"
  type        = string
}

variable "rancher_token" {
  description = "Rancher API token (format: token-xxxxx:xxxxxxxxxxxx)"
  type        = string
  sensitive   = true
}

variable "rancher_insecure" {
  description = "Skip TLS verification for Rancher API (set to true only for dev/self-signed certs)"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Harvester Connection
# -----------------------------------------------------------------------------

variable "harvester_kubeconfig_path" {
  description = "Path to Harvester cluster kubeconfig (for state backend and image upload)"
  type        = string
}

variable "harvester_cloud_credential_kubeconfig_path" {
  description = "Path to Harvester kubeconfig for Rancher cloud credential (uses SA token, not Rancher user token)"
  type        = string
  default     = "./kubeconfig-harvester-cloud-cred.yaml"
}

variable "harvester_cluster_id" {
  description = "Harvester management cluster ID in Rancher (e.g. c-bdrxb)"
  type        = string
}

# -----------------------------------------------------------------------------
# Cluster Configuration
# -----------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name for the RKE2 cluster"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the RKE2 cluster"
  type        = string
  default     = "v1.34.2+rke2r1"
}

variable "cni" {
  description = "CNI plugin for the cluster"
  type        = string
  default     = "cilium"
}

variable "traefik_lb_ip" {
  description = "Static LoadBalancer IP for Traefik ingress"
  type        = string
  default     = "192.168.48.2"
}

variable "cilium_lb_pool_start" {
  description = "Start of Cilium L2 LoadBalancer IP pool (must include traefik_lb_ip)"
  type        = string
  default     = "192.168.48.2"
}

variable "cilium_lb_pool_stop" {
  description = "End of Cilium L2 LoadBalancer IP pool"
  type        = string
  default     = "192.168.48.20"
}

variable "cilium_image_registry" {
  description = <<-EOT
    Registry prefix for Cilium images (cilium, operator-generic, hubble-relay,
    hubble-ui, hubble-ui-backend). The chart appends "/cilium/<image>" to this.
    Default points at upstream quay.io. For airgapped sites override per-cluster
    in tfvars to your Harbor proxy-cache, e.g. "<your-harbor>/quay.io".
  EOT
  type        = string
  default     = "quay.io"
}

variable "cilium_image_tag" {
  description = "Container image tag for cilium / operator / hubble-relay (must match the chart version pinned in cluster.tf)."
  type        = string
  default     = "v1.19.3"
}

variable "hubble_ui_image_tag" {
  description = "Container image tag for hubble-ui and hubble-ui-backend (versioned independently from the cilium-agent tag)."
  type        = string
  default     = "v0.13.3"
}

# -----------------------------------------------------------------------------
# Harvester Networking
# -----------------------------------------------------------------------------

variable "vm_namespace" {
  description = "Harvester namespace where VMs will be created"
  type        = string
}

variable "harvester_network_name" {
  description = "Name of the Harvester VM network"
  type        = string
}

variable "harvester_network_namespace" {
  description = "Namespace of the Harvester VM network (usually same as vm_namespace)"
  type        = string
}

variable "harvester_services_network_name" {
  description = "Name of the Harvester services/ingress network (eth1, VLAN 5)"
  type        = string
  default     = "services-network"
}

variable "harvester_services_network_namespace" {
  description = "Namespace of the Harvester services network"
  type        = string
  default     = "default"
}

# -----------------------------------------------------------------------------
# Golden Image
# -----------------------------------------------------------------------------

variable "golden_image_name" {
  description = "Name of the pre-baked golden image in Harvester (must already exist)"
  type        = string

  validation {
    condition     = length(var.golden_image_name) > 0
    error_message = "golden_image_name is required — the golden image must exist on Harvester."
  }
}

variable "harvester_image_namespace" {
  description = "Harvester namespace that holds the golden image (often 'default', distinct from vm_namespace)"
  type        = string
  default     = "default"
}

# -----------------------------------------------------------------------------
# Control Plane Pool
# -----------------------------------------------------------------------------

variable "controlplane_count" {
  description = "Number of control plane nodes (should be odd for etcd quorum)"
  type        = number
  default     = 3
}

variable "controlplane_cpu" {
  description = "vCPUs per control plane node"
  type        = string
  default     = "8"
}

variable "controlplane_memory" {
  description = "Memory (GiB) per control plane node"
  type        = string
  default     = "32"
}

variable "controlplane_disk_size" {
  description = "Disk size (GiB) per control plane node"
  type        = number
  default     = 80
}

# -----------------------------------------------------------------------------
# General Worker Pool
# -----------------------------------------------------------------------------

variable "general_cpu" {
  description = "vCPUs per general worker node"
  type        = string
  default     = "4"
}

variable "general_memory" {
  description = "Memory (GiB) per general worker node"
  type        = string
  default     = "8"
}

variable "general_disk_size" {
  description = "Disk size (GiB) per general worker node"
  type        = number
  default     = 60
}

variable "general_min_count" {
  description = "Minimum number of general worker nodes (autoscaler)"
  type        = number
  default     = 4
}

variable "general_max_count" {
  description = "Maximum number of general worker nodes (autoscaler)"
  type        = number
  default     = 10
}

# -----------------------------------------------------------------------------
# Compute Worker Pool
# -----------------------------------------------------------------------------

variable "compute_cpu" {
  description = "vCPUs per compute worker node"
  type        = string
  default     = "8"
}

variable "compute_memory" {
  description = "Memory (GiB) per compute worker node"
  type        = string
  default     = "32"
}

variable "compute_disk_size" {
  description = "Disk size (GiB) per compute worker node"
  type        = number
  default     = 80
}

variable "compute_min_count" {
  description = "Minimum number of compute worker nodes (autoscaler, 0 = scale from zero)"
  type        = number
  default     = 0
}

variable "compute_max_count" {
  description = "Maximum number of compute worker nodes (autoscaler)"
  type        = number
  default     = 10
}

# -----------------------------------------------------------------------------
# Database Worker Pool
# -----------------------------------------------------------------------------

variable "database_cpu" {
  description = "vCPUs per database worker node"
  type        = string
  default     = "4"
}

variable "database_memory" {
  description = "Memory (GiB) per database worker node"
  type        = string
  default     = "16"
}

variable "database_disk_size" {
  description = "Disk size (GiB) per database worker node"
  type        = number
  default     = 80
}

variable "database_min_count" {
  description = "Minimum number of database worker nodes (autoscaler)"
  type        = number
  default     = 4
}

variable "database_max_count" {
  description = "Maximum number of database worker nodes (autoscaler)"
  type        = number
  default     = 10
}

# -----------------------------------------------------------------------------
# Cluster Autoscaler Behavior
# -----------------------------------------------------------------------------

variable "autoscaler_scale_down_unneeded_time" {
  description = "How long a node must be unneeded before the autoscaler removes it (e.g., 30m0s)"
  type        = string
  default     = "30m0s"
}

variable "autoscaler_scale_down_delay_after_add" {
  description = "Cooldown after adding a node before any scale-down is considered (e.g., 15m0s)"
  type        = string
  default     = "15m0s"
}

variable "autoscaler_scale_down_delay_after_delete" {
  description = "Cooldown after deleting a node before the next scale-down (e.g., 30m0s)"
  type        = string
  default     = "30m0s"
}

variable "autoscaler_scale_down_utilization_threshold" {
  description = "CPU/memory request utilization below which a node is considered unneeded (0.0–1.0)"
  type        = string
  default     = "0.5"
}

# -----------------------------------------------------------------------------
# NTP Servers (optional — if empty, chrony uses default public pools)
# -----------------------------------------------------------------------------

variable "ntp_servers" {
  description = "Space-separated list of NTP server hostnames (optional)"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Docker Hub Auth (rate-limit workaround until Harbor mirrors are in place)
# -----------------------------------------------------------------------------

variable "dockerhub_username" {
  description = "Docker Hub username for authenticated pulls"
  type        = string
  default     = ""
}

variable "dockerhub_token" {
  description = "Docker Hub personal access token"
  type        = string
  sensitive   = true
  default     = ""
}

# -----------------------------------------------------------------------------
# Harbor Registry
# -----------------------------------------------------------------------------

variable "harbor_fqdn" {
  description = "Harbor registry FQDN (e.g., <your-harbor>)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+[a-z0-9]$", var.harbor_fqdn))
    error_message = "harbor_fqdn must be a valid hostname."
  }
}

variable "harbor_registry_mirrors" {
  description = "Upstream container registries to mirror through Harbor proxy-cache"
  type        = list(string)
  default     = ["docker.io", "quay.io", "ghcr.io", "gcr.io", "registry.k8s.io", "docker.elastic.co", "registry.gitlab.com", "docker-registry1.mariadb.com", "docker-registry2.mariadb.com", "docker-registry3.mariadb.com", "dhi.io", "oci.external-secrets.io"]

  validation {
    condition     = alltrue([for m in var.harbor_registry_mirrors : can(regex("^[a-z0-9][a-z0-9.-]+[a-z0-9]$", m))])
    error_message = "Each harbor_registry_mirror must be a valid registry hostname."
  }
}

# -----------------------------------------------------------------------------
# Cloud Provider
# -----------------------------------------------------------------------------

variable "harvester_cloud_credential_name" {
  description = "Name of the pre-existing Harvester cloud credential in Rancher"
  type        = string
}

variable "harvester_cloud_provider_kubeconfig_path" {
  description = "Path to the Harvester cloud provider kubeconfig file"
  type        = string
}

# -----------------------------------------------------------------------------
# SSH
# -----------------------------------------------------------------------------

variable "ssh_user" {
  description = "SSH user for the cloud image"
  type        = string
  default     = "rocky"
}

variable "ssh_authorized_keys" {
  description = "List of SSH public keys to add to all nodes"
  type        = list(string)
}

# -----------------------------------------------------------------------------
# Registry / Bootstrap
# -----------------------------------------------------------------------------

variable "private_ca_pem" {
  description = "PEM-encoded private CA certificate chain (used for registry and internal service TLS trust)"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("-----BEGIN CERTIFICATE-----[\\s\\S]+-----END CERTIFICATE-----", var.private_ca_pem))
    error_message = "private_ca_pem must contain a complete PEM certificate block (BEGIN and END markers required)."
  }
}

variable "bootstrap_registry" {
  description = "Hostname of the pre-existing container registry for initial containerd mirrors (no scheme — cluster.tf prepends https://). Used before configure_rancher_registries patches to Harbor."
  type        = string

  validation {
    condition     = length(var.bootstrap_registry) > 0
    error_message = "bootstrap_registry is required — containerd mirrors need a registry endpoint at first boot."
  }

  validation {
    condition     = !can(regex("^https?://", var.bootstrap_registry))
    error_message = "bootstrap_registry must be hostname-only (no http:// or https:// prefix); cluster.tf prepends https:// itself. A scheme here renders as https://https://<host>."
  }
}

variable "bootstrap_registry_ca_pem" {
  description = "PEM-encoded CA cert for bootstrap registry TLS (if different from private_ca_pem)"
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.bootstrap_registry_ca_pem == "" || can(regex("-----BEGIN CERTIFICATE-----[\\s\\S]+-----END CERTIFICATE-----", var.bootstrap_registry_ca_pem))
    error_message = "bootstrap_registry_ca_pem must be empty or contain a complete PEM certificate block."
  }
}

# -----------------------------------------------------------------------------
# Operator Deployment
# -----------------------------------------------------------------------------

variable "deploy_operators" {
  description = "Deploy operators after cluster creation (node-labeler, storage-autoscaler, cluster-autoscaler, and optionally DB operators). Default OFF — production uses Fleet GitOps."
  type        = bool
  default     = false
}

variable "deploy_cluster_autoscaler" {
  description = "Deploy Kubernetes cluster-autoscaler with Rancher cloud provider (requires deploy_operators = true)"
  type        = bool
  default     = false
}

variable "deploy_cnpg" {
  description = "Deploy CloudNativePG operator (requires deploy_operators = true)"
  type        = bool
  default     = false
}

variable "deploy_mariadb_operator" {
  description = "Deploy MariaDB Operator (requires deploy_operators = true)"
  type        = bool
  default     = false
}

variable "deploy_redis_operator" {
  description = "Deploy OpsTree Redis Operator (requires deploy_operators = true)"
  type        = bool
  default     = false
}

variable "harbor_admin_user" {
  description = "Harbor username for pushing operator images (required when deploy_operators = true)"
  type        = string
  default     = "admin"
}

variable "harbor_admin_password" {
  description = "Harbor admin password for pushing operator images (required when deploy_operators = true)"
  type        = string
  sensitive   = true
  default     = ""
}

# -----------------------------------------------------------------------------
# Per-pool live migration policy (KubeVirt allowPostCopy)
# -----------------------------------------------------------------------------
# See docs/operations.md#live-migration-policy-per-node-pool for the
# pre-copy vs post-copy trade-off.

variable "cp_allow_post_copy" {
  description = "Allow KubeVirt post-copy live migration for the controlplane pool. KEEP false — etcd leader loss on post-copy failure is too costly."
  type        = bool
  default     = false
}

variable "general_allow_post_copy" {
  description = "Allow KubeVirt post-copy live migration for the general worker pool. Default false for mixed-workload safety."
  type        = bool
  default     = false
}

variable "compute_allow_post_copy" {
  description = "Allow KubeVirt post-copy live migration for the compute worker pool. Default false for mixed-workload safety."
  type        = bool
  default     = false
}

variable "database_allow_post_copy" {
  description = "Allow KubeVirt post-copy live migration for the database worker pool. Default true — Postgres commits to WAL, so in-memory state loss is acceptable, and pre-copy frequently fails to converge under write load."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Cluster Autoscaler — Helm chart + image (Harbor OCI)
# -----------------------------------------------------------------------------
# Source once via TF; Fleet HelmOp takes over version/values after bootstrap.
# lifecycle.ignore_changes on helm_release prevents TF/Fleet tug-of-war.

variable "cluster_autoscaler_chart_repository" {
  description = "OCI repo path for cluster-autoscaler chart (must exist before first apply). Override per-cluster in tfvars to point at your Harbor/registry proxy."
  type        = string
  default     = "oci://registry.k8s.io/autoscaling/cluster-autoscaler"
}

variable "cluster_autoscaler_chart_version" {
  description = "Chart version for cluster-autoscaler. Must be compatible with kubernetes_version."
  type        = string
  default     = "9.40.0"
}

variable "cluster_autoscaler_image_repository" {
  description = "Container image repo for cluster-autoscaler. Override per-cluster in tfvars (typically <your-harbor>/registry.k8s.io/autoscaling/cluster-autoscaler when using a proxy-cache)."
  type        = string
  default     = "registry.k8s.io/autoscaling/cluster-autoscaler"
}

variable "cluster_autoscaler_image_tag" {
  description = "Container image tag for cluster-autoscaler. Should track kubernetes_version (e.g. v1.34.3 for K8s 1.34)."
  type        = string
  default     = "v1.34.3"
}

# -----------------------------------------------------------------------------
# Storage Autoscaler — Helm chart + image (Harbor OCI)
# -----------------------------------------------------------------------------

variable "storage_autoscaler_chart_repository" {
  description = "OCI repo path for storage-autoscaler chart (in-house chart). REQUIRED — set per-cluster in tfvars to your registry, e.g. oci://<your-harbor>/library."
  type        = string
  default     = ""

  validation {
    condition     = length(var.storage_autoscaler_chart_repository) > 0
    error_message = "storage_autoscaler_chart_repository must be set in tfvars (no public default — this is an in-house chart)."
  }
}

variable "storage_autoscaler_chart_version" {
  description = "Chart version for storage-autoscaler (in-house chart; tracks appVersion)."
  type        = string
  default     = "0.7.0"
}

variable "storage_autoscaler_image_repository" {
  description = "Container image repo for storage-autoscaler (in-house image). REQUIRED — set per-cluster in tfvars to your registry, e.g. <your-harbor>/library/storage-autoscaler."
  type        = string
  default     = ""

  validation {
    condition     = length(var.storage_autoscaler_image_repository) > 0
    error_message = "storage_autoscaler_image_repository must be set in tfvars (no public default — this is an in-house image)."
  }
}

variable "storage_autoscaler_image_tag" {
  description = "Container image tag for storage-autoscaler (matches chart appVersion by default)."
  type        = string
  default     = "v0.7.0"
}

# -----------------------------------------------------------------------------
# Shape B-2 — Dedicated LB + Ingress pools (workaround for cilium #44630)
# -----------------------------------------------------------------------------
# When enabled:
#   - new `lb` pool (workload-type=lb, taint NoSchedule) hosts only the
#     Cilium L2 announcer; no Traefik or app workloads
#   - new `ingress` pool (workload-type=ingress, taint NoSchedule) hosts
#     only Traefik DS via chart_values nodeSelector + tolerations
#   - existing general/compute/database pools become single-NIC (no eth1)
#     and use user_data_singlenic (no ingress-routing daemon)
#   - Cilium L2 policy nodeSelector flips from `control-plane=DoesNotExist`
#     to `workload-type=lb`
# Sidesteps cilium/cilium#44630 same-node DNAT bug by guaranteeing the
# L2 announcer node never has a local Traefik backend.
# -----------------------------------------------------------------------------

variable "enable_dedicated_ingress_pool" {
  description = "Enable Shape B-2: dedicated lb + ingress pools + single-NIC workers. Default TRUE — Shape B-2 is the de-facto standard since 2026-04-26 (cilium #44630 architectural workaround validated end-to-end with 0% loss vs 13% baseline; deployed on both rke2-test and rke2-prod). Set false only when reverting to the legacy single-pool layout."
  type        = bool
  default     = true
}

# LB pool — Cilium L2 announce only
variable "lb_count" {
  description = "Number of nodes in the lb pool (Shape B-2). Recommend ≥2 for L2 lease HA."
  type        = number
  default     = 2
}

variable "lb_cpu" {
  description = "vCPUs per lb pool node"
  type        = string
  default     = "1"
}

variable "lb_memory" {
  description = "Memory (GiB) per lb pool node"
  type        = string
  default     = "2"
}

variable "lb_disk_size" {
  description = "Disk size (GiB) per lb pool node"
  type        = number
  default     = 20
}

variable "lb_allow_post_copy" {
  description = "Allow KubeVirt post-copy live migration for the lb pool. KEEP false — L2 announcer needs predictable failover."
  type        = bool
  default     = false
}

# Ingress pool — Traefik DS only (cluster-autoscaler-managed)
variable "ingress_min_count" {
  description = "Minimum number of ingress pool nodes (autoscaler-managed). Recommend ≥2 for Traefik HA."
  type        = number
  default     = 2
}

variable "ingress_max_count" {
  description = "Maximum number of ingress pool nodes (autoscaler-managed). Scales up under load when Traefik throughput is constrained."
  type        = number
  default     = 4
}

variable "ingress_cpu" {
  description = "vCPUs per ingress pool node"
  type        = string
  default     = "2"
}

variable "ingress_memory" {
  description = "Memory (GiB) per ingress pool node"
  type        = string
  default     = "4"
}

variable "ingress_disk_size" {
  description = "Disk size (GiB) per ingress pool node"
  type        = number
  default     = 20
}

variable "ingress_allow_post_copy" {
  description = "Allow KubeVirt post-copy live migration for the ingress pool. KEEP false — pre-copy preserves connection state better for in-flight HTTPS."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Rotation marker
# -----------------------------------------------------------------------------
# Free-form string interpolated as a comment into every node's cloud-init.
# Changing this value forces a cloud-init hash change → CAPI rolling
# replacement of every VM in the cluster (one pool at a time, surge-then-drain).
# Use ISO date + reason: "2026-04-26-shape-b2-validation".
# Empty default = no rotation forced.
variable "rotation_marker" {
  description = "Cloud-init comment marker — changing this triggers a full rolling VM replacement via CAPI"
  type        = string
  default     = ""
}

# NOTE: `manage_vm_eviction_reconciler` was removed 2026-05-03. The Harvester-
# host CronJob that reconciles VM eviction strategy now lives at
# `addons/vm-eviction-reconciler.yaml` (applied via `kubectl apply` against
# the Harvester local cluster, not via per-RKE2 Terraform workspaces). See
# `vm_eviction_strategy.tf` for the per-cluster one-shot patch that stays
# under Terraform.
