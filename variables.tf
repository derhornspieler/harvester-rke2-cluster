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
  description = "Harbor registry FQDN (e.g., harbor.example.com)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+[a-z0-9]$", var.harbor_fqdn))
    error_message = "harbor_fqdn must be a valid hostname."
  }
}

variable "harbor_registry_mirrors" {
  description = "Upstream container registries to mirror through Harbor proxy-cache"
  type        = list(string)
  default     = ["docker.io", "quay.io", "ghcr.io", "gcr.io", "registry.k8s.io", "docker.elastic.co", "registry.gitlab.com", "docker-registry1.mariadb.com", "docker-registry2.mariadb.com", "docker-registry3.mariadb.com"]

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
  description = "Pre-existing container registry for initial containerd mirrors (used before configure_rancher_registries patches to Harbor)"
  type        = string

  validation {
    condition     = length(var.bootstrap_registry) > 0
    error_message = "bootstrap_registry is required — containerd mirrors need a registry endpoint at first boot."
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
  description = "Deploy operators after cluster creation (node-labeler, storage-autoscaler, and optionally DB operators)"
  type        = bool
  default     = true
}

variable "deploy_cnpg" {
  description = "Deploy CloudNativePG operator (requires deploy_operators = true)"
  type        = bool
  default     = true
}

variable "deploy_mariadb_operator" {
  description = "Deploy MariaDB Operator (requires deploy_operators = true)"
  type        = bool
  default     = false
}

variable "deploy_redis_operator" {
  description = "Deploy OpsTree Redis Operator (requires deploy_operators = true)"
  type        = bool
  default     = true
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
