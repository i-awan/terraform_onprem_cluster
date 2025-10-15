terraform {
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "2.42.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"   # supports kubernetes { ... } block
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}

provider "kubernetes" {
  config_path = var.local_kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = var.local_kubeconfig_path
  }
}

provider "scaleway" {
  zone   = "fr-par-1"
  region = "fr-par"
}




