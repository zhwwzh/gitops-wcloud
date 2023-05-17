terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.48.0"
    }

    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "1.14.0"
    }

    sops = {
      source  = "carlpett/sops"
      version = "0.7.1"
    }
  }

  backend "remote" {
    hostname     = "delivery.instana.io"
    organization = "ops-gcp-cluster"

    workspaces {
      prefix = "instana-"
    }
  }
}

locals {
  max_node_count          = 256
  postgres_admin_password = data.sops_file.core_secret.data["stringData.datastorePassword"]
}

provider "google" {
  project = var.project
  region  = var.region
}

provider "google-beta" {
  project = var.project
  region  = var.region
}


data "google_client_config" "provider" {}
data "google_project" "active_project" {}
data "google_compute_default_service_account" "default" {}

data "google_compute_network" "instana" {
  name = "in-${terraform.workspace}"
}

data "google_compute_subnetwork" "instana" {
  name = "in-${terraform.workspace}-private"
}

data "google_dns_managed_zone" "instana" {
  name = "${terraform.workspace}-private-zone"
}

data "google_dns_managed_zone" "instana_acme" {
  name = "${terraform.workspace}-acme-zone"
}

data "sops_file" "core_secret" {
  source_file = "../../regions/${terraform.workspace}/config/region-secrets.enc.yaml"
}

# Object Storage
resource "google_storage_bucket" "instana" {
  provider = google
  for_each = var.object_stores

  name     = "in-${terraform.workspace}-${each.key}"
  location = var.region

  labels = {
    "instana-region" = terraform.workspace
  }

  dynamic "lifecycle_rule" {
    for_each = each.value > 0 ? [each.value] : []

    content {
      condition {
        age = each.value
      }

      action {
        type = "Delete"
      }
    }
  }
}

# Kubernetes Cluster
resource "google_container_cluster" "instana" {
  provider = google-beta

  name     = "in-${terraform.workspace}"
  location = var.region

  # Create, then remove, the default
  # node pool.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Enable Datapath V2
  datapath_provider = "ADVANCED_DATAPATH"

  network_policy {
    enabled  = false
    provider = "PROVIDER_UNSPECIFIED"
  }

  # Enable Workload Identity
  identity_service_config {
    enabled = true
  }

  workload_identity_config {
    workload_pool = "${var.project}.svc.id.goog"
  }

  # Configure networking
  network                   = data.google_compute_network.instana.self_link
  subnetwork                = data.google_compute_subnetwork.instana.self_link
  default_max_pods_per_node = 32

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
    enable_private_nodes    = true
    enable_private_endpoint = false
  }

  # Configure release channel
  release_channel {
    channel = "REGULAR"
  }

  # Monitor only system components
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }
  
  addons_config {
    gcp_filestore_csi_driver_config {
      enabled = true
    }

    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  node_config {
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    machine_type = var.default_node_pool_type

    labels = {
      "instana.io/pool" = "default"
    }

    tags = ["in-${terraform.workspace}-node"]

    service_account = data.google_compute_default_service_account.default.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  lifecycle {
    ignore_changes = [
      enable_autopilot,
      node_pool,
      logging_config[0].enable_components,
      monitoring_config[0].enable_components,
      node_config[0].labels,
      node_config[0].machine_type,
    ]
  }
}

resource "google_container_node_pool" "pool" {
  provider = google-beta
  for_each = var.node_pools

  name    = "${terraform.workspace}-${each.key}"
  cluster = google_container_cluster.instana.self_link

  max_pods_per_node = each.value["max_pods_per_node"]

  node_config {
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    machine_type = each.value["machine_type"]

    labels = merge(
      { "instana.io/pool" = each.key },
      { for w in each.value["acceped_workloads"] : "workloads.instana.io/${w}" => "true" }
    )

    kubelet_config {
      cpu_manager_policy = "static"
    }

    tags = ["in-${terraform.workspace}-node"]

    service_account = data.google_compute_default_service_account.default.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  autoscaling {
    min_node_count = each.value["min_in_pool"]
    max_node_count = local.max_node_count
  }

  timeouts {
    create = "30m"
    update = "20m"
  }

  lifecycle {
    ignore_changes = [
      node_config[0].tags
    ]
  }
}

# Create the Cloud SQL Postgres Database
resource "random_id" "db_name_suffix" {
  byte_length = 4
}

resource "google_sql_database_instance" "instana" {
  provider = google-beta

  # NB: Database names have a one week cooldown period in GCP. 
  # While this isn't an issue for a stable environment, it is for a test one.
  # We add extra entropy here to ensure that we can quickly spin up/tear down
  # test regions.
  name             = "in-${terraform.workspace}-${random_id.db_name_suffix.hex}"
  database_version = "POSTGRES_14"

  root_password = local.postgres_admin_password

  # Disable delete protection for non-production domains
  # TODO: Use `endswith(var.domain_name, ".io")` when we can use Terraform 1.3.0.
  deletion_protection = length(regexall(".*\\.io$", var.domain_name)) > 0

  settings {
    tier = "db-custom-4-24576"

    ip_configuration {
      ipv4_enabled    = false
      private_network = data.google_compute_network.instana.self_link
    }

    user_labels = {
      "instana-io-pool" = "postgres"
    }
  }
}

resource "google_dns_record_set" "db_dns" {
  name         = "in-pg.${data.google_dns_managed_zone.instana.dns_name}"
  managed_zone = data.google_dns_managed_zone.instana.name

  rrdatas = [
    google_sql_database_instance.instana.private_ip_address
  ]

  ttl  = 300
  type = "A"
}

# Configure IAM
resource "google_service_account" "pod_service_account" {
  account_id  = "in-${terraform.workspace}-pods"
  description = "Service account assigned to the region's Kubernetes pods."
}

resource "google_project_iam_member" "pods_can_create_objects" {
  project = var.project
  role    = "roles/storage.objectCreator"
  member  = "serviceAccount:${google_service_account.pod_service_account.email}"

  condition {
    title       = "only_for_region"
    description = "Limit the service account to storage objects for its given region"
    expression  = "resource.matchTag('${data.google_project.active_project.project_id}/instana-region', '${terraform.workspace}')"
  }
}

resource "google_project_iam_member" "pods_can_decrypt_secrets" {
  project = var.project
  role    = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member  = "serviceAccount:${google_service_account.pod_service_account.email}"

  condition {
    title       = "only_for_key"
    description = "Limit the service account to only use the sops kms key."
    expression  = "resource.name.startsWith('projects/${data.google_project.active_project.project_id}/locations/${var.region}/keyRings/${terraform.workspace}-ring/cryptoKeys/${terraform.workspace}-sops')"
  }
}

resource "google_project_iam_member" "pods_can_manage_dns" {
  project = var.project
  role    = "roles/dns.admin"
  member  = "serviceAccount:${google_service_account.pod_service_account.email}"
}

resource "google_service_account_iam_member" "pod_service_accounts_can_access_gcp_account" {
  for_each = var.service_account_names

  service_account_id = google_service_account.pod_service_account.id
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${data.google_project.active_project.project_id}.svc.id.goog[${each.value}]"
}