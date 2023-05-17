terraform {
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "1.14.0"
    }

    sops = {
      source  = "carlpett/sops"
      version = "0.7.1"
    }
  }

  backend "kubernetes" {
    secret_suffix = "instana"
  }
}

variable "config_context" {
  type = string
}

provider "kubectl" {
  config_context = var.config_context
}

data "kubectl_file_documents" "gotk_components" {
  content = file("../../clusters/${terraform.workspace}/flux-system/gotk-components.yaml")
}

data "kubectl_file_documents" "gotk_sync" {
  content = file("../../clusters/${terraform.workspace}/flux-system/gotk-sync.yaml")
}

data "sops_file" "seed_resources" {
  source_file = "../seed-resources/${terraform.workspace}.enc.yaml"
}

data "kubectl_file_documents" "seed_resources" {
  content = data.sops_file.seed_resources.raw
}

resource "kubectl_manifest" "seed_resources" {
  for_each  = data.kubectl_file_documents.seed_resources.manifests
  yaml_body = each.value
}

resource "kubectl_manifest" "gotk_components" {
  for_each  = data.kubectl_file_documents.gotk_components.manifests
  yaml_body = each.value

  depends_on = [
    kubectl_manifest.seed_resources
  ]
}

resource "kubectl_manifest" "gotk_sync" {
  for_each  = data.kubectl_file_documents.gotk_sync.manifests
  yaml_body = each.value

  depends_on = [
    kubectl_manifest.gotk_components
  ]
}