terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.37.0"
    }
  }
  
  backend "remote" {
    hostname     = "delivery.instana.io"
    organization = "ops-gcp-developer-sandbox"
  
    workspaces {
      prefix = "instana-"
    }
  }
}

locals {
  cidr_index = var.region_number * 8
  public_subnet_cidr    = cidrsubnet(var.base_cidr, 8, local.cidr_index + 0)
  private_subnet_cidr   = cidrsubnet(var.base_cidr, 8, local.cidr_index + 1)
  private_pods_cidr     = cidrsubnet(var.base_cidr, 8, local.cidr_index + 2)
  private_services_cidr = cidrsubnet(var.base_cidr, 8, local.cidr_index + 3)
  google_peering_cidr   = cidrsubnet(var.base_cidr, 8, local.cidr_index + 4)
}

provider "google" {
  project = var.project
  region  = var.region
}

data "google_organization" "org" {
  domain = "instana.com"
}

resource "google_tags_tag_key" "key" {
  parent = data.google_organization.org.name
  short_name = "in-${terraform.workspace}-owner"
  description = "The identifier of the team member(s) responsible for this resource."
}

resource "google_service_account" "developer_service_account" {
  account_id  = "in-dev-hosts"
  description = "Test Service Account"
}

resource "google_project_iam_member" "launch_compute_instsances_with_tags" {
  project = var.project
  role    = "roles/compute.instanceAdmin"
  member  = "group:${var.developer_group}"

  condition {
    title       = "must_have_tags"
    description = "Launched instances must have an owner tag."
    expression  = "resource.hasTagKey('${data.google_organization.org.org_id}/in-${terraform.workspace}-owner')"
  }
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