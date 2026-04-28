# -----------------------------------------------------------------------------
# Operator Deployment — node-labeler, storage-autoscaler, cluster-autoscaler, DB operators
# -----------------------------------------------------------------------------
# Pushes pre-built custom operator images to Harbor, then deploys all
# operators via kubectl. Gated by var.deploy_operators (default: true).
# DB operators individually gated by var.deploy_cnpg, var.deploy_mariadb_operator,
# var.deploy_redis_operator (each requires deploy_operators = true).
#
# DB operators use upstream image references (ghcr.io, quay.io) directly;
# RKE2 registries.yaml handles transparent rewrite to Harbor proxy-cache.
#
# Dependency chain:
#   rancher2_cluster_v2.rke2
#     -> null_resource.operator_kubeconfig
#       -> null_resource.operator_image_push
#         -> null_resource.deploy_node_labeler          (parallel)
#         -> null_resource.storage_autoscaler_crd       (parallel)
#           -> helm_release.storage_autoscaler
#       -> null_resource.deploy_cnpg                    (parallel)
#       -> null_resource.deploy_mariadb_operator        (parallel)
#       -> null_resource.deploy_redis_operator          (parallel)
#       -> null_resource.cluster_autoscaler_secrets     (parallel)
#         -> helm_release.cluster_autoscaler
# -----------------------------------------------------------------------------

locals {
  operators = {
    node-labeler = {
      version = "v0.2.0"
    }
    storage-autoscaler = {
      version = "v0.2.0"
    }
  }

  db_operators = {
    cnpg = {
      version   = "1.28.1"
      namespace = "cnpg-system"
    }
    mariadb-operator = {
      version   = "25.10.4"
      namespace = "mariadb-operator"
    }
    redis-operator = {
      version   = "v0.23.0"
      namespace = "redis-operator"
    }
  }

  operator_kubeconfig = "${path.module}/.kubeconfig-rke2-operators"
  rendered_dir        = "${path.module}/.rendered"
}

# -----------------------------------------------------------------------------
# Kubeconfig + Rendered Templates — written via shell (no hashicorp/local)
# -----------------------------------------------------------------------------

resource "null_resource" "operator_kubeconfig" {
  count = var.deploy_operators ? 1 : 0

  # always_run forces this resource to re-run on every apply. Required because
  # the shared on-disk path (`.kubeconfig-rke2-operators`) is a local file not
  # tracked by TF state — if a sibling workspace (e.g. rke2-prod) wrote to it
  # last, this workspace's autoscaler deploy would aim at the wrong cluster.
  # Regenerating the file on every apply keeps it aligned with THIS workspace's
  # rancher2_cluster_v2.rke2.kube_config.
  triggers = {
    cluster_id = rancher2_cluster_v2.rke2.id
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -euo pipefail
      mkdir -p "${local.rendered_dir}"

      # Write kubeconfig
      cat > "${local.operator_kubeconfig}" <<'KUBECONFIG'
      ${rancher2_cluster_v2.rke2.kube_config}
      KUBECONFIG
      chmod 600 "${local.operator_kubeconfig}"

      # Render node-labeler deployment template
      sed \
        -e 's|$${harbor_fqdn}|${var.harbor_fqdn}|g' \
        -e 's|$${version}|${local.operators["node-labeler"].version}|g' \
        "${path.module}/../operators/templates/node-labeler-deployment.yaml.tftpl" \
        > "${local.rendered_dir}/node-labeler-deployment.yaml"

      # Note: DB operator templates no longer rendered here.
      # DB operators use upstream install manifests from operators/upstream/
      # with nodeSelector patched at deploy time.
    SCRIPT
  }

  depends_on = [
    rancher2_cluster_v2.rke2,
  ]
}

# -----------------------------------------------------------------------------
# Image Push — crane pushes custom operator tarballs to Harbor
# -----------------------------------------------------------------------------

