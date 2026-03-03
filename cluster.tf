# -----------------------------------------------------------------------------
# Docker Hub registry auth secret (avoids anonymous pull rate limits)
# Created in fleet-default on the local (Rancher) cluster so RKE2 nodes
# pick it up via registries.yaml.
# -----------------------------------------------------------------------------
resource "rancher2_secret_v2" "dockerhub_auth" {
  count      = var.dockerhub_username != "" ? 1 : 0
  cluster_id = "local"
  name       = "${var.cluster_name}-dockerhub-auth"
  namespace  = "fleet-default"
  type       = "kubernetes.io/basic-auth"
  data = {
    username = var.dockerhub_username
    password = var.dockerhub_token
  }

}

resource "rancher2_cluster_v2" "rke2" {
  name                         = var.cluster_name
  kubernetes_version           = var.kubernetes_version
  cloud_credential_secret_name = rancher2_cloud_credential.harvester.id

  # Cluster Autoscaler scale-down behavior
  annotations = {
    "cluster.provisioning.cattle.io/autoscaler-scale-down-unneeded-time"         = var.autoscaler_scale_down_unneeded_time
    "cluster.provisioning.cattle.io/autoscaler-scale-down-delay-after-add"       = var.autoscaler_scale_down_delay_after_add
    "cluster.provisioning.cattle.io/autoscaler-scale-down-delay-after-delete"    = var.autoscaler_scale_down_delay_after_delete
    "cluster.provisioning.cattle.io/autoscaler-scale-down-utilization-threshold" = var.autoscaler_scale_down_utilization_threshold
  }

  rke_config {
    # -----------------------------------------------------------------
    # Pool 1: Control Plane (dedicated — no workloads)
    # -----------------------------------------------------------------
    machine_pools {
      name                         = "controlplane"
      cloud_credential_secret_name = rancher2_cloud_credential.harvester.id
      control_plane_role           = true
      etcd_role                    = true
      worker_role                  = false
      quantity                     = var.controlplane_count
      drain_before_delete          = true

      machine_config {
        kind = rancher2_machine_config_v2.controlplane.kind
        name = rancher2_machine_config_v2.controlplane.name
      }

      rolling_update {
        max_unavailable = "0"
        max_surge       = "1"
      }
    }

    # -----------------------------------------------------------------
    # Pool 2: General Workers (autoscale 4–10)
    # -----------------------------------------------------------------
    machine_pools {
      name                         = "general"
      cloud_credential_secret_name = rancher2_cloud_credential.harvester.id
      control_plane_role           = false
      etcd_role                    = false
      worker_role                  = true
      quantity                     = var.general_min_count
      drain_before_delete          = true

      machine_config {
        kind = rancher2_machine_config_v2.general.kind
        name = rancher2_machine_config_v2.general.name
      }

      rolling_update {
        max_unavailable = "0"
        max_surge       = "1"
      }

      labels = {
        "workload-type" = "general"
      }

      annotations = {
        "cluster.provisioning.cattle.io/autoscaler-min-size" = tostring(var.general_min_count)
        "cluster.provisioning.cattle.io/autoscaler-max-size" = tostring(var.general_max_count)
      }
    }

    # -----------------------------------------------------------------
    # Pool 3: Compute Workers (autoscale 4–10, scale from zero)
    # -----------------------------------------------------------------
    machine_pools {
      name                         = "compute"
      cloud_credential_secret_name = rancher2_cloud_credential.harvester.id
      control_plane_role           = false
      etcd_role                    = false
      worker_role                  = true
      quantity                     = var.compute_min_count
      drain_before_delete          = true

      machine_config {
        kind = rancher2_machine_config_v2.compute.kind
        name = rancher2_machine_config_v2.compute.name
      }

      rolling_update {
        max_unavailable = "0"
        max_surge       = "1"
      }

      labels = {
        "workload-type" = "compute"
      }

      annotations = {
        "cluster.provisioning.cattle.io/autoscaler-min-size" = tostring(var.compute_min_count)
        "cluster.provisioning.cattle.io/autoscaler-max-size" = tostring(var.compute_max_count)
        # Scale-from-zero: resource annotations so the autoscaler knows
        # what capacity a new node in this pool would provide.
        "cluster.provisioning.cattle.io/autoscaler-resource-cpu"     = var.compute_cpu
        "cluster.provisioning.cattle.io/autoscaler-resource-memory"  = "${var.compute_memory}Gi"
        "cluster.provisioning.cattle.io/autoscaler-resource-storage" = "${var.compute_disk_size}Gi"
      }
    }

    # -----------------------------------------------------------------
    # Pool 4: Database Workers (autoscale 4–10)
    # -----------------------------------------------------------------
    machine_pools {
      name                         = "database"
      cloud_credential_secret_name = rancher2_cloud_credential.harvester.id
      control_plane_role           = false
      etcd_role                    = false
      worker_role                  = true
      quantity                     = var.database_min_count
      drain_before_delete          = true

      machine_config {
        kind = rancher2_machine_config_v2.database.kind
        name = rancher2_machine_config_v2.database.name
      }

      rolling_update {
        max_unavailable = "0"
        max_surge       = "1"
      }

      labels = {
        "workload-type" = "database"
      }

      annotations = {
        "cluster.provisioning.cattle.io/autoscaler-min-size" = tostring(var.database_min_count)
        "cluster.provisioning.cattle.io/autoscaler-max-size" = tostring(var.database_max_count)
      }
    }

    # -----------------------------------------------------------------
    # Harvester Cloud Provider
    # -----------------------------------------------------------------
    machine_selector_config {
      config = yamlencode({
        cloud-provider-config = file(var.harvester_cloud_provider_kubeconfig_path)
        cloud-provider-name   = "harvester"
      })
    }

    # Per-pool node labels (kubelet --node-labels via RKE2 machine_selector_config)
    # NOTE: node-role.kubernetes.io/* labels are applied via label_unlabeled_nodes()
    # in deploy-cluster.sh because NodeRestriction prevents kubelet from setting them.
    machine_selector_config {
      config = yamlencode({ node-label = ["workload-type=general"] })
      machine_label_selector {
        match_labels = { "rke.cattle.io/rke-machine-pool-name" = "general" }
      }
    }

    machine_selector_config {
      config = yamlencode({ node-label = ["workload-type=compute"] })
      machine_label_selector {
        match_labels = { "rke.cattle.io/rke-machine-pool-name" = "compute" }
      }
    }

    machine_selector_config {
      config = yamlencode({ node-label = ["workload-type=database"] })
      machine_label_selector {
        match_labels = { "rke.cattle.io/rke-machine-pool-name" = "database" }
      }
    }

    chart_values = yamlencode({
      "harvester-cloud-provider" = {
        clusterName     = var.cluster_name
        cloudConfigPath = "/var/lib/rancher/rke2/etc/config-files/cloud-provider-config"
      }

      "rke2-cilium" = {
        kubeProxyReplacement = true
        k8sServiceHost       = "127.0.0.1"
        k8sServicePort       = 6443

        l2announcements = { enabled = true }
        externalIPs     = { enabled = true }
        gatewayAPI      = { enabled = true }

        operator = { replicas = 1 }

        hubble = {
          enabled = true
          relay   = { enabled = true }
          ui      = { enabled = true }
        }

        prometheus = { enabled = true }

        k8sClientRateLimit = {
          qps   = 25
          burst = 50
        }
      }

      "rke2-traefik" = {
        service = {
          type = "LoadBalancer"
          spec = {
            loadBalancerIP = var.traefik_lb_ip
          }
        }
        providers = {
          kubernetesGateway = { enabled = true, experimentalChannel = true }
        }
        logs = {
          access = { enabled = true }
        }
        ports = {
          web = {
            redirections = {
              entryPoint = { to = "websecure", scheme = "https" }
            }
          }
          ssh = {
            port        = 2222
            expose      = { default = true }
            exposedPort = 22
            protocol    = "TCP"
          }
        }
        volumes = [
          { name = "vault-root-ca", mountPath = "/vault-ca", type = "configMap" },
          { name = "combined-ca", mountPath = "/combined-ca", type = "emptyDir" }
        ]
        deployment = {
          initContainers = [{
            name    = "combine-ca"
            image   = "${var.harbor_fqdn}/library/alpine:3.21"
            command = ["sh", "-c", "cp /etc/ssl/certs/ca-certificates.crt /combined-ca/ca-certificates.crt 2>/dev/null || true; if [ -s /vault-ca/ca.crt ]; then cat /vault-ca/ca.crt >> /combined-ca/ca-certificates.crt; fi"]
            volumeMounts = [
              { name = "vault-root-ca", mountPath = "/vault-ca", readOnly = true },
              { name = "combined-ca", mountPath = "/combined-ca" }
            ]
          }]
        }
        env = [{ name = "SSL_CERT_FILE", value = "/combined-ca/ca-certificates.crt" }]
        additionalArguments = [
          "--api.dashboard=false",
          "--entryPoints.web.transport.respondingTimeouts.readTimeout=1800s",
          "--entryPoints.web.transport.respondingTimeouts.writeTimeout=1800s",
          "--entryPoints.websecure.transport.respondingTimeouts.readTimeout=1800s",
          "--entryPoints.websecure.transport.respondingTimeouts.writeTimeout=1800s"
        ]
      }
    })

    # -----------------------------------------------------------------
    # Global Machine Config
    # -----------------------------------------------------------------
    machine_global_config = yamlencode({
      cni                   = var.cni
      "disable-kube-proxy"  = true
      "disable"             = ["rke2-ingress-nginx"]
      "ingress-controller"  = "traefik"
      "etcd-expose-metrics" = true
      # NOTE: system-default-registry is intentionally NOT set.
      # It's incompatible with Harbor proxy-cache (rewrites paths wrong).
      # Containerd mirrors in the registries block handle all image routing.

      # NOTE: kube-apiserver OIDC args are added post-deploy (Phase 6) via
      # Rancher cluster config patching, not at cluster creation time.

      "kube-scheduler-arg"          = ["bind-address=0.0.0.0"]
      "kube-controller-manager-arg" = ["bind-address=0.0.0.0"]
    })

    # -----------------------------------------------------------------
    # Private Registry Config — Harbor proxy-cache mirrors
    # -----------------------------------------------------------------
    registries {
      # Docker Hub auth (avoids anonymous pull rate limits)
      dynamic "configs" {
        for_each = var.dockerhub_username != "" ? [1] : []
        content {
          hostname                = "docker.io"
          auth_config_secret_name = rancher2_secret_v2.dockerhub_auth[0].name
        }
      }

      # Harbor TLS config (private CA)
      configs {
        hostname  = var.harbor_fqdn
        ca_bundle = var.private_ca_pem
      }

      # Bootstrap registry TLS config (used during initial provisioning)
      configs {
        hostname  = var.bootstrap_registry
        ca_bundle = coalesce(var.bootstrap_registry_ca_pem, var.private_ca_pem)
      }

      # Registry mirrors — route pulls through bootstrap registry initially.
      # configure_rancher_registries() patches these to Harbor in Phase 4.
      dynamic "mirrors" {
        for_each = toset(var.harbor_registry_mirrors)
        content {
          hostname  = mirrors.value
          endpoints = ["https://${var.bootstrap_registry}"]
          rewrites  = { "^(.*)$" = "${mirrors.value}/$1" }
        }
      }
    }

    # -----------------------------------------------------------------
    # Upgrade Strategy
    # -----------------------------------------------------------------
    upgrade_strategy {
      control_plane_concurrency = "1"
      worker_concurrency        = "1"
    }

    # -----------------------------------------------------------------
    # Etcd Snapshots
    # -----------------------------------------------------------------
    etcd {
      snapshot_schedule_cron = "0 */6 * * *"
      snapshot_retention     = 5
    }
  }

  # EFI patches must complete before Rancher starts provisioning VMs
  depends_on = [
    null_resource.efi,
  ]

  # Ignore quantity drift from cluster autoscaler — Terraform manages min/max
  # annotations and machine config, but the autoscaler owns the live replica count.
  # New clusters get the initial quantity from variables; existing clusters keep
  # whatever the autoscaler has set.
  lifecycle {
    ignore_changes = [
      rke_config[0].machine_pools[1].quantity, # general
      rke_config[0].machine_pools[2].quantity, # compute
      rke_config[0].machine_pools[3].quantity, # database
      rke_config[0].registries,                # patched by configure_rancher_registries()
    ]
  }

  timeouts {
    create = "90m"
  }
}
