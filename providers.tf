provider "rancher2" {
  api_url   = var.rancher_url
  token_key = var.rancher_token
  insecure  = var.rancher_insecure
  ca_certs  = var.rancher_insecure ? "" : var.private_ca_pem
}

provider "harvester" {
  kubeconfig = var.harvester_kubeconfig_path
}
