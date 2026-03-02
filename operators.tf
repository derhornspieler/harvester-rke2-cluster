# -----------------------------------------------------------------------------
# Operator Deployment — node-labeler + storage-autoscaler
# -----------------------------------------------------------------------------
# Pushes pre-built OCI images to Harbor, then deploys operators via kubectl.
# Gated by var.deploy_operators (default: true).
#
# Dependency chain:
#   rancher2_cluster_v2.rke2
#     -> null_resource.operator_kubeconfig
#     -> null_resource.operator_image_push
#       -> null_resource.deploy_node_labeler    (parallel)
#       -> null_resource.deploy_storage_autoscaler (parallel)
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
    SCRIPT
  }
}

# -----------------------------------------------------------------------------
# Image Push — crane pushes pre-built OCI tarballs to Harbor
# -----------------------------------------------------------------------------

resource "null_resource" "operator_image_push" {
  count = var.deploy_operators ? 1 : 0

  triggers = {
    cluster_id                 = rancher2_cluster_v2.rke2.id
    node_labeler_version       = local.operators["node-labeler"].version
    storage_autoscaler_version = local.operators["storage-autoscaler"].version
  }

  provisioner "local-exec" {
    command     = "${path.module}/operators/push-images.sh"
    environment = {
      HARBOR_FQDN    = var.harbor_fqdn
      HARBOR_USER    = "admin"
      HARBOR_PASSWORD = var.harbor_admin_password
      HARBOR_CA_PEM  = var.private_ca_pem
      IMAGES_DIR     = "${path.module}/operators/images"
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

      echo "Deploying node-labeler ${local.operators["node-labeler"].version}..."

      # Apply static manifests (namespace, rbac, service, hpa)
      for f in namespace.yaml rbac.yaml service.yaml hpa.yaml; do
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

      # Apply static manifests (namespace, rbac, service, hpa)
      for f in namespace.yaml rbac.yaml service.yaml hpa.yaml; do
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
