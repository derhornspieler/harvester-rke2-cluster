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
#         -> null_resource.deploy_storage_autoscaler    (parallel)
#       -> null_resource.deploy_cnpg                    (parallel)
#       -> null_resource.deploy_mariadb_operator        (parallel)
#       -> null_resource.deploy_redis_operator          (parallel)
#       -> null_resource.deploy_cluster_autoscaler      (parallel)
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

  # Cluster autoscaler version should match the cluster's Kubernetes minor version.
  # K8s v1.34.x -> cluster-autoscaler v1.34.x
  cluster_autoscaler_version = "v1.34.3"

  operator_kubeconfig = "${path.module}/.kubeconfig-rke2-operators"
  rendered_dir        = "${path.module}/.rendered"
}

# -----------------------------------------------------------------------------
# Kubeconfig + Rendered Templates — written via shell (no hashicorp/local)
# -----------------------------------------------------------------------------

resource "null_resource" "operator_kubeconfig" {
  count = var.deploy_operators ? 1 : 0

  triggers = {
    cluster_id = rancher2_cluster_v2.rke2.id
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
        "${path.module}/operators/templates/node-labeler-deployment.yaml.tftpl" \
        > "${local.rendered_dir}/node-labeler-deployment.yaml"

      # Render storage-autoscaler deployment template
      sed \
        -e 's|$${harbor_fqdn}|${var.harbor_fqdn}|g' \
        -e 's|$${version}|${local.operators["storage-autoscaler"].version}|g' \
        "${path.module}/operators/templates/storage-autoscaler-deployment.yaml.tftpl" \
        > "${local.rendered_dir}/storage-autoscaler-deployment.yaml"

      # Render cluster-autoscaler deployment template
      sed \
        -e 's|$${version}|${local.cluster_autoscaler_version}|g' \
        -e 's|$${scale_down_delay_after_add}|${var.autoscaler_scale_down_delay_after_add}|g' \
        -e 's|$${scale_down_delay_after_delete}|${var.autoscaler_scale_down_delay_after_delete}|g' \
        -e 's|$${scale_down_unneeded_time}|${var.autoscaler_scale_down_unneeded_time}|g' \
        -e 's|$${scale_down_utilization_threshold}|${var.autoscaler_scale_down_utilization_threshold}|g' \
        "${path.module}/operators/templates/cluster-autoscaler-deployment.yaml.tftpl" \
        > "${local.rendered_dir}/cluster-autoscaler-deployment.yaml"

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
    command = "${path.module}/operators/push-images.sh"
    environment = {
      HARBOR_FQDN     = var.harbor_fqdn
      HARBOR_USER     = var.harbor_admin_user
      HARBOR_PASSWORD = var.harbor_admin_password
      HARBOR_CA_PEM   = var.private_ca_pem
      IMAGES_DIR      = "${path.module}/operators/images"
    }
  }

  lifecycle {
    precondition {
      condition     = var.harbor_admin_password != ""
      error_message = "harbor_admin_password is required when deploy_operators = true."
    }
  }

  depends_on = [
    null_resource.operator_kubeconfig,
  ]
}

# -----------------------------------------------------------------------------
# Deploy: node-labeler
# -----------------------------------------------------------------------------

