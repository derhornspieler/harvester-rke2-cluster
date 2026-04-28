output "cluster_id" {
  description = "Rancher v2 cluster ID"
  value       = rancher2_cluster_v2.rke2.id
}

output "cluster_name" {
  description = "Cluster name"
  value       = rancher2_cluster_v2.rke2.name
}

output "cluster_v1_id" {
  description = "Rancher v1 cluster ID (c-xxxxx format)"
  value       = rancher2_cluster_v2.rke2.cluster_v1_id
}

output "image_id" {
  description = "Harvester image ID"
  value       = data.harvester_image.golden.id
}

output "cloud_credential_id" {
  description = "Rancher cloud credential ID"
  value       = rancher2_cloud_credential.harvester.id
}

output "kubeconfig_rke2" {
  description = "RKE2 cluster kubeconfig (via Rancher proxy)"
  value       = rancher2_cluster_v2.rke2.kube_config
  sensitive   = true
}