resource "null_resource" "operator_image_push" {
  count = var.deploy_operators ? 1 : 0

  triggers = {
    cluster_id                 = rancher2_cluster_v2.rke2.id
    node_labeler_version       = local.operators["node-labeler"].version
    storage_autoscaler_version = local.operators["storage-autoscaler"].version
  }

  provisioner "local-exec" {
    command = "${path.module}/../operators/push-images.sh"
    environment = {
      HARBOR_FQDN     = var.harbor_fqdn
      HARBOR_USER     = var.harbor_admin_user
      HARBOR_PASSWORD = var.harbor_admin_password
      HARBOR_CA_PEM   = var.private_ca_pem
      IMAGES_DIR      = "${path.module}/../operators/images"
    }
  }

  lifecycle {
    # harbor_admin_password is optional — harbor.example.com's /library
    # project is configured for anonymous read/write, so push-images.sh
    # will skip the auth login when HARBOR_PASSWORD is empty and rely on
    # the anonymous idempotency check to skip already-present images.
  }

  depends_on = [
    null_resource.operator_kubeconfig,
  ]
}

# -----------------------------------------------------------------------------
# Deploy: node-labeler
# -----------------------------------------------------------------------------

resource "null_resource" "deploy_node_labeler" {
  # Intentionally disabled — node labels are now applied directly via
  # rancher2_machine_config_v2.machine_labels in machine_config.tf (fixed
  # 2026-04-02 via GitHub issue rancher/terraform-provider-rancher2#2119).
  # node-labeler operator is redundant + adds maintenance burden. Keeping
  # the resource stanza for easy re-enable by setting count = 1 if needed.
  count = 0

  triggers = {
    cluster_id = rancher2_cluster_v2.rke2.id
    version    = local.operators["node-labeler"].version
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -euo pipefail
      export KUBECONFIG="${local.operator_kubeconfig}"

      echo "Waiting for nodes to be Ready..."
      kubectl wait --for=condition=Ready node --all --timeout=600s

      # Wait for Rancher webhook to be ready — it validates namespace
      # creation and rejects requests if its endpoints aren't available
      echo "Waiting for Rancher webhook endpoints..."
      until kubectl get endpoints rancher-webhook -n cattle-system -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; do
        sleep 5
      done
      echo "Rancher webhook is ready."

      # Bootstrap workload-type labels on initial nodes (node-labeler
      # will maintain these going forward, but it needs the labels to
      # schedule in the first place)
      echo "Bootstrapping workload-type labels on nodes..."
      for node in $(kubectl get nodes -o name | grep general); do
        kubectl label "$node" workload-type=general --overwrite
      done
      for node in $(kubectl get nodes -o name | grep database); do
        kubectl label "$node" workload-type=database --overwrite
      done
      for node in $(kubectl get nodes -o name | grep compute); do
        kubectl label "$node" workload-type=compute --overwrite
      done

      echo "Deploying node-labeler ${local.operators["node-labeler"].version}..."

      # Apply static manifests (namespace, rbac, service, hpa, networkpolicy)
      for f in namespace.yaml rbac.yaml service.yaml hpa.yaml; do
        kubectl apply -f "${path.module}/../operators/manifests/node-labeler/$f"
      done

      # Apply rendered deployment (with correct Harbor image reference)
      kubectl apply -f "${local.rendered_dir}/node-labeler-deployment.yaml"

      echo "node-labeler deployed successfully."
    SCRIPT
  }

  depends_on = [
    null_resource.operator_image_push,
  ]
}

# -----------------------------------------------------------------------------
# Storage Autoscaler — CRD (applied outside Helm)
# -----------------------------------------------------------------------------
# Kept outside the chart because Helm's CRD lifecycle is fragile (no upgrade
# of existing CRDs, delete-on-uninstall removes all CRs). Apply server-side
# with kubectl to match what Fleet will do once it takes over.

