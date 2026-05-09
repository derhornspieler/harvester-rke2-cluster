resource "rancher2_cloud_credential" "harvester" {
  name = var.harvester_cloud_credential_name

  harvester_credential_config {
    cluster_id         = var.harvester_cluster_id
    cluster_type       = "imported"
    kubeconfig_content = file(var.harvester_cloud_credential_kubeconfig_path)
  }
}
