# -----------------------------------------------------------------------------
# Operator Deployment — node-labeler, storage-autoscaler, DB operators
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

      # Render CNPG deployment template (upstream image, only version substitution)
      sed \
        -e 's|$${version}|${local.db_operators["cnpg"].version}|g' \
        "${path.module}/operators/templates/cnpg-deployment.yaml.tftpl" \
        > "${local.rendered_dir}/cnpg-deployment.yaml"

      # Render MariaDB Operator deployment template (upstream image, only version substitution)
      sed \
        -e 's|$${version}|${local.db_operators["mariadb-operator"].version}|g' \
        "${path.module}/operators/templates/mariadb-operator-deployment.yaml.tftpl" \
        > "${local.rendered_dir}/mariadb-operator-deployment.yaml"

      # Render Redis Operator deployment template (upstream image, only version substitution)
      sed \
        -e 's|$${version}|${local.db_operators["redis-operator"].version}|g' \
        "${path.module}/operators/templates/redis-operator-deployment.yaml.tftpl" \
        > "${local.rendered_dir}/redis-operator-deployment.yaml"
    SCRIPT
  }
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

      # Apply namespace first
      kubectl apply -f "${path.module}/operators/manifests/cnpg-system/namespace.yaml"

      # Apply CRDs — must exist before the controller starts
      kubectl apply --server-side -f "${path.module}/operators/manifests/cnpg-system/crds.yaml"

      # Apply remaining static manifests (rbac, service, hpa, networkpolicy, webhook)
      for f in rbac.yaml service.yaml hpa.yaml pdb.yaml networkpolicy.yaml webhook.yaml; do
        kubectl apply -f "${path.module}/operators/manifests/cnpg-system/$f"
      done

      # Apply rendered deployment (with correct Harbor image reference)
      kubectl apply -f "${local.rendered_dir}/cnpg-deployment.yaml"

      # Wait for rollout to complete
      kubectl rollout status deployment/cnpg-controller-manager \
        -n cnpg-system --timeout=300s

      echo "CloudNativePG deployed successfully."
    SCRIPT
  }

  depends_on = [
    null_resource.operator_kubeconfig,
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

      # Apply namespace first
      kubectl apply -f "${path.module}/operators/manifests/mariadb-operator/namespace.yaml"

      # Apply CRDs — must exist before the controller starts
      kubectl apply --server-side -f "${path.module}/operators/manifests/mariadb-operator/crds.yaml"

      # Apply remaining static manifests (rbac, service, hpa, pdb, networkpolicy)
      # Note: webhook.yaml skipped — cert-controller requires separate deployment
      for f in rbac.yaml service.yaml hpa.yaml pdb.yaml networkpolicy.yaml; do
        kubectl apply -f "${path.module}/operators/manifests/mariadb-operator/$f"
      done

      # Apply rendered deployment (with correct Harbor image reference)
      kubectl apply -f "${local.rendered_dir}/mariadb-operator-deployment.yaml"

      # Wait for rollout to complete
      kubectl rollout status deployment/mariadb-operator \
        -n mariadb-operator --timeout=300s

      echo "MariaDB Operator deployed successfully."
    SCRIPT
  }

  depends_on = [
    null_resource.operator_kubeconfig,
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

      # Apply namespace first
      kubectl apply -f "${path.module}/operators/manifests/redis-operator/namespace.yaml"

      # Apply CRDs — must exist before the controller starts
      kubectl apply --server-side -f "${path.module}/operators/manifests/redis-operator/crds.yaml"

      # Apply remaining static manifests (rbac, service, hpa, networkpolicy)
      # Note: Redis Operator does not use webhooks
      for f in rbac.yaml service.yaml hpa.yaml pdb.yaml networkpolicy.yaml; do
        kubectl apply -f "${path.module}/operators/manifests/redis-operator/$f"
      done

      # Apply rendered deployment (with correct Harbor image reference)
      kubectl apply -f "${local.rendered_dir}/redis-operator-deployment.yaml"

      # Wait for rollout to complete
      kubectl rollout status deployment/redis-operator \
        -n redis-operator --timeout=300s

      echo "Redis Operator deployed successfully."
    SCRIPT
  }

  depends_on = [
    null_resource.operator_kubeconfig,
  ]
}