resource "null_resource" "storage_autoscaler_crd" {
  count = var.deploy_operators ? 1 : 0

  triggers = {
    cluster_id      = rancher2_cluster_v2.rke2.id
    crd_hash        = filemd5("${path.module}/../operators/manifests/storage-autoscaler/crd.yaml")
    kubeconfig_hash = md5(rancher2_cluster_v2.rke2.kube_config)
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -euo pipefail
      export KUBECONFIG="${local.operator_kubeconfig}"

      echo "Waiting for nodes to be Ready..."
      kubectl wait --for=condition=Ready node --all --timeout=600s

      echo "Applying storage-autoscaler CRD..."
      kubectl apply --server-side -f "${path.module}/../operators/manifests/storage-autoscaler/crd.yaml"
    SCRIPT
  }

  depends_on = [
    null_resource.operator_kubeconfig,
  ]
}

# -----------------------------------------------------------------------------
# Storage Autoscaler — helm_release
# -----------------------------------------------------------------------------
# One-time bootstrap install. Fleet HelmOp (out of scope for TF) takes over
# version/values via GitOps after first apply.
# lifecycle.ignore_changes keeps TF from reverting Fleet's upgrades.

resource "helm_release" "storage_autoscaler" {
  count = var.deploy_operators ? 1 : 0

  name             = "storage-autoscaler"
  namespace        = "storage-autoscaler"
  create_namespace = true # Helm preflight rejects install into missing ns; chart ns template removed
  repository       = var.storage_autoscaler_chart_repository
  chart            = "storage-autoscaler"
  version          = var.storage_autoscaler_chart_version

  timeout = 300
  wait    = true
  atomic  = false # let TF surface Helm failures rather than rolling back silently

  set {
    name  = "image.repository"
    value = var.storage_autoscaler_image_repository
  }
  set {
    name  = "image.tag"
    value = var.storage_autoscaler_image_tag
  }

  lifecycle {
    ignore_changes = [
      version,
      values,
      set,
      set_sensitive,
    ]
  }

  depends_on = [
    null_resource.storage_autoscaler_crd,
  ]
}

# -----------------------------------------------------------------------------
# Deploy: CloudNativePG (CNPG)
# -----------------------------------------------------------------------------

resource "null_resource" "deploy_cnpg" {
  count = var.deploy_operators && var.deploy_cnpg ? 1 : 0

  triggers = {
    cluster_id = rancher2_cluster_v2.rke2.id
    version    = local.db_operators["cnpg"].version
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -euo pipefail
      export KUBECONFIG="${local.operator_kubeconfig}"

      echo "Waiting for nodes to be Ready..."
      kubectl wait --for=condition=Ready node --all --timeout=600s

      echo "Deploying CloudNativePG ${local.db_operators["cnpg"].version}..."

      # Apply upstream install manifest (CRDs, RBAC, Deployment, Webhooks, Service — all-in-one)
      kubectl apply --server-side -f "${path.module}/../operators/upstream/cnpg-${local.db_operators["cnpg"].version}.yaml"

      # Patch deployment to schedule on database pool nodes
      kubectl patch deployment cnpg-controller-manager -n cnpg-system --type=json \
        -p '[{"op":"add","path":"/spec/template/spec/nodeSelector","value":{"workload-type":"database"}}]'

      # Apply our additions (NetworkPolicy, HPA, PDB)
      for f in hpa.yaml pdb.yaml; do
        kubectl apply -f "${path.module}/../operators/manifests/cnpg-system/$f"
      done

      # Wait for rollout to complete
      kubectl rollout status deployment/cnpg-controller-manager \
        -n cnpg-system --timeout=300s

      echo "CloudNativePG deployed successfully."
    SCRIPT
  }

  depends_on = [
    null_resource.deploy_node_labeler,
  ]
}

# -----------------------------------------------------------------------------
# Deploy: MariaDB Operator
# -----------------------------------------------------------------------------

