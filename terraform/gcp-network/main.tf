terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.37.0"
    }
  }

  backend "remote" {
    hostname     = "delivery.instana.io"
    organization = "ops-gcp-network"

    workspaces {
      prefix = "instana-"
    }
  }
}

provider "google" {
  project = var.project
  region  = var.region
}

locals {
  cidr_index = var.region_number * 8
  public_subnet_cidr    = cidrsubnet(var.base_cidr, 8, local.cidr_index + 0)
  private_subnet_cidr   = cidrsubnet(var.base_cidr, 8, local.cidr_index + 1)
  private_pods_cidr     = cidrsubnet(var.base_cidr, 8, local.cidr_index + 2)
  private_services_cidr = cidrsubnet(var.base_cidr, 8, local.cidr_index + 3)
  google_peering_cidr   = cidrsubnet(var.base_cidr, 8, local.cidr_index + 4)
}

resource "google_compute_network" "instana_network" {
  name                    = "in-${terraform.workspace}"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "instana_public" {
  name                     = "in-${terraform.workspace}-public"
  network                  = google_compute_network.instana_network.id
  private_ip_google_access = true

  ip_cidr_range = local.public_subnet_cidr
}

resource "google_compute_subnetwork" "instana_private" {
  name                     = "in-${terraform.workspace}-private"
  network                  = google_compute_network.instana_network.id
  private_ip_google_access = true

  ip_cidr_range = local.private_subnet_cidr

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = local.private_pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = local.private_services_cidr
  }
}

resource "google_compute_router" "instana_router" {
  name    = "in-${terraform.workspace}-router"
  network = google_compute_network.instana_network.name
}

resource "google_compute_router_nat" "instana_nat" {
  name   = "in-${terraform.workspace}-nat"
  router = google_compute_router.instana_router.name

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_compute_global_address" "instana_google_peering" {
  name    = "in-${terraform.workspace}-peering-google"
  network = google_compute_network.instana_network.name

  address_type  = "INTERNAL"
  purpose       = "VPC_PEERING"
  address       = split("/", local.google_peering_cidr)[0]
  prefix_length = split("/", local.google_peering_cidr)[1]
}

resource "google_service_networking_connection" "google_service_networking" {
  network                 = google_compute_network.instana_network.name
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.instana_google_peering.name]
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = google_compute_network.instana_network.id

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["22", "3389"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "master_webhooks" {
  name        = "gke-in-${terraform.workspace}-webhooks"
  description = "Allow master to hit pods for admission controllers/webhooks"
  network     = google_compute_network.instana_network.id
  priority    = 1000
  direction   = "INGRESS"

  source_ranges = [var.master_ipv4_cidr_block]
  target_tags   = ["in-${terraform.workspace}-node"]

  allow {
    protocol = "tcp"
    ports    = ["9443", "8443", "443"]
  }
}

# Private DNS Zone
resource "google_dns_managed_zone" "region_private" {
  name        = "${terraform.workspace}-private-zone"
  dns_name    = "${terraform.workspace}-internal.${var.domain_name}."
  description = "Internal DNS Zone for non-Kubernetes resources."

  visibility = "private"
  
  labels = {
    "instana-region" = terraform.workspace
  }

  private_visibility_config {
    networks {
      network_url = google_compute_network.instana_network.self_link
    }
  }
}

# ACME DNS Zone
resource "google_dns_managed_zone" "acme_region" {
  name        = "${terraform.workspace}-acme-zone"
  dns_name    = "_acme-challenge.${var.domain_name}."
  description = "Public DNS Zone to handle ACME challenge delegation."

  visibility = "public"
  
  labels = {
    "instana-region" = terraform.workspace
  }
}

# SOPS Managed Encryption Keys
resource "google_kms_key_ring" "sops_ring" {
  name     = "${terraform.workspace}-ring"
  location = var.region
}

resource "google_kms_crypto_key" "sops_key" {
  name     = "${terraform.workspace}-sops"
  key_ring = google_kms_key_ring.sops_ring.id
}