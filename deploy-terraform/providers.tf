provider "rancher2" {
  api_url   = var.rancher_url
  token_key = var.rancher_token
  insecure  = var.rancher_insecure
  ca_certs  = var.rancher_insecure ? "" : var.private_ca_pem
}

provider "harvester" {
  kubeconfig = var.harvester_kubeconfig_path
}

# Kubernetes provider configured against the Harvester cluster — used for
# resources that target KubeVirt CRDs (e.g. MigrationPolicy) that the
# harvester provider does not expose directly.
provider "kubernetes" {
  alias       = "harvester"
  config_path = var.harvester_kubeconfig_path
}

# Helm provider configured against the downstream RKE2 cluster. Uses the
# kubeconfig emitted by rancher2_cluster_v2.rke2 (same source as
# null_resource.operator_kubeconfig). OCI registry auth is anonymous for
# <your-harbor>'s /library and /kubernetes.github.io projects —
# Harbor is configured for anonymous read, which is all TF needs (push
# happens out-of-band via operators/push-charts.sh).
provider "helm" {
  kubernetes {
    host                   = yamldecode(rancher2_cluster_v2.rke2.kube_config).clusters[0].cluster.server
    token                  = yamldecode(rancher2_cluster_v2.rke2.kube_config).users[0].user.token
    cluster_ca_certificate = base64decode(yamldecode(rancher2_cluster_v2.rke2.kube_config).clusters[0].cluster["certificate-authority-data"])
  }
}