resource "null_resource" "deploy_mariadb_operator" {
  count = var.deploy_operators && var.deploy_mariadb_operator ? 1 : 0

  triggers = {
    cluster_id = rancher2_cluster_v2.rke2.id
    version    = local.db_operators["mariadb-operator"].version
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -euo pipefail
      export KUBECONFIG="${local.operator_kubeconfig}"

      echo "Waiting for nodes to be Ready..."
      kubectl wait --for=condition=Ready node --all --timeout=600s

      echo "Deploying MariaDB Operator ${local.db_operators["mariadb-operator"].version}..."

      # Create namespace (helm template doesn't include it)
      kubectl create namespace mariadb-operator --dry-run=client -o yaml | kubectl apply -f -

      # Apply CRDs from separate chart (helm template --include-crds doesn't work)
      kubectl apply --server-side -f "${path.module}/../operators/upstream/mariadb-operator-crds-${local.db_operators["mariadb-operator"].version}.yaml"

      # Apply upstream Helm-rendered manifest (RBAC, Deployment, cert-controller, webhook)
      # Note: -n flag needed because helm template doesn't embed namespace in all resources
      kubectl apply --server-side -n mariadb-operator -f "${path.module}/../operators/upstream/mariadb-operator-${local.db_operators["mariadb-operator"].version}.yaml"

      # Patch deployments to schedule on database pool nodes
      for deploy in mariadb-operator mariadb-operator-cert-controller; do
        kubectl patch deployment "$deploy" -n mariadb-operator --type=json \
          -p '[{"op":"add","path":"/spec/template/spec/nodeSelector","value":{"workload-type":"database"}}]' 2>/dev/null || true
      done

      # Apply our additions (NetworkPolicy, HPA, PDB)
      for f in hpa.yaml pdb.yaml; do
        kubectl apply -f "${path.module}/../operators/manifests/mariadb-operator/$f"
      done

      # Wait for rollout to complete
      kubectl rollout status deployment/mariadb-operator \
        -n mariadb-operator --timeout=300s

      echo "MariaDB Operator deployed successfully."
    SCRIPT
  }

  depends_on = [
    null_resource.deploy_node_labeler,
  ]
}

# -----------------------------------------------------------------------------
# Deploy: Redis Operator (OpsTree)
# -----------------------------------------------------------------------------

resource "null_resource" "deploy_redis_operator" {
  count = var.deploy_operators && var.deploy_redis_operator ? 1 : 0

  triggers = {
    cluster_id = rancher2_cluster_v2.rke2.id
    version    = local.db_operators["redis-operator"].version
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -euo pipefail
      export KUBECONFIG="${local.operator_kubeconfig}"

      echo "Waiting for nodes to be Ready..."
      kubectl wait --for=condition=Ready node --all --timeout=600s

      echo "Deploying Redis Operator ${local.db_operators["redis-operator"].version}..."

      # Create namespace (helm template doesn't include it)
      kubectl create namespace redis-operator --dry-run=client -o yaml | kubectl apply -f -

      # Apply upstream Helm-rendered manifest (CRDs, RBAC, Deployment)
      kubectl apply --server-side -n redis-operator -f "${path.module}/../operators/upstream/redis-operator-${local.db_operators["redis-operator"].version}.yaml"

      # Patch deployment to schedule on database pool nodes
      kubectl patch deployment redis-operator -n redis-operator --type=json \
        -p '[{"op":"add","path":"/spec/template/spec/nodeSelector","value":{"workload-type":"database"}}]'

      # Apply our additions (NetworkPolicy, HPA, PDB)
      for f in hpa.yaml pdb.yaml; do
        kubectl apply -f "${path.module}/../operators/manifests/redis-operator/$f"
      done

      # Wait for rollout to complete
      kubectl rollout status deployment/redis-operator \
        -n redis-operator --timeout=300s

      echo "Redis Operator deployed successfully."
    SCRIPT
  }

  depends_on = [
    null_resource.deploy_node_labeler,
  ]
}

