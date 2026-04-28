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

      machine_labels = {
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

      machine_labels = {
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

      machine_labels = {
        "workload-type" = "database"
      }

      annotations = {
        "cluster.provisioning.cattle.io/autoscaler-min-size" = tostring(var.database_min_count)
        "cluster.provisioning.cattle.io/autoscaler-max-size" = tostring(var.database_max_count)
      }
    }

    # -----------------------------------------------------------------
    # Pool 5 (Shape B-2 only): LB pool — Cilium L2 announcer, no Traefik.
    # Fixed-quantity (no autoscaler annotations). Tainted to keep app
    # workloads off; only Cilium agent + system DaemonSets land here.
    # -----------------------------------------------------------------
    dynamic "machine_pools" {
      for_each = var.enable_dedicated_ingress_pool ? [1] : []
      content {
        name                         = "lb"
        cloud_credential_secret_name = rancher2_cloud_credential.harvester.id
        control_plane_role           = false
        etcd_role                    = false
        worker_role                  = true
        quantity                     = var.lb_count
        drain_before_delete          = true

        machine_config {
          kind = rancher2_machine_config_v2.lb[0].kind
          name = rancher2_machine_config_v2.lb[0].name
        }

        rolling_update {
          max_unavailable = "0"
          max_surge       = "1"
        }

        labels = {
          "workload-type" = "lb"
        }

        machine_labels = {
          "workload-type" = "lb"
        }

        taints {
          key    = "workload-type"
          value  = "lb"
          effect = "NoSchedule"
        }
      }
    }

    # -----------------------------------------------------------------
    # Pool 6 (Shape B-2 only): Ingress pool — Traefik DS only, no L2.
    # Cluster-autoscaler managed (min/max via tfvars). Initial quantity
    # uses min_count; autoscaler scales up to max under load. Tainted;
    # Traefik DS tolerates via chart_values rke2-traefik.tolerations.
    # -----------------------------------------------------------------
    dynamic "machine_pools" {
      for_each = var.enable_dedicated_ingress_pool ? [1] : []
      content {
        name                         = "ingress"
        cloud_credential_secret_name = rancher2_cloud_credential.harvester.id
        control_plane_role           = false
        etcd_role                    = false
        worker_role                  = true
        quantity                     = var.ingress_min_count
        drain_before_delete          = true

        machine_config {
          kind = rancher2_machine_config_v2.ingress[0].kind
          name = rancher2_machine_config_v2.ingress[0].name
        }

        rolling_update {
          max_unavailable = "0"
          max_surge       = "1"
        }

        labels = {
          "workload-type" = "ingress"
        }

        machine_labels = {
          "workload-type" = "ingress"
        }

        taints {
          key    = "workload-type"
          value  = "ingress"
          effect = "NoSchedule"
        }

        annotations = {
          "cluster.provisioning.cattle.io/autoscaler-min-size" = tostring(var.ingress_min_count)
          "cluster.provisioning.cattle.io/autoscaler-max-size" = tostring(var.ingress_max_count)
        }
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

    # NOTE: Per-pool workload-type labels are applied via machine_labels on each
    # pool (propagates to CAPI Machine AND K8s node). The node-label field in
    # machineSelectorConfig is silently dropped by Rancher's metadata service.
    # See: https://github.com/rancher/terraform-provider-rancher2/issues/2119
    #
    # node-role.kubernetes.io/* labels are still applied via label_unlabeled_nodes()
    # in deploy-cluster.sh because NodeRestriction prevents kubelet from setting them.

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

        # Pin Cilium to v1.19.3 to fix BPF lb slot-gap bug present in v1.19.1
        # (RKE2 v1.34.5+rke2r1 bundles 1.19.1). Upstream fix lives in v1.19.2+;
        # 1.19.3 is the latest patch as of 2026-04-26. See
        # docs/plans/2026-04-26-cilium-1.19-bpf-lb-slot-drift-fix.md.
        # Pull through Harbor's quay.io proxy-cache.
        image = {
          repository = "harbor.example.com/quay.io/cilium/cilium"
          tag        = "v1.19.3"
          useDigest  = false
        }

        operator = {
          replicas = 1
          image = {
            # Cilium chart template renders operator image as
            # `<repository>-<cloudFlavor><suffix>` where cloudFlavor defaults
            # to "generic". So to get the standard "operator-generic" image,
            # set repository to "operator" and leave suffix as the default "".
            repository = "harbor.example.com/quay.io/cilium/operator"
            tag        = "v1.19.3"
            useDigest  = false
          }
        }

        hubble = {
          enabled = true
          relay = {
            enabled = true
            image = {
              repository = "harbor.example.com/quay.io/cilium/hubble-relay"
              tag        = "v1.19.3"
              useDigest  = false
            }
          }
          ui = {
            enabled = true
            backend = {
              image = {
                repository = "harbor.example.com/quay.io/cilium/hubble-ui-backend"
                tag        = "v0.13.3"
                useDigest  = false
              }
            }
            frontend = {
              image = {
                repository = "harbor.example.com/quay.io/cilium/hubble-ui"
                tag        = "v0.13.3"
                useDigest  = false
              }
            }
          }
        }

        prometheus = { enabled = true }

        # Bumped from qps=25/burst=50; reduces reconcile throttling on a
        # 13-node cluster. See design doc "Cluster configuration check" table.
        k8sClientRateLimit = {
          qps   = 50
          burst = 100
        }
      }

      # Shape B-2: when enable_dedicated_ingress_pool=true, Traefik DS pins
      # to nodes with `workload-type=ingress` and tolerates the matching
      # NoSchedule taint. When false, both keys are null — Helm's templates
      # treat null as absent (`{{- if .Values.nodeSelector }}` is falsy on
      # null) so the legacy "schedule everywhere" behavior is preserved.
      # Sidesteps cilium #44630 by ensuring the L2 announcer (lb pool) never
      # has a local Traefik backend.
      "rke2-traefik" = {
        nodeSelector = var.enable_dedicated_ingress_pool ? {
          "workload-type" = "ingress"
        } : null
        tolerations = var.enable_dedicated_ingress_pool ? [{
          key      = "workload-type"
          operator = "Equal"
          value    = "ingress"
          effect   = "NoSchedule"
        }] : null

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
            image   = "docker.io/library/alpine:3.21"
            command = ["sh", "-c", "cp /etc/ssl/certs/ca-certificates.crt /combined-ca/ca-certificates.crt 2>/dev/null || true; if [ -s /vault-ca/ca.crt ]; then cat /vault-ca/ca.crt >> /combined-ca/ca-certificates.crt; fi"]
            volumeMounts = [
              { name = "vault-root-ca", mountPath = "/vault-ca", readOnly = true },
              { name = "combined-ca", mountPath = "/combined-ca" }
            ]
          }]
        }
        env = [{ name = "SSL_CERT_FILE", value = "/combined-ca/ca-certificates.crt" }]
        additionalArguments = [
          "--api.dashboard=true",
          "--api.insecure=true",
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

  # Ignore drift on fields Rancher or the cluster-autoscaler owns:
  #   - machine_pools[N].quantity — cluster-autoscaler owns live replica count;
  #     Terraform only seeds the initial quantity from variables.
  #   - machine_selector_config — Rancher's admission webhook auto-extracts
  #     sensitive inline config (e.g. cloud-provider-config kubeconfig) into
  #     an owner-referenced Secret and rewrites the live value as
  #     `secret://<ns>:<name>`. Without this ignore, every plan shows a
  #     permanent diff (inline YAML ↔ secret:// reference).
  lifecycle {
    ignore_changes = [
      rke_config[0].machine_pools[1].quantity, # general
      rke_config[0].machine_pools[2].quantity, # compute
      rke_config[0].machine_pools[3].quantity, # database
      rke_config[0].machine_pools[5].quantity, # ingress (Shape B-2 only — autoscaled)
      rke_config[0].machine_selector_config,   # Rancher normalizes inline → secret://
    ]
  }

  timeouts {
    create = "90m"
  }
}
