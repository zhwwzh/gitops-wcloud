terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }

  backend "remote" {
    hostname     = "delivery.instana.io"
    organization = "ops-aws-network"

    workspaces {
      prefix = "instana-"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      "Environment" = "in-${terraform.workspace}"
      "ManagedBy"   = "terraform"
    }
  }
}

locals {
  cidr_index = var.region_number * 8

  vpc_base_cidr = cidrsubnet(var.base_cidr, 8, local.cidr_index + 0)
  public_cidr_blocks = { for i in range(1, 4) :
  data.aws_availability_zones.available.names[i % 3] => cidrsubnet(var.base_cidr, 8, local.cidr_index + i) }
  private_cidr_blocks = { for i in range(4, 7) :
  data.aws_availability_zones.available.names[i % 3] => cidrsubnet(var.base_cidr, 8, local.cidr_index + i) }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# VPC Networking
resource "aws_vpc" "instana" {
  cidr_block                           = local.vpc_base_cidr
  enable_network_address_usage_metrics = true
  
  enable_dns_support = true
  enable_dns_hostnames = true

  tags = {
    Name = "in-${terraform.workspace}-gw"
    Role = "vpc"
  }
}

resource "aws_internet_gateway" "instana" {
  vpc_id = aws_vpc.instana.id

  tags = {
    Name = "in-${terraform.workspace}-gw"
    Role = "internet-gateway"
  }
}

resource "aws_vpc_ipv4_cidr_block_association" "public_cidr" {
  for_each = local.public_cidr_blocks

  vpc_id     = aws_vpc.instana.id
  cidr_block = each.value
}

resource "aws_vpc_ipv4_cidr_block_association" "private_cidr" {
  for_each = local.private_cidr_blocks

  vpc_id     = aws_vpc.instana.id
  cidr_block = each.value
}

resource "aws_subnet" "public_subnet" {
  for_each = local.public_cidr_blocks

  vpc_id            = aws_vpc_ipv4_cidr_block_association.public_cidr[each.key].vpc_id
  cidr_block        = each.value
  availability_zone = each.key

  map_public_ip_on_launch = true

  tags = {
    Name       = "in-${terraform.workspace}-public-${each.key}"
    Role       = "subnet"
    Visibility = "public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.instana.id

  tags = {
    Name       = "in-${terraform.workspace}-rt-public"
    Role       = "route-table"
    Visibility = "public"
  }
}

resource "aws_route" "public_subnet_internet_gateway" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.instana.id
}

resource "aws_route_table_association" "public_subnet_public_table" {
  for_each = local.public_cidr_blocks

  subnet_id      = aws_subnet.public_subnet[each.key].id
  route_table_id = aws_route_table.public.id
}

resource "aws_subnet" "private_subnet" {
  for_each = local.private_cidr_blocks

  vpc_id            = aws_vpc_ipv4_cidr_block_association.private_cidr[each.key].vpc_id
  cidr_block        = each.value
  availability_zone = each.key

  tags = {
    Name       = "in-${terraform.workspace}-private-${each.key}"
    Role       = "subnet"
    Visibility = "private"
  }
}

resource "aws_eip" "region_ip" {
  for_each = local.private_cidr_blocks
  
  vpc              = true
  
  tags = {
    Name       = "in-${terraform.workspace}-ip-${each.key}"
    Role       = "eip"
    Visibility = "public"
  }
  
  depends_on = [aws_internet_gateway.instana]  
}

resource "aws_nat_gateway" "instana" {
  for_each = local.private_cidr_blocks

  subnet_id = aws_subnet.public_subnet[each.key].id
  allocation_id = aws_eip.region_ip[each.key].id

  tags = {
    Name       = "in-${terraform.workspace}-nat-${each.key}"
    Role       = "nat-gateway"
    Visibility = "public"
  }

  depends_on = [aws_internet_gateway.instana]
}

resource "aws_route_table" "private" {
  for_each = local.private_cidr_blocks
  vpc_id   = aws_vpc.instana.id

  tags = {
    Name       = "in-${terraform.workspace}-rt-private-${each.key}"
    Role       = "route-table"
    Visibility = "private"
  }
}

resource "aws_route" "private_subnet_nat_gateway" {
  for_each = local.private_cidr_blocks

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id             = aws_nat_gateway.instana[each.key].id
}

resource "aws_route_table_association" "private_subnet_private_table" {
  for_each = local.private_cidr_blocks

  subnet_id      = aws_subnet.private_subnet[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

# Private DNS
resource "aws_route53_zone" "internal" {
  name = "${terraform.workspace}-internal.${var.domain_name}"

  vpc {
    vpc_id = aws_vpc.instana.id
  }

  tags = {
    Role       = "dns"
    Visibility = "private"
  }
}

# ACME Challenge DNS
resource "aws_route53_zone" "acme_challenge" {
  name = "_acme-challenge.${var.domain_name}"

  tags = {
    Role       = "dns"
    Visibility = "public"
  }
}

# KMS Key for SOPS
resource "aws_kms_key" "sops" {
  description             = "SOPS key for ${terraform.workspace}"
  deletion_window_in_days = 10

  tags = {
    Name       = "in-${terraform.workspace}-sops"
    Role       = "sops"
    Visibility = "private"
  }
}

resource "aws_kms_alias" "sops" {
  name          = "alias/sops-in-${terraform.workspace}"
  target_key_id = aws_kms_key.sops.key_id
}