# -----------------------------------------------------------------------------
# Cluster Autoscaler — secrets (cloud-config + CA bundle)
# -----------------------------------------------------------------------------
# Creates the secrets the chart references via extraVolumes:
#   - cluster-autoscaler-cloud-config : Rancher URL + token + cluster target
#   - cluster-autoscaler-ca-cert      : Rancher TLS CA bundle (private + system)
# Must run before helm_release.cluster_autoscaler. Uses kubectl rather than
# kubernetes_secret resource because of the 262144-byte annotation cap on
# last-applied-configuration — the combined CA bundle routinely exceeds it.

resource "null_resource" "cluster_autoscaler_secrets" {
  count = var.deploy_operators && var.deploy_cluster_autoscaler ? 1 : 0

  triggers = {
    cluster_id      = rancher2_cluster_v2.rke2.id
    kubeconfig_hash = md5(rancher2_cluster_v2.rke2.kube_config)
    rancher_url     = var.rancher_url
    ca_hash         = md5(var.private_ca_pem)
    # Force re-run when rancher_token changes so the cloud-config secret
    # stays fresh even though the token is sensitive and not in triggers.
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -euo pipefail
      export KUBECONFIG="${local.operator_kubeconfig}"

      echo "Waiting for nodes to be Ready..."
      kubectl wait --for=condition=Ready node --all --timeout=600s

      # Ensure namespace exists (chart will do this too on first install;
      # we need it up-front to place the secrets before helm_release runs).
      kubectl create namespace cluster-autoscaler --dry-run=client -o yaml | kubectl apply -f -

      # Write cloud-config to rendered directory
      printf '%s\n' "$CLOUD_CONFIG" > "${local.rendered_dir}/cluster-autoscaler-cloud-config"

      # Build combined CA bundle = Rancher chain + private CA + system CAs
      ca_bundle="${local.rendered_dir}/cluster-autoscaler-ca-cert.pem"

      rancher_host=$(echo "$RANCHER_URL" | sed -E 's|https?://||;s|/.*||;s|:.*||')
      rancher_port=$(echo "$RANCHER_URL" | sed -nE 's|https?://[^:/]+(:[0-9]+).*|\1|p' | tr -d ':')
      rancher_port="$${rancher_port:-443}"

      echo "Fetching CA certificate chain from Rancher at $${rancher_host}:$${rancher_port}..."
      if openssl s_client -connect "$${rancher_host}:$${rancher_port}" \
           -servername "$${rancher_host}" -showcerts </dev/null 2>/dev/null \
           | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/{print}' > "$${ca_bundle}.rancher" \
           && [ -s "$${ca_bundle}.rancher" ]; then
        echo "Rancher certificate chain retrieved successfully."
      else
        echo "WARNING: Could not fetch Rancher certificate chain; continuing with provided CA only."
        : > "$${ca_bundle}.rancher"
      fi

      cp "$${ca_bundle}.rancher" "$${ca_bundle}"
      printf '%s\n' "$CA_CERT" >> "$${ca_bundle}"
      for sys_ca in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
        if [ -f "$${sys_ca}" ]; then
          cat "$${sys_ca}" >> "$${ca_bundle}"
          break
        fi
      done
      rm -f "$${ca_bundle}.rancher"

      kubectl create secret generic cluster-autoscaler-cloud-config \
        -n cluster-autoscaler \
        --from-file=cloud-config="${local.rendered_dir}/cluster-autoscaler-cloud-config" \
        --dry-run=client -o yaml | kubectl apply -f -

      kubectl create secret generic cluster-autoscaler-ca-cert \
        -n cluster-autoscaler \
        --from-file=ca.crt="$${ca_bundle}" \
        --dry-run=client -o yaml | kubectl apply --server-side --force-conflicts -f -

      rm -f "${local.rendered_dir}/cluster-autoscaler-cloud-config" "$${ca_bundle}"

      echo "cluster-autoscaler secrets created."
    SCRIPT

    environment = {
      RANCHER_URL = var.rancher_url
      CLOUD_CONFIG = join("\n", [
        "url: ${var.rancher_url}",
        "token: ${var.rancher_token}",
        "clusterName: ${var.cluster_name}",
        "clusterNamespace: fleet-default",
      ])
      CA_CERT = var.private_ca_pem
    }
  }

  depends_on = [
    null_resource.operator_kubeconfig,
  ]
}