resource "null_resource" "deploy_node_labeler" {
  count = var.deploy_operators ? 1 : 0

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
      for f in namespace.yaml rbac.yaml service.yaml hpa.yaml networkpolicy.yaml; do
        kubectl apply -f "${path.module}/operators/manifests/node-labeler/$f"
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
# Deploy: storage-autoscaler
# -----------------------------------------------------------------------------

resource "null_resource" "deploy_storage_autoscaler" {
  count = var.deploy_operators ? 1 : 0

  triggers = {
    cluster_id = rancher2_cluster_v2.rke2.id
    version    = local.operators["storage-autoscaler"].version
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -euo pipefail
      export KUBECONFIG="${local.operator_kubeconfig}"

      echo "Waiting for nodes to be Ready..."
      kubectl wait --for=condition=Ready node --all --timeout=600s

      echo "Deploying storage-autoscaler ${local.operators["storage-autoscaler"].version}..."

      # Apply CRD first — must exist before the controller starts
      kubectl apply -f "${path.module}/operators/manifests/storage-autoscaler/crd.yaml"

      # Apply static manifests (namespace, rbac, service, hpa, networkpolicy)
      for f in namespace.yaml rbac.yaml service.yaml hpa.yaml networkpolicy.yaml; do
        kubectl apply -f "${path.module}/operators/manifests/storage-autoscaler/$f"
      done

      # Apply rendered deployment (with correct Harbor image reference)
      kubectl apply -f "${local.rendered_dir}/storage-autoscaler-deployment.yaml"

      echo "storage-autoscaler deployed successfully."
    SCRIPT
  }

  depends_on = [
    null_resource.operator_image_push,
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
      kubectl apply --server-side -f "${path.module}/operators/upstream/cnpg-${local.db_operators["cnpg"].version}.yaml"

      # Patch deployment to schedule on database pool nodes
      kubectl patch deployment cnpg-controller-manager -n cnpg-system --type=json \
        -p '[{"op":"add","path":"/spec/template/spec/nodeSelector","value":{"workload-type":"database"}}]'

      # Apply our additions (NetworkPolicy, HPA, PDB)
      for f in networkpolicy.yaml hpa.yaml pdb.yaml; do
        kubectl apply -f "${path.module}/operators/manifests/cnpg-system/$f"
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
      kubectl apply --server-side -f "${path.module}/operators/upstream/mariadb-operator-crds-${local.db_operators["mariadb-operator"].version}.yaml"

      # Apply upstream Helm-rendered manifest (RBAC, Deployment, cert-controller, webhook)
      # Note: -n flag needed because helm template doesn't embed namespace in all resources
      kubectl apply --server-side -n mariadb-operator -f "${path.module}/operators/upstream/mariadb-operator-${local.db_operators["mariadb-operator"].version}.yaml"

      # Patch deployments to schedule on database pool nodes
      for deploy in mariadb-operator mariadb-operator-cert-controller; do
        kubectl patch deployment "$deploy" -n mariadb-operator --type=json \
          -p '[{"op":"add","path":"/spec/template/spec/nodeSelector","value":{"workload-type":"database"}}]' 2>/dev/null || true
      done

      # Apply our additions (NetworkPolicy, HPA, PDB)
      for f in networkpolicy.yaml hpa.yaml pdb.yaml; do
        kubectl apply -f "${path.module}/operators/manifests/mariadb-operator/$f"
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
      kubectl apply --server-side -n redis-operator -f "${path.module}/operators/upstream/redis-operator-${local.db_operators["redis-operator"].version}.yaml"

      # Patch deployment to schedule on database pool nodes
      kubectl patch deployment redis-operator -n redis-operator --type=json \
        -p '[{"op":"add","path":"/spec/template/spec/nodeSelector","value":{"workload-type":"database"}}]'

      # Apply our additions (NetworkPolicy, HPA, PDB)
      for f in networkpolicy.yaml hpa.yaml pdb.yaml; do
        kubectl apply -f "${path.module}/operators/manifests/redis-operator/$f"
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
# Deploy: Cluster Autoscaler (Rancher cloud provider)
# -----------------------------------------------------------------------------
# Deploys the upstream Kubernetes cluster-autoscaler with --cloud-provider=rancher.
# The autoscaler talks to the Rancher API to adjust machine pool quantities based
# on pod scheduling pressure and node utilization.
#
# Prerequisites already in place:
#   - Machine pool annotations (autoscaler-min-size, autoscaler-max-size) in cluster.tf
#   - Cluster-level autoscaler annotations (scale-down behavior) in cluster.tf
#   - lifecycle.ignore_changes on worker pool quantities in cluster.tf
#
# The autoscaler runs on the general pool with priorityClassName system-cluster-critical
# to prevent chicken-and-egg problems (it must be running to trigger scale-up).
# -----------------------------------------------------------------------------

resource "null_resource" "deploy_cluster_autoscaler" {
  count = var.deploy_operators && var.deploy_cluster_autoscaler ? 1 : 0

  triggers = {
    cluster_id = rancher2_cluster_v2.rke2.id
    version    = local.cluster_autoscaler_version
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -euo pipefail
      export KUBECONFIG="${local.operator_kubeconfig}"

      echo "Waiting for nodes to be Ready..."
      kubectl wait --for=condition=Ready node --all --timeout=600s

      echo "Deploying cluster-autoscaler ${local.cluster_autoscaler_version}..."

      # Apply static manifests (namespace, rbac, service, pdb, networkpolicy)
      for f in namespace.yaml rbac.yaml service.yaml pdb.yaml networkpolicy.yaml; do
        kubectl apply -f "${path.module}/operators/manifests/cluster-autoscaler/$f"
      done

      # Write cloud-config to rendered directory (avoids shell escaping
      # issues with multiline data inside Terraform local-exec).
      printf '%s\n' "$CLOUD_CONFIG" > "${local.rendered_dir}/cluster-autoscaler-cloud-config"

      # Build a combined CA bundle so the autoscaler trusts Rancher's TLS
      # regardless of whether Rancher uses a public CA, private CA, or a
      # CA different from private_ca_pem (common in airgapped deployments).
      #
      # Bundle = Rancher server cert chain + private_ca_pem + system CAs
      ca_bundle="${local.rendered_dir}/cluster-autoscaler-ca-cert.pem"

      # 1. Fetch the Rancher server's certificate chain via openssl.
      #    We use -servername for SNI and extract all certs in the chain.
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

      # 2. Start the combined bundle with the fetched Rancher chain
      cp "$${ca_bundle}.rancher" "$${ca_bundle}"

      # 3. Append the private CA (always provided via Terraform variable)
      printf '%s\n' "$CA_CERT" >> "$${ca_bundle}"

      # 4. Append system CA bundle for public CA trust
      for sys_ca in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
        if [ -f "$${sys_ca}" ]; then
          cat "$${sys_ca}" >> "$${ca_bundle}"
          break
        fi
      done

      rm -f "$${ca_bundle}.rancher"

      # Create cloud-config secret for Rancher API access.
      # The autoscaler uses this to authenticate with Rancher and adjust
      # machine pool quantities on the provisioning.cattle.io cluster resource.
      kubectl create secret generic cluster-autoscaler-cloud-config \
        -n cluster-autoscaler \
        --from-file=cloud-config="${local.rendered_dir}/cluster-autoscaler-cloud-config" \
        --dry-run=client -o yaml | kubectl apply -f -

      # Create CA cert secret with the combined bundle for Rancher TLS verification.
      kubectl create secret generic cluster-autoscaler-ca-cert \
        -n cluster-autoscaler \
        --from-file=ca.crt="$${ca_bundle}" \
        --dry-run=client -o yaml | kubectl apply -f -

      # Clean up sensitive files immediately after creating secrets
      rm -f "${local.rendered_dir}/cluster-autoscaler-cloud-config" \
            "$${ca_bundle}"

      # Apply rendered deployment (with correct image version and scale-down params)
      kubectl apply -f "${local.rendered_dir}/cluster-autoscaler-deployment.yaml"

      # Wait for rollout to complete
      kubectl rollout status deployment/cluster-autoscaler \
        -n cluster-autoscaler --timeout=300s

      echo "cluster-autoscaler deployed successfully."
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
    null_resource.deploy_node_labeler,
  ]
}
