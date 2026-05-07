terraform {
  required_version = ">= 1.5.0"

  required_providers {
    rancher2 = {
      source  = "rancher/rancher2"
      version = "~> 14.1"
    }

    harvester = {
      source  = "harvester/harvester"
      version = "~> 1.7"
    }

    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
  }

  backend "kubernetes" {
    secret_suffix = "rke2-cluster"
    namespace     = "terraform-state"
    config_path   = "kubeconfig-harvester.yaml"
  }
}