# -----------------------------------------------------------------------------
# Cluster Autoscaler — helm_release
# -----------------------------------------------------------------------------
# Uses upstream kubernetes/autoscaler chart configured for the Rancher cloud
# provider. Chart is pulled from Harbor OCI (vendored source at
# operators/cluster-autoscaler/chart/ is pushed to Harbor once via
# operators/push-charts.sh).
#
# Fleet HelmOp (separate GitOps repo, out of scope here) takes over chart
# version + values after first apply. lifecycle.ignore_changes stops TF
# from reverting Fleet's upgrades.

resource "helm_release" "cluster_autoscaler" {
  count = var.deploy_operators && var.deploy_cluster_autoscaler ? 1 : 0

  name             = "cluster-autoscaler"
  namespace        = "cluster-autoscaler"
  create_namespace = false # created by null_resource.cluster_autoscaler_secrets
  repository       = var.cluster_autoscaler_chart_repository
  chart            = "cluster-autoscaler"
  version          = var.cluster_autoscaler_chart_version

  timeout = 600
  wait    = true
  atomic  = false

  # Override the chart's fullname template. Default would produce
  # `cluster-autoscaler-rancher-cluster-autoscaler` (release-name-chart-fullname doubling).
  set {
    name  = "fullnameOverride"
    value = "cluster-autoscaler"
  }

  set {
    name  = "cloudProvider"
    value = "rancher"
  }
  set {
    name  = "autoDiscovery.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "image.repository"
    value = var.cluster_autoscaler_image_repository
  }
  set {
    name  = "image.tag"
    value = var.cluster_autoscaler_image_tag
  }

  set {
    name  = "replicaCount"
    value = "2"
  }
  set {
    name  = "priorityClassName"
    value = "system-cluster-critical"
  }
  set {
    name  = "podLabels.app\\.kubernetes\\.io/name"
    value = "cluster-autoscaler"
  }

  set {
    name  = "nodeSelector.workload-type"
    value = "general"
  }

  set {
    name  = "extraArgs.scale-down-delay-after-add"
    value = var.autoscaler_scale_down_delay_after_add
  }
  set {
    name  = "extraArgs.scale-down-delay-after-delete"
    value = var.autoscaler_scale_down_delay_after_delete
  }
  set {
    name  = "extraArgs.scale-down-unneeded-time"
    value = var.autoscaler_scale_down_unneeded_time
  }
  set {
    name  = "extraArgs.scale-down-utilization-threshold"
    value = var.autoscaler_scale_down_utilization_threshold
  }
  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }
  set {
    name  = "extraArgs.skip-nodes-with-local-storage"
    value = "false"
  }

  values = [
    yamlencode({
      extraVolumeSecrets = {
        cloud-config = {
          name      = "cluster-autoscaler-cloud-config"
          mountPath = "/config"
          readOnly  = true
        }
        ca-cert = {
          # Upstream chart's extraVolumeSecrets ignores subPath and mounts the
          # whole secret as a directory; mount at a dir path and point
          # SSL_CERT_FILE at the ca.crt key inside.
          name      = "cluster-autoscaler-ca-cert"
          mountPath = "/etc/ssl/certs/rancher-ca"
          readOnly  = true
        }
      }
      extraEnv = {
        SSL_CERT_FILE = "/etc/ssl/certs/rancher-ca/ca.crt"
      }
      extraArgs = {
        "cloud-config" = "/config/cloud-config"
        # namespace is already set by the chart's template from .Release.Namespace;
        # do not duplicate it here.
      }
    })
  ]

  lifecycle {
    ignore_changes = [
      version,
      values,
      set,
      set_sensitive,
    ]
  }

  depends_on = [
    null_resource.cluster_autoscaler_secrets,
  ]
}
