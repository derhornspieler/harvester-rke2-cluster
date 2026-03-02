terraform {
  required_version = ">= 1.5.0"

  required_providers {
    rancher2 = {
      source  = "rancher/rancher2"
      version = "~> 13.1"
    }

    harvester = {
      source  = "harvester/harvester"
      version = "~> 0.6"
    }
  }

  backend "kubernetes" {
    secret_suffix = "rke2-cluster"
    namespace     = "terraform-state"
    config_path   = "kubeconfig-harvester.yaml"
  }
}
